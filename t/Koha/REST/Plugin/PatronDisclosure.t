#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Test::MockModule;
use Test::More;
use Test::Mojo;
use Mojolicious::Lite;

use C4::Context;
use Koha::Patron::Disclosure;

{
    package Test::PatronDisclosure::Event;

    sub new {
        return bless {}, shift;
    }

    sub add_subject {
        my ( $self, $params ) = @_;
        $self->{subject} = $params;
        return $self;
    }

    sub commit {
        die "injected storage failure\n" if $main::fail_next;
        return 'event-id';
    }
}

our $fail_next = 1;
our $enabled   = 1;
my $cors_origin = 'https://allowed.example.invalid';
my $disclosure_mock = Test::MockModule->new('Koha::Patron::Disclosure');
$disclosure_mock->redefine( enabled => sub { return $enabled } );
$disclosure_mock->redefine( new => sub { return Test::PatronDisclosure::Event->new } );
my $context_mock = Test::MockModule->new('C4::Context');
$context_mock->redefine(
    preference => sub {
        my ( $class, $name ) = @_;
        return $cors_origin if $name eq 'AccessControlAllowOrigin';
        return;
    }
);

plugin 'Koha::REST::Plugin::PatronDisclosure';
hook after_dispatch => sub {
    my ($c) = @_;
    $c->patron_disclosure->finalize;
};

get '/disclosure' => sub {
    my ($c) = @_;
    $c->patron_disclosure->initialize(
        {
            spec        => { 'x-koha-patron-disclosure' => 'GET /patrons/{patron_id}' },
            actor_id    => 42,
            auth_source => 'session',
        }
    );
    $c->patron_disclosure->add_subject( { patron_id => 77, data_classes => ['identity'] } );
    $c->res->headers->header( 'x-koha-request-id'   => 'client-controlled' );
    $c->res->headers->header( 'Content-Disposition' => 'attachment; filename=private.json' );
    $c->res->headers->location('/private/location');
    if ( $c->param('xml') ) {
        $c->res->headers->content_type('application/xml');
        $c->res->body('<patron>PRIVATE_SENTINEL</patron>');
        return $c->rendered(200);
    }
    return $c->render( status => 200, json => { surname => 'PRIVATE_SENTINEL' } );
};

my $t = Test::Mojo->new;
$t->get_ok('/disclosure')
    ->status_is(503)
    ->json_is( '/error_code' => 'patron_disclosure_audit_unavailable' )
    ->content_unlike(qr/PRIVATE_SENTINEL/)
    ->header_is( 'Content-Type'                => 'application/json; charset=utf8' )
    ->header_is( 'Cache-Control'               => 'no-store' )
    ->header_is( 'Access-Control-Allow-Origin' => $cors_origin )
    ->header_is( 'x-koha-request-id'           => undef )
    ->header_is( 'Content-Disposition'         => undef )
    ->header_is( 'Location'                    => undef );

$t->get_ok('/disclosure?xml=1')
    ->status_is(503)
    ->json_is( '/error_code' => 'patron_disclosure_audit_unavailable' )
    ->content_unlike(qr/PRIVATE_SENTINEL/)
    ->header_is( 'Content-Type' => 'application/json; charset=utf8' );

$cors_origin = '';
$t->get_ok('/disclosure')->status_is(503)->header_is( 'Access-Control-Allow-Origin' => undef );

$fail_next = 0;
$t->get_ok('/disclosure')->status_is(200)->json_is( '/surname' => 'PRIVATE_SENTINEL' );
$enabled = 0;
$t->get_ok('/disclosure')->status_is(200)->json_is( '/surname' => 'PRIVATE_SENTINEL' );

done_testing;
