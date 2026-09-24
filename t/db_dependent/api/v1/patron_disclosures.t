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
use Module::Load::Conditional qw( can_load );
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
t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',         1 );
t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );

my $t = Test::Mojo->new('Koha::REST::V1');

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
        },
        { order_by => 'action_id' }
    );
}

sub clear_disclosure_logs {
    disclosure_logs()->delete;
    return;
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
    clear_disclosure_logs();

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

    if ( can_load( modules => { 'Net::OAuth2::AuthorizationServer' => undef } ) ) {
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
    } else {
        note 'OAuth request skipped because Net::OAuth2::AuthorizationServer is unavailable';
    }

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
    clear_disclosure_logs();

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
    clear_disclosure_logs();

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

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 0 );
    $t->get_ok( $credentials . '/api/v1/patrons/' . $target->id )
        ->status_is(200)
        ->json_is( '/surname' => 'AUDIT_PRIVATE_SENTINEL' );
    is( disclosure_logs()->count, 0, 'preference off leaves the response unchanged and writes no rows' );

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 1 );
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
        is( disclosure_logs()->count, 0, 'failed audit write leaves no partial disclosure event' );
    }

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'nested item embeds log only Patrons serialized in one response' => sub {
    $schema->storage->txn_begin;
    clear_disclosure_logs();

    my ( $actor, $password ) = build_actor();
    my $biblio          = $builder->build_sample_biblio;
    my $checkout_patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $hold_patron     = $builder->build_object( { class => 'Koha::Patrons' } );
    my $recall_patron   = $builder->build_object( { class => 'Koha::Patrons' } );
    my $claim_patron    = $builder->build_object( { class => 'Koha::Patrons' } );
    my $unrelated       = $builder->build_object( { class => 'Koha::Patrons' } );
    my $checkout_item   = $builder->build_sample_item( { biblionumber => $biblio->id } );
    my $hold_item       = $builder->build_sample_item( { biblionumber => $biblio->id } );
    my $recall_item     = $builder->build_sample_item( { biblionumber => $biblio->id } );
    my $claim_item      = $builder->build_sample_item( { biblionumber => $biblio->id } );

    $builder->build_object(
        {
            class => 'Koha::Checkouts',
            value => {
                borrowernumber => $checkout_patron->id,
                itemnumber     => $checkout_item->id,
                branchcode     => $checkout_item->holdingbranch,
            },
        }
    );
    $builder->build_object(
        {
            class => 'Koha::Holds',
            value => {
                borrowernumber => $hold_patron->id,
                biblionumber   => $biblio->id,
                itemnumber     => $hold_item->id,
                branchcode     => $hold_item->holdingbranch,
                found          => undef,
                priority       => 1,
                reservedate    => dt_from_string()->subtract( days => 1 )->ymd,
                suspend        => 0,
                waitingdate    => undef,
            },
        }
    );
    $builder->build_object(
        {
            class => 'Koha::Recalls',
            value => {
                patron_id         => $recall_patron->id,
                biblio_id         => $biblio->id,
                item_id           => $recall_item->id,
                pickup_library_id => $recall_item->holdingbranch,
                status            => 'requested',
                completed         => 0,
            },
        }
    );
    $builder->build_object(
        {
            class => 'Koha::Checkouts::ReturnClaims',
            value => {
                itemnumber     => $claim_item->id,
                borrowernumber => $claim_patron->id,
                created_by     => $actor->id,
            },
        }
    );

    my $path = '/api/v1/biblios/' . $biblio->id . '/items?_order_by=item_id';
    $t->get_ok( '//'
            . $actor->userid
            . ":$password\@$path" => { 'x-koha-embed' => 'checkout.patron,first_hold.patron,recall.patron' } )
        ->status_is(200);

    my @representations;
    for my $item ( @{ $t->tx->res->json } ) {
        for my $relation (qw( checkout first_hold recall )) {
            push @representations, $item->{$relation}->{patron}
                if ref( $item->{$relation} ) eq 'HASH' && ref( $item->{$relation}->{patron} ) eq 'HASH';
        }
    }
    my %response_subjects = map  { $_->{patron_id} => 1 } @representations;
    my @response_ids      = sort { $a <=> $b } keys %response_subjects;
    my @expected_ids      = sort { $a <=> $b } map { $_->id } ( $checkout_patron, $hold_patron, $recall_patron );
    is_deeply( \@response_ids, \@expected_ids, 'fixture serialized all three distinct nested Patron subjects' );

    my @logs = disclosure_logs()->as_list;
    is_deeply( [ map { 0 + $_->object } @logs ], \@expected_ids, 'only serialized Patron IDs are logged' );
    ok( !grep( { $_->object == $unrelated->id } @logs ), 'unrelated server-side Patron is not logged' );
    is(
        scalar( keys %{ { map { payload($_)->{event_id} => 1 } @logs } } ),
        1,
        'all nested patrons share one response event ID'
    );
    is_deeply(
        [ map { payload($_)->{surface} } @logs ],
        [ ('catalogue.items.patron_status') x @logs ],
        'nested rows use the stable item-status surface'
    );

    clear_disclosure_logs();
    $t->get_ok( '//'
            . $actor->userid
            . ":$password\@$path" => { 'x-koha-embed' => 'checkout,first_hold,recall,return_claims' } )->status_is(200);
    my @reference_ids =
        sort { $a <=> $b } map { $_->id } ( $checkout_patron, $hold_patron, $recall_patron, $claim_patron );
    is_deeply(
        [ map { 0 + $_->object } disclosure_logs()->as_list ],
        \@reference_ids,
        'bare patron-owner references in non-Patron representations are logged'
    );

    clear_disclosure_logs();
    $t->get_ok( '//' . $actor->userid . ":$password\@$path" )->status_is(200);
    is( disclosure_logs()->count, 0, 'the same item response without Patron embeds creates no disclosure row' );

    $t->get_ok( '//' . $actor->userid . ":$password\@$path&_per_page=-1" )
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    is( disclosure_logs()->count, 0, 'an unbounded item request is rejected before disclosure' );

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 2 );
    $t->get_ok( '//'
            . $actor->userid
            . ":$password\@$path" => { 'x-koha-embed' => 'checkout.patron,first_hold.patron,recall.patron' } )
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    is( disclosure_logs()->count, 0, 'the fan-out ceiling rejects work before writing a nested event' );
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects', 1000 );

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'staff booking APIs log exact booking and checkout patrons' => sub {
    $schema->storage->txn_begin;
    clear_disclosure_logs();

    my ( $actor, $password ) = build_actor();
    my $booking_patron  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $checkout_patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $biblio          = $builder->build_sample_biblio;
    my $item            = $builder->build_sample_item( { biblionumber => $biblio->id, bookable => 1 } );
    my $booking         = $builder->build_object(
        {
            class => 'Koha::Bookings',
            value => {
                biblio_id         => $biblio->id,
                item_id           => $item->id,
                patron_id         => $booking_patron->id,
                pickup_library_id => $item->holdingbranch,
                start_date        => dt_from_string->add( days => 2 )->truncate( to => 'day' ),
                end_date          => dt_from_string->add( days => 4 )->truncate( to => 'day' ),
            },
        }
    );
    $builder->build_object(
        {
            class => 'Koha::Checkouts',
            value => {
                borrowernumber => $checkout_patron->id,
                itemnumber     => $item->id,
                branchcode     => $item->holdingbranch,
            },
        }
    );

    my $credentials = '//' . $actor->userid . ":$password\@";
    my $path        = '/api/v1/bookings?biblio_id=' . $biblio->id;
    $t->get_ok( $credentials . $path => { 'x-koha-embed' => 'item.checkout,patron' } )->status_is(200);

    my @logs = disclosure_logs()->as_list;
    is_deeply(
        [ sort { $a <=> $b } map { 0 + $_->object } @logs ],
        [ sort { $a <=> $b } ( $booking_patron->id, $checkout_patron->id ) ],
        'the booking owner and nested current-checkout owner are exact subjects'
    );
    is(
        scalar( keys %{ { map { payload($_)->{event_id} => 1 } @logs } } ),
        1,
        'booking and checkout patrons share one response event'
    );
    my %classes = map { $_->object => payload($_)->{data_classes} } @logs;
    ok( grep( { $_ eq 'service_activity' } @{ $classes{ $booking_patron->id } } ), 'booking activity is classified' );
    is_deeply(
        $classes{ $checkout_patron->id },
        [qw( circulation_current identity )],
        'the nested checkout owner is current circulation data'
    );

    clear_disclosure_logs();
    $path = '/api/v1/biblios/' . $biblio->id . '/bookings';
    $t->get_ok( $credentials . $path => { 'x-koha-embed' => 'patron' } )->status_is(200);
    my $log = disclosure_logs()->single;
    is( 0 + $log->object,         $booking_patron->id,            'record bookings identify the exact patron' );
    is( payload($log)->{surface}, 'catalogue.bookings.by_record', 'record-booking surface is stable' );

    clear_disclosure_logs();
    $path = '/api/v1/biblios/' . $biblio->id . '/checkouts';
    $t->get_ok( $credentials . $path )->status_is(200);
    $log = disclosure_logs()->single;
    is( 0 + $log->object,         $checkout_patron->id,            'record checkouts identify the exact patron' );
    is( payload($log)->{surface}, 'catalogue.checkouts.by_record', 'record-checkout surface is stable' );

    for my $pickup_case (
        {
            path    => '/api/v1/biblios/' . $biblio->id . '/pickup_locations?patron_id=' . $booking_patron->id,
            surface => 'catalogue.biblio_pickup_locations.for_patron',
            label   => 'record',
        },
        {
            path    => '/api/v1/items/' . $item->id . '/pickup_locations?patron_id=' . $booking_patron->id,
            surface => 'catalogue.item_pickup_locations.for_patron',
            label   => 'item',
        },
        )
    {
        clear_disclosure_logs();
        $t->get_ok( $credentials . $pickup_case->{path} )->status_is(200);
        $log = disclosure_logs()->single;
        is(
            0 + $log->object, $booking_patron->id,
            "$pickup_case->{label} pickup eligibility identifies the exact patron"
        );
        is( payload($log)->{surface}, $pickup_case->{surface}, "$pickup_case->{label} pickup surface is stable" );
        is_deeply(
            payload($log)->{data_classes},
            [qw( identity service_activity )],
            "$pickup_case->{label} pickup eligibility is classified"
        );
    }

    for my $unbounded_path (
        '/api/v1/bookings?biblio_id=' . $biblio->id . '&_per_page=-1',
        '/api/v1/biblios/' . $biblio->id . '/bookings?_per_page=-1',
        '/api/v1/biblios/' . $biblio->id . '/checkouts?_per_page=-1'
        )
    {
        clear_disclosure_logs();
        $t->get_ok( $credentials . $unbounded_path )
            ->status_is(400)
            ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
        is( disclosure_logs()->count, 0, 'an unbounded booking workflow response writes no audit row' );
    }

    $booking->delete;
    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'serialized staff patron data remains an auditable subject' => sub {
    $schema->storage->txn_begin;
    clear_disclosure_logs();

    my ( $actor, $password ) = build_actor();
    my $target = $builder->build_object( { class => 'Koha::Patrons' } );
    my $issuer = $builder->build_object( { class => 'Koha::Patrons' } );
    my $item   = $builder->build_sample_item;
    $builder->build_object(
        {
            class => 'Koha::Checkouts',
            value => {
                borrowernumber => $target->id,
                itemnumber     => $item->id,
                branchcode     => $item->holdingbranch,
                issuer_id      => $issuer->id,
            },
        }
    );

    my $path = '/api/v1/patrons/' . $target->id . '/checkouts';
    $t->get_ok( '//' . $actor->userid . ":$password\@$path" => { 'x-koha-embed' => 'issuer' } )->status_is(200);

    my @logs = disclosure_logs()->as_list;
    is_deeply(
        [ sort { $a <=> $b } map { 0 + $_->object } @logs ],
        [ sort { $a <=> $b } ( $target->id, $issuer->id ) ],
        'the scoped customer and serialized staff account are both exact disclosure subjects'
    );
    is(
        scalar( keys %{ { map { payload($_)->{event_id} => 1 } @logs } } ),
        1,
        'customer and staff subjects share the response event ID'
    );

    clear_disclosure_logs();
    $t->get_ok( '//' . $actor->userid . ":$password\@$path?_per_page=-1" )
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    is( disclosure_logs()->count, 0, 'an unbounded checkout request is rejected before disclosure' );

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'empty patron activity response still identifies its path Patron' => sub {
    $schema->storage->txn_begin;
    clear_disclosure_logs();

    my ( $actor, $password ) = build_actor();
    my $target = $builder->build_object( { class => 'Koha::Patrons' } );
    my $path   = '/api/v1/patrons/' . $target->id . '/checkouts';

    $t->get_ok( '//' . $actor->userid . ":$password\@$path" )->status_is(200)->json_is( [] );
    my $log = disclosure_logs()->single;
    is( 0 + $log->object,         $target->id,                 'path Patron is logged for an empty representation' );
    is( payload($log)->{surface}, 'patrons.checkouts.current', 'activity surface is stable' );
    is_deeply(
        payload($log)->{data_classes},
        [qw( circulation_current identity )],
        'the path identifier and activity class are explicit'
    );

    clear_disclosure_logs();
    $path = '/api/v1/patrons/' . $target->id . '/holds';
    $t->get_ok( '//' . $actor->userid . ":$password\@$path" )->status_is(200)->json_is( [] );
    $log = disclosure_logs()->single;
    is( 0 + $log->object,         $target->id,          'an empty current-holds response logs its explicit target' );
    is( payload($log)->{surface}, 'patrons.holds.list', 'current and historical holds share a stable list surface' );
    is_deeply(
        payload($log)->{data_classes},
        [qw( circulation_current identity )],
        'current holds include the path identity and current class'
    );

    clear_disclosure_logs();
    $t->get_ok( '//' . $actor->userid . ":$password\@$path?old=1" )->status_is(200)->json_is( [] );
    $log = disclosure_logs()->single;
    is( 0 + $log->object, $target->id, 'an empty old-holds response logs its explicit target' );
    is_deeply(
        payload($log)->{data_classes},
        [qw( circulation_history identity )],
        'old holds include the path identity and history class'
    );

    clear_disclosure_logs();
    $t->get_ok( '//' . $actor->userid . ":$password\@$path?_per_page=-1" )->status_is(200);
    is( disclosure_logs()->count, 1, 'a single-subject activity response needs no audit-only page ceiling' );

    $schema->storage->txn_rollback;
    done_testing;
};

had_no_warnings;
done_testing;
