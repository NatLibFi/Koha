#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Test::Exception;
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::NoWarnings qw( had_no_warnings );
use Scalar::Util     qw( blessed );

use Mojolicious::Lite;

use C4::Context;
use Koha::Patron::Disclosure;

{

    package Test::PatronDisclosure::Event;

    sub new {
        my ( $class, $params ) = @_;
        return bless {
            fail     => $params->{fail},
            subjects => [],
            commits  => 0,
        }, $class;
    }

    sub add_subject {
        my ( $self, $params ) = @_;
        push @{ $self->{subjects} }, $params;
        return $self;
    }

    sub commit {
        my ($self) = @_;
        die "patron disclosure finalizer ran before a later response hook\n"
            unless $main::later_response_hook_ran;
        $self->{commits}++;
        die "injected audit failure\n" if $self->{fail};
        return 'server-event-id';
    }
}

{

    package Test::PatronDisclosure::Serializable;

    our $received_collector;

    sub new {
        return bless {}, shift;
    }

    sub to_api {
        my ( $self, $params ) = @_;
        $received_collector = $params->{patron_disclosure} ? 1 : 0;
        if ( $params->{patron_disclosure} ) {
            $params->{patron_disclosure}->add_subject(
                {
                    patron_id    => 777,
                    data_classes => ['identity'],
                }
            );
        }
        return { patron_id => 777 };
    }
}

my $enabled   = 1;
my $fail_next = 0;
my @events;
my $query_count            = 0;
my $subject_limit          = 1000;
my $enablement_reads       = 0;
my $rest_default_page_size = 20;
my $seen_per_page;
our $later_response_hook_ran;

my $context_mock = Test::MockModule->new('C4::Context');
$context_mock->redefine(
    preference => sub {
        my ( $class, $name ) = @_;
        if ( $name eq Koha::Patron::Disclosure::PREFERENCE ) {
            $enablement_reads++;
            return $enabled;
        }
        return $subject_limit          if $name eq Koha::Patron::Disclosure::LIMIT_PREFERENCE;
        return $rest_default_page_size if $name eq 'RESTdefaultPageSize';
        return;
    }
);

my $disclosure_mock = Test::MockModule->new('Koha::Patron::Disclosure');
$disclosure_mock->redefine(
    new => sub {
        my $event = Test::PatronDisclosure::Event->new( { fail => $fail_next } );
        push @events, $event;
        return $event;
    }
);

hook after_dispatch => sub {
    my ($c) = @_;
    $c->patron_disclosure->finalize;
};

plugin 'Koha::REST::Plugin::PatronDisclosure';
plugin 'Koha::REST::Plugin::Objects';

hook before_dispatch => sub {
    $later_response_hook_ran = 0;
};

hook after_dispatch => sub {
    $later_response_hook_ran = 1;
};

sub operation_spec {
    my (%params) = @_;

    my $metadata = {
        surface          => $params{surface} // 'patrons.record.api',
        success_statuses => [200],
        strategies       => $params{strategies} // ['serialized_patrons'],
    };
    $metadata->{max_page_size}          = $params{max_page_size} if exists $params{max_page_size};
    $metadata->{subjects_per_page_item} = $params{subjects_per_page_item}
        if exists $params{subjects_per_page_item};
    $metadata->{fixed_subjects} = $params{fixed_subjects} if exists $params{fixed_subjects};
    $metadata->{path_patron}    = $params{path_patron}    if exists $params{path_patron};

    my @parameters;
    push @parameters, { '$ref' => '#/parameters/swagger_yaml-parameters_per_page' }
        if $params{paginated};

    return {
        parameters                 => \@parameters,
        responses                  => { '200' => {}, '404' => {} },
        'x-koha-patron-disclosure' => $metadata,
    };
}

sub initialize {
    my ( $c, $spec ) = @_;
    return $c->patron_disclosure->initialize(
        {
            spec        => $spec,
            actor_id    => 42,
            auth_source => 'session',
        }
    );
}

get '/path/:patron_id' => sub {
    my ($c) = @_;
    initialize(
        $c,
        operation_spec(
            strategies  => ['path_patron'],
            path_patron => {
                parameter    => 'patron_id',
                data_classes => ['circulation_current'],
            },
        )
    );
    $c->render( status => 200, json => { activity => [] } );
};

get '/page' => sub {
    my ($c) = @_;
    initialize(
        $c,
        operation_spec(
            paginated              => 1,
            max_page_size          => 2,
            subjects_per_page_item => 1,
        )
    );

    my $ok = eval {
        $c->patron_disclosure->validate_page_size;
        1;
    };
    unless ($ok) {
        my $error = $@;
        return $c->render( status => 503, json => { error => $error->error } )
            if blessed($error) && $error->isa('Koha::Exceptions::UnderMaintenance');
        return $c->render( status => 400, json => $error->error );
    }

    $seen_per_page = $c->req->query_params->to_hash->{_per_page};
    $query_count++;
    return $c->render( status => 200, json => [] );
};

