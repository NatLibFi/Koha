#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use File::Temp                qw( tempdir );
use JSON                      qw( decode_json );
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::NoWarnings qw( had_no_warnings );

use t::lib::Mocks;
use t::lib::TestBuilder;

use C4::Auth;
use Koha::ActionLog;
use Koha::ActionLogs;
use Koha::ApiKeys;
use Koha::Database;
use Koha::DateUtils qw( dt_from_string );
use Koha::Patron::Disclosure;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

# DBI-backed CGI sessions force AutoCommit and break the surrounding test
# transaction. Packaged instances can also configure a daemon-owned temporary
# directory, so keep file-backed test sessions in a process-owned directory.
my $session_tmpdir = tempdir( CLEANUP => 1 );
t::lib::Mocks::mock_config( 'tmp_path', $session_tmpdir );
t::lib::Mocks::mock_preference( 'SessionStorage',                       'tmp' );
t::lib::Mocks::mock_preference( 'RESTBasicAuth',                        1 );
t::lib::Mocks::mock_preference( 'RESTOAuth2ClientCredentials',          1 );
t::lib::Mocks::mock_config( 'patron_data_disclosure_log',         1 );
t::lib::Mocks::mock_config( 'patron_data_disclosure_max_subjects', 1000 );

my $t = Test::Mojo->new('Koha::REST::V1');
my $current_actor_id;

# Mojolicious runs after_dispatch hooks in reverse registration order. This
# later hook must therefore contribute its subject before Koha finalizes the
# response-bound event registered during application startup.
$t->app->hook(
    after_dispatch => sub {
        my ($c) = @_;

        my $patron_id = $c->req->headers->header('x-koha-test-late-disclosure-subject');
        return unless $patron_id;

        $c->patron_disclosure->add_subject(
            {
                patron_id    => $patron_id,
                data_classes => ['identity'],
            }
        );
    }
);

sub disclosure_logs {
    return Koha::ActionLogs->search(
        {
            module => Koha::Patron::Disclosure::MODULE,
            action => Koha::Patron::Disclosure::ACTION,
            user   => $current_actor_id,
        },
        { order_by => 'action_id' }
    );
}

sub payload {
    my ($log) = @_;
    return decode_json( $log->info );
}

sub classes_for_patron_representation {
    my ($representation) = @_;
    my $mapping = Koha::Patron::Disclosure->api_field_classes;
    my %classes;

    for my $field ( keys %{$representation} ) {
        die "Unclassified field '$field' in Patron response" unless exists $mapping->{$field};
        $classes{$_} = 1 for @{ $mapping->{$field} };
    }

    return [ sort keys %classes ];
}

sub build_actor {
    my $password = 'DisclosureAudit1!';
    my $actor    = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 1 },
        }
    );
    $actor->set_password( { password => $password, skip_validation => 1 } );
    $actor->discard_changes;
    $current_actor_id = $actor->id;
    return ( $actor, $password );
}

