#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More;
use Test::NoWarnings 'had_no_warnings';
use Test::MockModule;
use Test::Mojo;
use Mojo::JSON qw( encode_json );
use Mojo::URL;

use Koha::Database;
use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

$schema->storage->txn_begin;

my $indexer = Test::MockModule->new('Koha::SearchEngine::Indexer');
$indexer->mock( index_records => sub { return; } );
t::lib::Mocks::mock_preference( 'RESTBasicAuth',            1 );
t::lib::Mocks::mock_preference( 'IndependentBranches',      0 );
t::lib::Mocks::mock_preference( 'AllowHoldsOnDamagedItems', 0 );

my $staff    = $builder->build_object( { class => 'Koha::Patrons', value => { flags => 64 } } );
my $password = 'thePassword123';
$staff->set_password( { password => $password, skip_validation => 1 } );
my $userid = $staff->userid;
my $t      = Test::Mojo->new('Koha::REST::V1');

my $biblio = $builder->build_sample_biblio;
my @holds;
for my $closed_stack ( 1, 0 ) {
    my $item = $builder->build_sample_item(
        {
            biblionumber    => $biblio->id,
            library         => $staff->branchcode,
            is_closed_stack => $closed_stack,
            itemlost        => 0, withdrawn => 0, damaged => 0, notforloan => 0, onloan => undef,
        }
    );
    push @holds, $builder->build_object(
        {
            class => 'Koha::Holds',
            value => {
                biblionumber    => $biblio->id,        itemnumber    => $item->id,
                borrowernumber  => $staff->id,         branchcode    => $staff->branchcode,
                priority        => scalar(@holds) + 1, suspend       => 0, found => undef,
                item_level_hold => 1,                  hold_group_id => undef,
            },
        }
    );
}
my $old_hold = $builder->build_object(
    {
        class => 'Koha::Old::Holds',
        value => {
            biblionumber   => $biblio->id, itemnumber => $holds[0]->itemnumber,
            borrowernumber => $staff->id,  branchcode => $staff->branchcode,
        },
    }
);

my $url = Mojo::URL->new("//$userid:$password\@/api/v1/holds");

subtest 'Current holds can be selected by closed stack classification' => sub {
    for my $enabled ( 1, 0 ) {
        t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
        for my $selector ( 'true', 'false', undef ) {
            my %query = ( biblio_id => $biblio->id );
            $query{closed_stack_request} = $selector if defined $selector;
            $t->get_ok( $url->clone->query( \%query ) )->status_is(200);
            my @expected;
            if ( !defined $selector || !$enabled && $selector eq 'false' ) {
                @expected = map { $_->id } @holds;
            } elsif ($enabled) {
                @expected = ( $selector eq 'true' ? $holds[0]->id : $holds[1]->id );
            }
            my $response = $t->tx->res->json;
            my $is_list  = ref($response) eq 'ARRAY'
                && !grep { ref($_) ne 'HASH' || !defined $_->{hold_id} } @$response;
            ok( $is_list, 'Listing response contains holds' );
            is_deeply(
                $is_list ? [ sort { $a <=> $b } map { $_->{hold_id} } @$response ] : undef,
                [ sort { $a <=> $b } @expected ],
                'Listing returns the selected holds, enabled=' . $enabled . ', selector=' . ( $selector // 'omitted' )
            );
            $t->header_is( 'X-Total-Count' => scalar @expected );
        }
    }
};

subtest 'Public queries, embeds and existing listing controls compose with the selector' => sub {
    t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
    $t->get_ok(
        $url->clone->query(
            {
                q                    => encode_json( { 'me.biblio_id' => $biblio->id } ),
                closed_stack_request => 'true',
            }
        ) => { 'x-koha-embed' => 'biblio,item' }
        )
        ->status_is(200)
        ->json_is( '/0/hold_id'          => $holds[0]->id )
        ->json_is( '/0/biblio/biblio_id' => $biblio->id )
        ->json_is( '/0/item/item_id'     => $holds[0]->itemnumber )
        ->json_hasnt('/1');

    $t->get_ok( $url->clone->query( { biblio_id => $biblio->id, priority => 2, closed_stack_request => 'false' } ) )
        ->status_is(200)
        ->json_is( '/0/hold_id' => $holds[1]->id )
        ->json_hasnt('/1');

    $t->get_ok(
        $url->clone->query( { biblio_id => $biblio->id, _order_by => 'priority', _per_page => 1, _page => 2 } ) )
        ->status_is(200)
        ->json_is( '/0/hold_id' => $holds[1]->id )
        ->json_hasnt('/1')
        ->header_is( 'X-Total-Count' => 2 );
};

subtest 'Old holds retain their listing and reject active classification' => sub {
    for my $selector ( 'true', 'false' ) {
        $t->get_ok(
            $url->clone->query( { biblio_id => $biblio->id, old => 'true', closed_stack_request => $selector } ) )
            ->status_is(400)
            ->json_is( '/error' => 'Closed stack request filtering is only available for current holds' );
    }
    $t->get_ok( $url->clone->query( { biblio_id => $biblio->id, old => 'true' } ) )
        ->status_is(200)
        ->json_is( '/0/hold_id' => $old_hold->id )
        ->json_hasnt('/1');
};

$schema->storage->txn_rollback;
had_no_warnings;
done_testing;