get '/failure' => sub {
    my ($c) = @_;
    initialize( $c, operation_spec() );
    $c->patron_disclosure->add_subject(
        {
            patron_id    => 84,
            data_classes => ['identity'],
        }
    );
    $c->res->headers->header( 'x-koha-request-id'   => 'client-controlled' );
    $c->res->headers->header( 'Content-Disposition' => 'attachment; filename=private.json' );
    $c->res->headers->location('/private/location');
    if ( $c->param('xml') ) {
        $c->res->headers->content_type('application/xml');
        $c->res->body('<patron><surname>PRIVATE_SENTINEL</surname></patron>');
        return $c->rendered(200);
    }
    return $c->render( status => 200, json => { surname => 'PRIVATE_SENTINEL' } );
};

get '/explicit/:patron_id' => sub {
    my ($c) = @_;
    initialize( $c, operation_spec( strategies => ['explicit'] ) );
    $c->patron_disclosure->add_subject(
        {
            patron_id    => $c->param('patron_id'),
            data_classes => ['circulation_history'],
        }
    );
    $c->render( status => 200, json => { history => [] } );
};

get '/explicit-missing' => sub {
    my ($c) = @_;
    initialize( $c, operation_spec( strategies => ['explicit'] ) );
    $c->render( status => 200, json => { surname => 'PRIVATE_SENTINEL' } );
};

get '/objects-collector' => sub {
    my ($c) = @_;
    initialize( $c, operation_spec() );
    my $representation = $c->objects->to_api( Test::PatronDisclosure::Serializable->new );
    $c->render( status => 200, json => $representation );
};

get '/objects-without-serialized-collector/:patron_id' => sub {
    my ($c) = @_;
    initialize(
        $c,
        operation_spec(
            strategies  => ['path_patron'],
            path_patron => {
                parameter    => 'patron_id',
                data_classes => ['circulation_current'],
            },
        )
    );
    my $representation = $c->objects->to_api( Test::PatronDisclosure::Serializable->new );
    $c->render( status => 200, json => $representation );
};

my $t = Test::Mojo->new;

subtest 'path subjects are committed at the response boundary' => sub {
    plan tests => 5;

    @events           = ();
    $enabled          = 1;
    $enablement_reads = 0;
    $fail_next        = 0;

    $t->get_ok('/path/123')->status_is(200);
    is( $events[0]->{commits}, 1, 'the response event is committed once' );
    is_deeply(
        $events[0]->{subjects},
        [ { patron_id => 123, data_classes => ['circulation_current'] } ],
        'the validated path patron is the exact subject'
    );
    is( $enablement_reads, 1, 'enablement is sampled exactly once when the request event is created' );
};

subtest 'covered page ceilings reject unbounded work' => sub {
    plan tests => 31;

    @events        = ();
    $query_count   = 0;
    $enabled       = 1;
    $subject_limit = 1000;

    $rest_default_page_size = 3;
    $t->get_ok('/page')->status_is(200);
    is( $seen_per_page, 2, 'an oversized implicit REST default is clamped to the audit ceiling' );
    is( $query_count,   1, 'the clamped implicit default reaches the query boundary' );
    $rest_default_page_size = 20;

    $t->get_ok('/page?_per_page=-1')
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    $t->get_ok('/page?_per_page=3')->status_is(400)->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    $t->get_ok('/page?_per_page=two')
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    $t->get_ok('/page?_per_page=2&_per_page=-1')
        ->status_is(400)
        ->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    is( $query_count, 1, 'rejected page sizes do not advance past the successful default request' );

    $t->get_ok('/page?_per_page=2')->status_is(200);
    is( $query_count,           2, 'the declared maximum reaches the query boundary' );
    is( $events[-1]->{commits}, 1, 'the accepted response reaches finalization' );

    $subject_limit = 1;
    $t->get_ok('/page?_per_page=2')->status_is(400)->json_is( '/error_code' => 'patron_disclosure_page_size_exceeded' );
    $t->get_ok('/page?_per_page=1')->status_is(200);
    is( $query_count, 3, 'the configured subject limit lowers the declared page ceiling' );

    $subject_limit = 0;
    $t->get_ok('/page?_per_page=1')->status_is(503)->json_is( '/error' => 'Patron disclosure auditing is unavailable' );
    is( $query_count, 3, 'an invalid subject limit cannot reach the query boundary' );
    $subject_limit = 1000;
};

subtest 'preference off leaves responses untouched' => sub {
    plan tests => 4;

    @events        = ();
    $enabled       = 0;
    $subject_limit = 1000;
    $query_count   = 0;

    $t->get_ok('/page?_per_page=-1')->status_is(200);
    is( $query_count,   1, 'the audit-only page ceiling is disabled' );
    is( scalar @events, 0, 'no request event is created' );
};

subtest 'audit failure replaces the complete response' => sub {
    plan tests => 9;

    @events    = ();
    $enabled   = 1;
    $fail_next = 1;

    $t->get_ok('/failure')
        ->status_is(503)
        ->json_is( '/error_code' => 'patron_disclosure_audit_unavailable' )
        ->content_unlike(qr/PRIVATE_SENTINEL/)
        ->header_is( 'Content-Type'        => 'application/json; charset=utf8' )
        ->header_is( 'Cache-Control'       => 'no-store' )
        ->header_is( 'x-koha-request-id'   => undef )
        ->header_is( 'Content-Disposition' => undef )
        ->header_is( 'Location'            => undef );
};