sub session_transaction {
    my ( $actor, $method, $path, $headers ) = @_;

    my $session = C4::Auth::get_session('');
    $session->param( 'number',      $actor->id );
    $session->param( 'id',          $actor->userid );
    $session->param( 'ip',          '127.0.0.1' );
    $session->param( 'lasttime',    time );
    $session->param( 'sessiontype', 'staff' );
    $session->flush;

    my $tx = $t->ua->build_tx( $method => $path => ( $headers // {} ) );
    $tx->req->cookies( { name => 'CGISESSID', value => $session->id } );
    $tx->req->env( { REMOTE_ADDR => '127.0.0.1' } );
    return $tx;
}

sub oauth_access_token {
    my ($actor) = @_;

    my $api_key = Koha::ApiKey->new( { patron_id => $actor->id, description => 'Disclosure audit test' } )->store;
    $t->post_ok(
        '/api/v1/oauth/token',
        form => {
            grant_type    => 'client_credentials',
            client_id     => $api_key->client_id,
            client_secret => $api_key->plain_text_secret,
        }
    )->status_is(200)->json_has('/access_token');

    return {
        access_token => $t->tx->res->json->{access_token},
        client_id    => $api_key->client_id,
    };
}

subtest 'authentication sources produce equivalent disclosure events' => sub {
    $schema->storage->txn_begin;

    my ( $actor, $password ) = build_actor();
    my $target = $builder->build_object( { class => 'Koha::Patrons', value => { branchcode => $actor->branchcode } } );
    my $path   = '/api/v1/patrons/' . $target->id;
    my @expected_classes;
    my @expected_auth_sources;
    my @expected_api_client_ids;

    $t->get_ok( '//' . $actor->userid . ":$password\@$path" => { 'x-koha-request-id' => 'forged-client-event-id' } )
        ->status_is(200);
    @expected_classes = @{ classes_for_patron_representation( $t->tx->res->json ) };
    push @expected_auth_sources, 'basic';
    push @expected_api_client_ids, undef;

    my $session_tx = session_transaction( $actor, GET => $path );
    $t->request_ok($session_tx)->status_is(200);
    is_deeply(
        classes_for_patron_representation( $t->tx->res->json ),
        \@expected_classes,
        'session response exposes the same data classes'
    );
    push @expected_auth_sources, 'session';
    push @expected_api_client_ids, undef;

    my $oauth    = oauth_access_token($actor);
    my $oauth_tx = $t->ua->build_tx( GET => $path );
    $oauth_tx->req->headers->authorization( 'Bearer ' . $oauth->{access_token} );
    $t->request_ok($oauth_tx)->status_is(200);
    is_deeply(
        classes_for_patron_representation( $t->tx->res->json ),
        \@expected_classes,
        'OAuth response exposes the same data classes'
    );
    push @expected_auth_sources, 'oauth';
    push @expected_api_client_ids, $oauth->{client_id};

    my @logs = disclosure_logs()->as_list;
    is( scalar @logs, scalar @expected_auth_sources, 'one row is written for each authenticated response' );
    is_deeply( [ map { 0 + $_->object } @logs ], [ ( $target->id ) x @logs ], 'every row identifies the exact target' );
    is_deeply( [ map { 0 + $_->user } @logs ],   [ ( $actor->id ) x @logs ],  'every row identifies the actor' );
    is_deeply(
        [ map { payload($_)->{auth_source} } @logs ], \@expected_auth_sources,
        'authentication source is recorded'
    );
    is_deeply(
        [ map { payload($_)->{api_client_id} } @logs ], \@expected_api_client_ids,
        'only OAuth responses record the authenticated API client identifier'
    );
    ok( !grep( { $_->info =~ /Disclosure audit test/ } @logs ), 'mutable API key descriptions are not copied' );
    is_deeply(
        [ map { payload($_)->{data_classes} } @logs ],
        [ map { [@expected_classes] } @logs ],
        'stored classes match each final Patron representation'
    );
    is(
        scalar( keys %{ { map { payload($_)->{event_id} => 1 } @logs } } ),
        scalar @logs,
        'persistent worker requests retain distinct server-generated event IDs'
    );
    ok(
        !grep( { payload($_)->{event_id} eq 'forged-client-event-id' } @logs ),
        'a client request ID is never adopted as the event ID'
    );

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'finalizer runs after later response post-processing hooks' => sub {
    $schema->storage->txn_begin;

    my ( $actor, $password ) = build_actor();
    my $target       = $builder->build_object( { class => 'Koha::Patrons' } );
    my $late_subject = $builder->build_object( { class => 'Koha::Patrons' } );

    $t->get_ok(
        '//' . $actor->userid . ":$password\@/api/v1/patrons/" . $target->id => {
            'x-koha-test-late-disclosure-subject' => $late_subject->id,
        }
    )->status_is(200);

    my @logs = disclosure_logs()->as_list;
    is_deeply(
        [ sort { $a <=> $b } map { 0 + $_->object } @logs ],
        [ sort { $a <=> $b } ( $target->id, $late_subject->id ) ],
        'the finalizer includes subjects added by a later response hook'
    );
    is(
        scalar( keys %{ { map { payload($_)->{event_id} => 1 } @logs } } ),
        1,
        'both subjects belong to the same response event'
    );

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'disabled, rejected, and failed responses disclose no unaudited Patron body' => sub {
    $schema->storage->txn_begin;

    my ( $actor, $password ) = build_actor();
    my $target = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => {
                branchcode => $actor->branchcode,
                surname    => 'AUDIT_PRIVATE_SENTINEL',
                email      => 'audit-private-sentinel@example.invalid',
            },
        }
    );
    my $credentials = '//' . $actor->userid . ":$password\@";

    t::lib::Mocks::mock_config( 'patron_data_disclosure_log', 0 );
    $t->get_ok( $credentials . '/api/v1/patrons/' . $target->id )
        ->status_is(200)
        ->json_is( '/surname' => 'AUDIT_PRIVATE_SENTINEL' );
    is( disclosure_logs()->count, 0, 'preference off leaves the response unchanged and writes no rows' );

    t::lib::Mocks::mock_config( 'patron_data_disclosure_log', 1 );
    $t->get_ok( $credentials . '/api/v1/patrons?patron_id=' . $target->id . '&_per_page=-1' )
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    $t->get_ok( $credentials . '/api/v1/patrons?patron_id=' . $target->id . '&_per_page=1001' )
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    is( disclosure_logs()->count, 0, 'rejected page sizes write no disclosure rows' );

    my $deleted_patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { protected => 0 },
        }
    );
    my $deleted_id = $deleted_patron->id;
    $deleted_patron->delete;
    $t->get_ok( $credentials . "/api/v1/patrons/$deleted_id" )->status_is(404);
    is( disclosure_logs()->count, 0, 'an error response writes no disclosure row' );

    t::lib::Mocks::mock_preference( 'AccessControlAllowOrigin', 'https://allowed.example.invalid' );
    {
        my $action_log_mock = Test::MockModule->new('Koha::ActionLog');
        $action_log_mock->redefine( store => sub { die "injected audit store failure\n" } );

        $t->get_ok( $credentials . '/api/v1/patrons/' . $target->id => { 'x-koha-request-id' => 'private-request-id' } )
            ->status_is(503)
            ->json_is(
            {
                error      => 'Service unavailable',
                error_code => 'patron_disclosure_audit_unavailable',
            }
            );
        unlike(
            $t->tx->res->body, qr/AUDIT_PRIVATE_SENTINEL|audit-private-sentinel/i,
            '503 body contains no Patron PII'
        );
        is( $t->tx->res->headers->header('x-koha-request-id'), undef,      'response correlation header is removed' );
        is( $t->tx->res->headers->cache_control,               'no-store', 'replacement response is not cacheable' );
        is( $t->tx->res->headers->header('Access-Control-Allow-Origin'),
            'https://allowed.example.invalid', 'trusted CORS origin survives the safe 503' );
        is( disclosure_logs()->count, 0, 'failed audit write leaves no partial disclosure event' );
    }

    t::lib::Mocks::mock_preference( 'AccessControlAllowOrigin', '' );
    $schema->storage->txn_rollback;
    done_testing;
};

had_no_warnings;
done_testing;
