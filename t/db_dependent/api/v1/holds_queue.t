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

use Test::NoWarnings;
use Test::More tests => 7;
use Test::Mojo;
use Test::MockModule;

use t::lib::TestBuilder;
use t::lib::Mocks;

use Koha::Caches;
use Koha::Hold::HoldsQueueItems;
use Koha::Database;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

my $t = Test::Mojo->new('Koha::REST::V1');
t::lib::Mocks::mock_preference( 'RESTBasicAuth', 1 );

subtest 'list() tests' => sub {

    plan tests => 20;

    $schema->storage->txn_begin;

    Koha::Hold::HoldsQueueItems->delete;

    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**1 }    # circulate flag
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    my $patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 0 }
        }
    );
    $patron->set_password( { password => $password, skip_validation => 1 } );
    my $unauth_userid = $patron->userid;

    # Unauthorized access
    $t->get_ok("//$unauth_userid:$password\@/api/v1/holds/queue")->status_is(403);

    # No items in queue
    $t->get_ok("//$userid:$password\@/api/v1/holds/queue")->status_is(200)->json_is( [] );

    # Build test data
    my $biblio      = $builder->build_sample_biblio;
    my $item        = $builder->build_sample_item( { biblionumber => $biblio->biblionumber } );
    my $hold_patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $library     = $builder->build_object( { class => 'Koha::Libraries' } );

    my $queue_item = $builder->build_object(
        {
            class => 'Koha::Hold::HoldsQueueItems',
            value => {
                biblionumber       => $biblio->biblionumber,
                itemnumber         => $item->itemnumber,
                barcode            => $item->barcode,
                surname            => $hold_patron->surname,
                firstname          => $hold_patron->firstname,
                phone              => $hold_patron->phone,
                borrowernumber     => $hold_patron->borrowernumber,
                cardnumber         => $hold_patron->cardnumber,
                reservedate        => '2026-01-15',
                title              => $biblio->title,
                itemcallnumber     => $item->itemcallnumber,
                holdingbranch      => $item->holdingbranch,
                pickbranch         => $library->branchcode,
                notes              => 'Test note',
                item_level_request => 1,
            },
        }
    );

    # One item in queue
    $t->get_ok("//$userid:$password\@/api/v1/holds/queue")
        ->status_is(200)
        ->json_is( '/0/item_id'           => $item->itemnumber )
        ->json_is( '/0/biblio_id'         => $biblio->biblionumber )
        ->json_is( '/0/patron_id'         => $hold_patron->borrowernumber )
        ->json_is( '/0/pickup_library_id' => $library->branchcode )
        ->json_is( '/0/hold_date'         => '2026-01-15' )
        ->json_is( '/0/item_level'        => Mojo::JSON->true )
        ->json_is( '/0/notes'             => 'Test note' );

    # Filter by holding_library_id
    $t->get_ok( "//$userid:$password\@/api/v1/holds/queue?holding_library_id=" . $item->holdingbranch )
        ->status_is(200)
        ->json_is( '/0/item_id' => $item->itemnumber );

    # Filter returns empty for non-matching
    $t->get_ok("//$userid:$password\@/api/v1/holds/queue?holding_library_id=NONEXISTENT")
        ->status_is(200)
        ->json_is( [] );

    $schema->storage->txn_rollback;
};

