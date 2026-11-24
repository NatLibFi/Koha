#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.

use Modern::Perl;

use Test::More;
use Test::Mojo;

use JSON       qw( encode_json );
use Mojo::Util qw( url_escape );

use Koha::Database;
use Koha::ILL::Requests;
use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
my $t       = Test::Mojo->new('Koha::REST::V1');

t::lib::Mocks::mock_preference( 'RESTBasicAuth',            1 );
t::lib::Mocks::mock_preference( 'ILLHiddenRequestStatuses', '' );

$schema->storage->txn_begin;

my $patron   = $builder->build_object( { class => 'Koha::Patrons', value => { flags => 2**22 } } );
my $outsider = $builder->build_object( { class => 'Koha::Patrons' } );
my $password = 'thePassword123';
$patron->set_password( { password => $password, skip_validation => 1 } );
my $userid    = $patron->userid;
my $patron_id = $patron->id;

my $shorter  = 'alpha@example.test; aardvark@example.test';
my $later    = 'alpha@example.test; zeta@example.test';
my @fixtures = (
    [ Standard => { Standard => $later } ],
    [ Other    => { Standard => 'hidden@example.test', Other => 'other@example.test' } ],
    [ Standard => { Standard => $shorter,              Other => 'stale@example.test' } ],
    [ Standard => { Standard => $shorter } ],
    [ Standard => { Other    => 'stale@example.test' } ],
    [ Standard => { Standard => 'beta@example.test' } ],
    [ Standard => { Standard => '' } ],
);
my @ids;
for my $fixture (@fixtures) {
    my ( $backend, $values ) = @{$fixture};
    my $request = $builder->build_object(
        {
            class => 'Koha::ILL::Requests',
            value => {
                backend  => $backend, borrowernumber => $patron_id, status => 'NEW',
                batch_id => undef,    notesstaff     => 'recipient sort fixtures',
            },
        }
    );
    my $id = $request->id;
    push @ids, $id;
    for my $attribute_backend ( sort keys %{$values} ) {
        $schema->resultset('Illrequestattribute')->create(
            {
                illrequest_id => $id,                  backend => $attribute_backend,
                type          => 'requested_partners', value   => $values->{$attribute_backend},
            }
        );
    }
}

for my $excluded ( [ $patron_id, 'different staff notes' ], [ $outsider->id, 'recipient sort fixtures' ] ) {
    $builder->build_object(
        {
            class => 'Koha::ILL::Requests',
            value => {
                backend  => 'Standard', borrowernumber => $excluded->[0], status => 'NEW',
                batch_id => undef,      notesstaff     => $excluded->[1],
            },
        }
    );
}

my $base_url    = "//$userid:$password\@/api/v1";
my $notes_query = { staff_notes => 'recipient sort fixtures' };
my @list_cases  = (
    [
        'ILL list with patron filter', '/ill/requests', { %{$notes_query}, patron_id => $patron_id },
        scalar Koha::ILL::Requests->count
    ],
    [ 'staff patron ILL endpoint', "/patrons/$patron_id/ill/requests", $notes_query, 1 + @ids ],
);
my @ordering = (
    [ 'ascending',     '%2Bme.last_request_sent_to', [ @ids[ 1, 4, 6 ], @ids[ 2, 3, 0 ], $ids[5] ] ],
    [ 'descending',    '-me.last_request_sent_to',   [ @ids[ 5, 0, 2 ], @ids[ 3, 1, 4 ], $ids[6] ] ],
    [ 'ID descending', '-me.ill_request_id',         [ reverse @ids ] ],
);

for my $list_case (@list_cases) {
    my ( $name, $path, $query, $base_total ) = @{$list_case};
    subtest $name => sub {
        my $encoded_query = url_escape( encode_json($query) );
        my $url           = "$base_url$path?q=$encoded_query";

        for my $ordering (@ordering) {
            my ( $direction, $order, $expected ) = @{$ordering};
            subtest $direction => sub {
                my @pages = ( [ @{$expected}[ 0 .. 2 ] ], [ @{$expected}[ 3 .. 5 ] ], [ $expected->[6] ] );
                for my $page ( 1 .. @pages ) {
                    $t->get_ok(
                        "$url&_order_by=$order&_per_page=3&_page=$page" => { 'x-koha-embed' => 'extended_attributes' } )
                        ->status_is(200)
                        ->header_is( 'X-Total-Count'      => scalar @ids )
                        ->header_is( 'X-Base-Total-Count' => $base_total );

                    my $rows = $t->tx->res->json;
                    is_deeply(
                        ref $rows eq 'ARRAY' ? [ map { $_->{ill_request_id} } @{$rows} ] : $rows,
                        $pages[ $page - 1 ], "page $page contains the expected requests in order",
                    );
                }
            };
        }
    };
}

$schema->storage->txn_rollback;
done_testing;