subtest 'audit failure replaces an XML representation after conversion' => sub {
    plan tests => 6;

    @events    = ();
    $enabled   = 1;
    $fail_next = 1;

    $t->get_ok('/failure?xml=1')
        ->status_is(503)
        ->content_unlike(qr/PRIVATE_SENTINEL/)
        ->header_is( 'Content-Type'  => 'application/json; charset=utf8' )
        ->header_is( 'Cache-Control' => 'no-store' );
    is( $events[0]->{commits}, 1, 'the converted response reaches the audit boundary once' );
};

subtest 'explicit collection is enforced at the response boundary' => sub {
    plan tests => 8;

    @events    = ();
    $enabled   = 1;
    $fail_next = 0;

    $t->get_ok('/explicit/321')->status_is(200);
    is_deeply(
        $events[0]->{subjects},
        [ { patron_id => 321, data_classes => ['circulation_history'] } ],
        'the controller supplies the exact explicit subject'
    );
    is( $events[0]->{commits}, 1, 'a completed explicit event is committed' );

    @events = ();
    $t->get_ok('/explicit-missing')->status_is(503)->content_unlike(qr/PRIVATE_SENTINEL/);
    is( $events[0]->{commits}, 0, 'an omitted explicit collector cannot commit an empty event' );
};

subtest 'objects.to_api passes the request collector to serializers' => sub {
    plan tests => 5;

    @events    = ();
    $enabled   = 1;
    $fail_next = 0;

    $t->get_ok('/objects-collector')->status_is(200)->json_is( '/patron_id' => 777 );
    is(
        $Test::PatronDisclosure::Serializable::received_collector, 1,
        'the declared serialized strategy enables its collector'
    );
    is_deeply(
        $events[0]->{subjects},
        [ { patron_id => 777, data_classes => ['identity'] } ],
        'the serializer receives the enabled request-local collector'
    );
};

subtest 'objects.to_api leaves non-Patron serializers available without a serialized strategy' => sub {
    plan tests => 5;

    @events    = ();
    $enabled   = 1;
    $fail_next = 0;

    $t->get_ok('/objects-without-serialized-collector/778')->status_is(200)->json_is( '/patron_id' => 777 );
    is(
        $Test::PatronDisclosure::Serializable::received_collector,
        0,
        'a non-Patron serializer does not receive a collector without the serialized_patrons strategy'
    );
    is_deeply(
        $events[0]->{subjects},
        [ { patron_id => 778, data_classes => ['circulation_current'] } ],
        'the independently declared path strategy remains active'
    );
};

subtest 'invalid covered metadata fails validation' => sub {
    plan tests => 6;

    $subject_limit = 0;
    throws_ok { Koha::Patron::Disclosure->max_subjects }
    qr/StaffPatronDataDisclosureMaxSubjects must be a positive integer/,
        'an invalid subject-limit preference fails with its stable name';
    $subject_limit = 1000;

    throws_ok {
        Koha::REST::Plugin::PatronDisclosure::_normalize_metadata(
            operation_spec( paginated => 1 )->{'x-koha-patron-disclosure'},
            operation_spec( paginated => 1 ),
        );
    }
    qr/must declare max_page_size and subjects_per_page_item/,
        'paginated Patron serialization requires an explicit fan-out ceiling';

    throws_ok {
        my $spec = operation_spec();
        $spec->{'x-koha-patron-disclosure'}->{future_key} = 1;
        Koha::REST::Plugin::PatronDisclosure::_normalize_metadata( $spec->{'x-koha-patron-disclosure'}, $spec );
    }
    qr/unknown key.*future_key/i, 'unknown metadata cannot silently alter the contract';

    throws_ok {
        my $spec = operation_spec();
        $spec->{responses}->{404}                               = {};
        $spec->{'x-koha-patron-disclosure'}->{success_statuses} = [404];
        Koha::REST::Plugin::PatronDisclosure::_normalize_metadata( $spec->{'x-koha-patron-disclosure'}, $spec );
    }
    qr/must be successful HTTP status integers/, 'an error response cannot be declared as a disclosure success';

    throws_ok {
        my $spec = operation_spec();
        $spec->{'x-koha-patron-disclosure'}->{success_statuses} = [ 200, 200 ];
        Koha::REST::Plugin::PatronDisclosure::_normalize_metadata( $spec->{'x-koha-patron-disclosure'}, $spec );
    }
    qr/Duplicate patron disclosure success status/, 'duplicate successful statuses are rejected';

    lives_ok {
        my $spec = operation_spec( strategies => ['explicit'] );
        Koha::REST::Plugin::PatronDisclosure::_normalize_metadata( $spec->{'x-koha-patron-disclosure'}, $spec );
    }
    'the explicit strategy is accepted with response-bound completion enforcement';
};

had_no_warnings;
done_testing;