subtest 'item_type_id and +strings tests' => sub {

    plan tests => 10;

    $schema->storage->txn_begin;

    Koha::Caches->get_instance('localization')->flush_all();
    Koha::Hold::HoldsQueueItems->delete;

    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**1 }    # circulate flag
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    my $itemtype = $builder->build_object(
        {
            class => 'Koha::ItemTypes',
            value => { description => 'Book' },
        }
    );

    my $biblio = $builder->build_sample_biblio;
    my $item   = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itype => $itemtype->itemtype } );
    my $hold_patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $library     = $builder->build_object( { class => 'Koha::Libraries' } );

    $builder->build_object(
        {
            class => 'Koha::Hold::HoldsQueueItems',
            value => {
                biblionumber      => $biblio->biblionumber,
                itemnumber        => $item->itemnumber,
                barcode           => $item->barcode,
                surname           => $hold_patron->surname,
                firstname         => $hold_patron->firstname,
                borrowernumber    => $hold_patron->borrowernumber,
                cardnumber        => $hold_patron->cardnumber,
                title             => $biblio->title,
                holdingbranch     => $item->holdingbranch,
                pickbranch        => $library->branchcode,
                item_type_id      => $itemtype->itemtype,
                itype_description => $itemtype->description,
            },
        }
    );

    # item_type_id exposes the materialized item type code
    $t->get_ok("//$userid:$password\@/api/v1/holds/queue")
        ->status_is(200)
        ->json_is( '/0/item_type_id'      => $itemtype->itemtype,    'item_type_id is the materialized itype code' )
        ->json_is( '/0/itype_description' => $itemtype->description, 'itype_description still exposed' );

    # Without a translation, +strings falls back to the base description
    $t->get_ok( "//$userid:$password\@/api/v1/holds/queue" => { 'x-koha-embed' => '+strings' } )
        ->status_is(200)
        ->json_is(
        '/0/_strings/item_type_id/str' => $itemtype->description,
        '+strings uses the base item type description when no translation exists'
        );

    # With a de-DE translation, +strings returns the translated description
    my $module = Test::MockModule->new('C4::Languages');
    $module->mock( _get_language_dirs => sub { return 'en', 'de-DE' } );

    $schema->resultset('Localization')->create(
        {
            entity      => 'itemtypes',
            code        => $itemtype->itemtype,
            property    => 'description',
            lang        => 'de-DE',
            translation => 'translated',
        }
    );
    Koha::Caches->get_instance('localization')->flush_all();

    $t->get_ok(
        "//$userid:$password\@/api/v1/holds/queue",
        { 'x-koha-embed' => '+strings', Cookie => 'KohaOpacLanguage=de-DE', 'Accept-Language' => 'en' }
    )->status_is(200)->json_is(
        '/0/_strings/item_type_id/str' => 'translated',
        'translations in _strings use the language set in the KohaOpacLanguage cookie'
    );

    Koha::Caches->get_instance('localization')->flush_all();

    $schema->storage->txn_rollback;
};

subtest 'sorting on embedded fields' => sub {

    plan tests => 12;

    $schema->storage->txn_begin;

    Koha::Hold::HoldsQueueItems->delete;

    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**1 }
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    my $biblio_a = $builder->build_sample_biblio( { title => 'Alpha' } );
    my $biblio_b = $builder->build_sample_biblio( { title => 'Zeta' } );

    my $item_a = $builder->build_sample_item( { biblionumber => $biblio_a->biblionumber } );
    my $item_b = $builder->build_sample_item( { biblionumber => $biblio_b->biblionumber } );

    my $patron_a = $builder->build_object( { class => 'Koha::Patrons', value => { surname => 'Adams' } } );
    my $patron_b = $builder->build_object( { class => 'Koha::Patrons', value => { surname => 'Zimmerman' } } );

    my $library = $builder->build_object( { class => 'Koha::Libraries' } );

    $builder->build_object(
        {
            class => 'Koha::Hold::HoldsQueueItems',
            value => {
                biblionumber   => $biblio_a->biblionumber,
                itemnumber     => $item_a->itemnumber,
                barcode        => $item_a->barcode,
                borrowernumber => $patron_a->borrowernumber,
                surname        => $patron_a->surname,
                firstname      => $patron_a->firstname,
                cardnumber     => $patron_a->cardnumber,
                pickbranch     => $library->branchcode,
                holdingbranch  => $item_a->holdingbranch,
                title          => $biblio_a->title,
            },
        }
    );

    $builder->build_object(
        {
            class => 'Koha::Hold::HoldsQueueItems',
            value => {
                biblionumber   => $biblio_b->biblionumber,
                itemnumber     => $item_b->itemnumber,
                barcode        => $item_b->barcode,
                borrowernumber => $patron_b->borrowernumber,
                surname        => $patron_b->surname,
                firstname      => $patron_b->firstname,
                cardnumber     => $patron_b->cardnumber,
                pickbranch     => $library->branchcode,
                holdingbranch  => $item_b->holdingbranch,
                title          => $biblio_b->title,
            },
        }
    );

    # Sort by patron.surname ascending
    $t->get_ok( "//$userid:$password\@/api/v1/holds/queue?_order_by=+patron.surname" =>
            { 'x-koha-embed' => 'biblio,patron,item' } )
        ->status_is(200)
        ->json_is( '/0/patron_id' => $patron_a->borrowernumber )
        ->json_is( '/1/patron_id' => $patron_b->borrowernumber );

    # Sort by patron.surname descending
    $t->get_ok( "//$userid:$password\@/api/v1/holds/queue?_order_by=-patron.surname" =>
            { 'x-koha-embed' => 'biblio,patron,item' } )
        ->status_is(200)
        ->json_is( '/0/patron_id' => $patron_b->borrowernumber )
        ->json_is( '/1/patron_id' => $patron_a->borrowernumber );

    # Sort by patron.category_id (should not 500)
    $t->get_ok(
        "//$userid:$password\@/api/v1/holds/queue?_order_by=+patron.category_id" => { 'x-koha-embed' => 'patron' } )
        ->status_is(200);

    # Sort by biblio.publisher (biblioitem field, should not 500)
    $t->get_ok(
        "//$userid:$password\@/api/v1/holds/queue?_order_by=+biblio.publisher" => { 'x-koha-embed' => 'biblio' } )
        ->status_is(200);

    $schema->storage->txn_rollback;
};

subtest 'call number ordering' => sub {

    $schema->storage->txn_begin;

    Koha::Hold::HoldsQueueItems->delete;

    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**1 },
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid  = $librarian->userid;
    my $patron  = $builder->build_object( { class => 'Koha::Patrons' } );
    my $library = $builder->build_object( { class => 'Koha::Libraries' } );

    # Plain text and classification orders differ. Include a shared classification
    # key, identical call numbers, and both NULL and empty classification keys.
    my @fixtures = (
        [ '100', '0000000100', 'Foxtrot' ],
        [ '20',  '0000000020', 'Echo' ],
        [ '30',  undef,        'Delta' ],
        [ '40',  '',           'Charlie' ],
        [ '21',  '0000000020', 'Alpha' ],
        [ '21',  '0000000020', 'Bravo' ],
    );
    my @items;
    my %callnumbers;

    for my $fixture (@fixtures) {
        my ( $callnumber, $cn_sort, $title ) = @$fixture;
        my $biblio = $builder->build_sample_biblio( { title => $title } );
        my $item   = $builder->build_sample_item(
            { biblionumber => $biblio->biblionumber, itemcallnumber => "Live $callnumber" } );

        # Set the stored key directly: Item->store would recalculate it. The queue
        # retains its own displayed call number even if the live item has changed.
        $item->_result->update( { cn_sort => $cn_sort } );
        push @items, $item->itemnumber;
        $callnumbers{ $item->itemnumber } = $callnumber;

        $builder->build_object(
            {
                class => 'Koha::Hold::HoldsQueueItems',
                value => {
                    biblionumber   => $biblio->biblionumber,
                    itemnumber     => $item->itemnumber,
                    barcode        => $item->barcode,
                    borrowernumber => $patron->borrowernumber,
                    surname        => $patron->surname,
                    firstname      => $patron->firstname,
                    cardnumber     => $patron->cardnumber,
                    pickbranch     => $library->branchcode,
                    holdingbranch  => $item->holdingbranch,
                    title          => $title,
                    itemcallnumber => $callnumber,
                },
            }
        );
    }

    # Stable item-number ties are part of the new contract in both modes.
    # The independent title-order check below is the existing-behavior control.
    my @alphabetical   = @items[ 0, 1, 4, 5, 2, 3 ];
    my @classification = @items[ 1, 4, 5, 0, 2, 3 ];
    my $url            = "//$userid:$password\@/api/v1/holds/queue";

    for my $mode ( 'alphabetical', 'classification', undef, '', 'unknown' ) {
        my $label = defined $mode ? "'$mode'" : 'missing';
        subtest "HoldsCallnumberSortQueue = $label" => sub {

            # Mocking also works on unpatched main, where the preference is absent.
            t::lib::Mocks::mock_preference( 'HoldsCallnumberSortQueue', $mode );
            my @ascending = defined $mode && $mode eq 'classification' ? @classification : @alphabetical;

            for my $direction ( 'asc', 'desc' ) {
                my @expected = $direction eq 'asc' ? @ascending      : reverse @ascending;
                my $order    = $direction eq 'asc' ? '%2Bcallnumber' : '-callnumber';
                $t->get_ok("$url?_order_by=$order&_per_page=-1")->status_is(200);
                my $rows = $t->tx->res->json;
                if ( is( ref($rows), 'ARRAY', "$direction response is an array" ) ) {
                    is_deeply( [ map { $_->{item_id} } @$rows ], \@expected, "$direction call number order" );
                    is_deeply(
                        [ map { $_->{callnumber} } @$rows ],
                        [ map { $callnumbers{$_} } @expected ],
                        'The displayed call numbers remain the queue values'
                    );
                }

                for my $page ( 1 .. 3 ) {

                    # Deliberately omit embeds: sorting must also work without
                    # the UI's item embed and must happen before pagination.
                    $t->get_ok("$url?_order_by=$order&_per_page=2&_page=$page")->status_is(200);
                    my @page_items = @expected[ ( $page - 1 ) * 2 .. $page * 2 - 1 ];
                    my $page_rows  = $t->tx->res->json;
                    if ( is( ref($page_rows), 'ARRAY', "$direction page $page response is an array" ) ) {
                        is_deeply(
                            [ map { $_->{item_id} } @$page_rows ],
                            \@page_items, "$direction page $page"
                        );
                    }
                }
            }

            # A previously supported embedded-field sort must stay independent.
            $t->get_ok( "$url?_order_by=%2Bbiblio.title&_per_page=-1" => { 'x-koha-embed' => 'biblio,item' } )
                ->status_is(200);
            my $title_rows = $t->tx->res->json;
            if ( is( ref($title_rows), 'ARRAY', 'Title-order response is an array' ) ) {
                is_deeply(
                    [ map { $_->{item_id} } @$title_rows ],
                    [ @items[ 4, 5, 3, 2, 1, 0 ] ], 'Title ordering is unaffected'
                );
            }
            done_testing;
        };
    }

    t::lib::Mocks::mock_preference( 'HoldsCallnumberSortQueue', 'classification' );

    # Match the UI's me. prefix to disambiguate the queue and embedded item.
    $t->get_ok( "$url?_order_by=%2Bme.callnumber,-biblio.title&_per_page=-1" => { 'x-koha-embed' => 'biblio,item' } )
        ->status_is(200);
    my $secondary_rows = $t->tx->res->json;
    if ( is( ref($secondary_rows), 'ARRAY', 'Secondary-order response is an array' ) ) {
        is_deeply(
            [ map { $_->{item_id} } @$secondary_rows ],
            [ @items[ 1, 5, 4, 0, 2, 3 ] ], 'Explicit secondary ordering precedes the item number tie breaker'
        );
    }

    $schema->storage->txn_rollback;
    done_testing;
};

subtest 'HidePatronName tests' => sub {

    plan tests => 14;

    $schema->storage->txn_begin;

    Koha::Hold::HoldsQueueItems->delete;

    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 2**1 }    # circulate flag
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    my $biblio      = $builder->build_sample_biblio;
    my $item        = $builder->build_sample_item( { biblionumber => $biblio->biblionumber } );
    my $hold_patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { surname => 'Smith', firstname => 'John' },
        }
    );
    my $library = $builder->build_object( { class => 'Koha::Libraries' } );

    $builder->build_object(
        {
            class => 'Koha::Hold::HoldsQueueItems',
            value => {
                biblionumber   => $biblio->biblionumber,
                itemnumber     => $item->itemnumber,
                barcode        => $item->barcode,
                surname        => $hold_patron->surname,
                firstname      => $hold_patron->firstname,
                borrowernumber => $hold_patron->borrowernumber,
                cardnumber     => $hold_patron->cardnumber,
                pickbranch     => $library->branchcode,
                holdingbranch  => $item->holdingbranch,
                title          => $biblio->title,
            },
        }
    );

    # HidePatronName OFF - full patron embed returned (not redacted)
    t::lib::Mocks::mock_preference( 'HidePatronName', 0 );

    $t->get_ok( "//$userid:$password\@/api/v1/holds/queue" => { 'x-koha-embed' => 'patron' } )
        ->status_is(200)
        ->json_has('/0/patron/library_id')
        ->json_has('/0/patron/surname')
        ->json_has('/0/patron/firstname');

    # HidePatronName ON - patron redacted to only allowed keys
    t::lib::Mocks::mock_preference( 'HidePatronName', 1 );

    my $tx =
        $t->get_ok( "//$userid:$password\@/api/v1/holds/queue" => { 'x-koha-embed' => 'patron,patron.library' } )
        ->status_is(200)
        ->json_hasnt('/0/patron/surname')
        ->json_hasnt('/0/patron/firstname')
        ->json_has('/0/patron/library_id')
        ->json_has('/0/patron/library');

    # HidePatronName ON applies even to superlibrarians
    my $superlibrarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 1 }     # superlibrarian
        }
    );
    $superlibrarian->set_password( { password => $password, skip_validation => 1 } );
    my $super_userid = $superlibrarian->userid;

    $t->get_ok( "//$super_userid:$password\@/api/v1/holds/queue" => { 'x-koha-embed' => 'patron' } )
        ->status_is(200)
        ->json_hasnt('/0/patron/surname');

    $schema->storage->txn_rollback;
};

subtest 'patron visibility across libraries tests' => sub {

    plan tests => 9;

    $schema->storage->txn_begin;

    Koha::Hold::HoldsQueueItems->delete;

    t::lib::Mocks::mock_preference( 'HidePatronName',      0 );
    t::lib::Mocks::mock_preference( 'IndependentBranches', 0 );

    my $library_staff  = $builder->build_object( { class => 'Koha::Libraries' } );
    my $library_patron = $builder->build_object( { class => 'Koha::Libraries' } );

    # Staff user restricted to their own library: only 'circulate_remaining_permissions'
    # (no 'view_borrower_infos_from_any_libraries')
    my $librarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => {
                branchcode => $library_staff->branchcode,
                flags      => 0,
            }
        }
    );
    $builder->build(
        {
            source => 'UserPermission',
            value  => {
                borrowernumber => $librarian->borrowernumber,
                module_bit     => 1,                                   # circulate
                code           => 'circulate_remaining_permissions',
            },
        }
    );
    my $password = 'thePassword123';
    $librarian->set_password( { password => $password, skip_validation => 1 } );
    my $userid = $librarian->userid;

    # A patron belonging to a *different* library
    my $hold_patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => {
                branchcode => $library_patron->branchcode,
                surname    => 'Smith',
                firstname  => 'John',
            },
        }
    );

    my $biblio = $builder->build_sample_biblio;
    my $item   = $builder->build_sample_item( { biblionumber => $biblio->biblionumber } );

    $builder->build_object(
        {
            class => 'Koha::Hold::HoldsQueueItems',
            value => {
                biblionumber   => $biblio->biblionumber,
                itemnumber     => $item->itemnumber,
                barcode        => $item->barcode,
                surname        => $hold_patron->surname,
                firstname      => $hold_patron->firstname,
                borrowernumber => $hold_patron->borrowernumber,
                cardnumber     => $hold_patron->cardnumber,
                pickbranch     => $library_patron->branchcode,
                holdingbranch  => $item->holdingbranch,
                title          => $biblio->title,
            },
        }
    );

    # The staff user cannot see patrons from the patron's library: identifying
    # fields are redacted, but library_id survives (unredact_list) so the UI can
    # still render "A patron from library X".
    $t->get_ok( "//$userid:$password\@/api/v1/holds/queue" => { 'x-koha-embed' => 'patron' } )
        ->status_is(200)
        ->json_is( '/0/patron/surname'    => undef, 'surname redacted for cross-library patron' )
        ->json_is( '/0/patron/firstname'  => undef, 'firstname redacted for cross-library patron' )
        ->json_is( '/0/patron/cardnumber' => undef, 'cardnumber redacted for cross-library patron' )
        ->json_is(
        '/0/patron/library_id' => $library_patron->branchcode,
        'library_id kept so the UI can show "A patron from library X"'
        );

    # A superlibrarian sees everything
    my $superlibrarian = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { flags => 1 }     # superlibrarian
        }
    );
    $superlibrarian->set_password( { password => $password, skip_validation => 1 } );
    my $super_userid = $superlibrarian->userid;

    $t->get_ok( "//$super_userid:$password\@/api/v1/holds/queue" => { 'x-koha-embed' => 'patron' } )
        ->status_is(200)
        ->json_is( '/0/patron/surname' => 'Smith', 'superlibrarian sees the patron surname' );

    $schema->storage->txn_rollback;
};
