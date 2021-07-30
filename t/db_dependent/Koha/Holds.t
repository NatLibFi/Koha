#!/usr/bin/perl

# Copyright 2020 Koha Development team
#
# This file is part of Koha
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
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 6;
use Test::Warn;

use C4::Circulation qw( AddIssue );
use C4::Reserves qw( AddReserve CheckReserves ModReserve ModReserveCancelAll );
use Koha::AuthorisedValueCategory;
use Koha::Database;
use Koha::Holds;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

my $builder = t::lib::TestBuilder->new;

subtest 'DB constraints' => sub {
    plan tests => 1;

    my $patron = $builder->build_object({ class => 'Koha::Patrons' });
    my $item = $builder->build_sample_item;
    my $hold_info = {
        branchcode     => $patron->branchcode,
        borrowernumber => $patron->borrowernumber,
        biblionumber   => $item->biblionumber,
        priority       => 1,
        title          => "title for fee",
        itemnumber     => $item->itemnumber,
    };

    my $reserve_id = C4::Reserves::AddReserve($hold_info);
    my $hold = Koha::Holds->find( $reserve_id );

    warning_like {
        eval { $hold->priority(undef)->store }
    }
    qr{.*DBD::mysql::st execute failed: Column 'priority' cannot be null.*},
      'DBD should have raised an error about priority that cannot be null';
};

subtest 'cancel' => sub {
    plan tests => 12;
    my $biblioitem = $builder->build_object( { class => 'Koha::Biblioitems' } );
    my $library    = $builder->build_object( { class => 'Koha::Libraries' } );
    my $itemtype   = $builder->build_object( { class => 'Koha::ItemTypes', value => { rentalcharge => 0 } } );
    my $item_info  = {
        biblionumber     => $biblioitem->biblionumber,
        biblioitemnumber => $biblioitem->biblioitemnumber,
        homebranch       => $library->branchcode,
        holdingbranch    => $library->branchcode,
        itype            => $itemtype->itemtype,
    };
    my $item = $builder->build_object( { class => 'Koha::Items', value => $item_info } );
    my $manager = $builder->build_object({ class => "Koha::Patrons" });
    t::lib::Mocks::mock_userenv({ patron => $manager,branchcode => $manager->branchcode });

    my ( @patrons, @holds );
    for my $i ( 0 .. 2 ) {
        my $priority = $i + 1;
        my $patron   = $builder->build_object(
            {
                class => 'Koha::Patrons',
                value => { branchcode => $library->branchcode, }
            }
        );
        my $reserve_id = C4::Reserves::AddReserve(
            {
                branchcode     => $library->branchcode,
                borrowernumber => $patron->borrowernumber,
                biblionumber   => $item->biblionumber,
                priority       => $priority,
                title          => "title for fee",
                itemnumber     => $item->itemnumber,
            }
        );
        my $hold = Koha::Holds->find($reserve_id);
        push @patrons, $patron;
        push @holds,   $hold;
    }

    # There are 3 holds on this records
    my $nb_of_holds =
      Koha::Holds->search( { biblionumber => $item->biblionumber } )->count;
    is( $nb_of_holds, 3,
        'There should have 3 holds placed on this biblio record' );
    my $first_hold  = $holds[0];
    my $second_hold = $holds[1];
    my $third_hold  = $holds[2];
    is( ref($second_hold), 'Koha::Hold',
        'We should play with Koha::Hold objects' );
    is( $second_hold->priority, 2,
        'Second hold should have a priority set to 3' );

    # Remove the second hold, only 2 should still exist in DB and priorities must have been updated
    my $is_cancelled = $second_hold->cancel;
    is( ref($is_cancelled), 'Koha::Hold',
        'Koha::Hold->cancel should return the Koha::Hold (?)' )
      ;    # This is can reconsidered
    is( $second_hold->in_storage, 0,
        'The hold has been cancelled and does not longer exist in DB' );
    $nb_of_holds =
      Koha::Holds->search( { biblionumber => $item->biblionumber } )->count;
    is( $nb_of_holds, 2,
        'a hold has been cancelled, there should have only 2 holds placed on this biblio record'
    );

    # discard_changes to refetch
    is( $first_hold->discard_changes->priority, 1, 'First hold should still be first' );
    is( $third_hold->discard_changes->priority, 2, 'Third hold should now be second' );

    subtest 'charge_cancel_fee parameter' => sub {
        plan tests => 15;
        my $library1 = $builder->build({
            source => 'Branch',
        });
        my $library2 = $builder->build({
            source => 'Branch',
        });

        my $bib_title = "Test Title";

        my $borrower = $builder->build({
            source => 'Borrower',
            value => {
                branchcode => $library1->{branchcode},
            }
        });

        my $itemtype1 = $builder->build({
            source => 'Itemtype',
            value => {}
        });
        my $itemtype2 = $builder->build({
            source => 'Itemtype',
            value => {}
        });
        my $itemtype3 = $builder->build({
            source => 'Itemtype',
            value => {}
        });
        my $itemtype4 = $builder->build({
            source => 'Itemtype',
            value => {}
        });

        my $borrowernumber = $borrower->{borrowernumber};

        my $library_A_code = $library1->{branchcode};

        my $biblio = $builder->build_sample_biblio({itemtype => $itemtype1->{itemtype}});
        my $biblionumber = $biblio->biblionumber;
        my $item1 = $builder->build_sample_item({
            biblionumber => $biblionumber,
            itype => $itemtype1->{itemtype},
            homebranch => $library_A_code,
            holdingbranch => $library_A_code
        });
        my $item2 = $builder->build_sample_item({
            biblionumber => $biblionumber,
            itype => $itemtype2->{itemtype},
            homebranch => $library_A_code,
            holdingbranch => $library_A_code
        });
        my $item3 = $builder->build_sample_item({
            biblionumber => $biblionumber,
            itype => $itemtype3->{itemtype},
            homebranch => $library_A_code,
            holdingbranch => $library_A_code
        });

        my $library_B_code = $library2->{branchcode};

        my $biblio2 = $builder->build_sample_biblio({itemtype => $itemtype4->{itemtype}});
        my $biblionumber2 = $biblio2->biblionumber;
        my $item4 = $builder->build_sample_item({
            biblionumber => $biblionumber2,
            itype => $itemtype4->{itemtype},
            homebranch => $library_B_code,
            holdingbranch => $library_B_code
        });

        Koha::CirculationRules->set_rules(
            {
                itemtype     => undef,
                categorycode => undef,
                branchcode   => undef,
                rules        => {
                    expire_reserves_charge => undef
                }
            }
        );
        Koha::CirculationRules->set_rules(
            {
                itemtype     => $itemtype1->{itemtype},
                categorycode => undef,
                branchcode   => undef,
                rules        => {
                    expire_reserves_charge => '111'
                }
            }
        );
        Koha::CirculationRules->set_rules(
            {
                itemtype     => $itemtype2->{itemtype},
                categorycode => undef,
                branchcode   => undef,
                rules        => {
                    expire_reserves_charge => undef
                }
            }
        );
        Koha::CirculationRules->set_rules(
            {
                itemtype     => undef,
                categorycode => undef,
                branchcode   => $library_B_code,
                rules        => {
                    expire_reserves_charge => '444'
                }
            }
        );

        t::lib::Mocks::mock_preference('ReservesControlBranch', 'ItemHomeLibrary');

        my $reserve_id;
        my $account;
        my $status;
        my $start_balance;

# TEST: Hold itemtype1 item
        $reserve_id = AddReserve(
            {
                branchcode       => $library_A_code,
                borrowernumber   => $borrowernumber,
                biblionumber     => $biblionumber,
                priority         => 1,
                itemnumber       => $item1->itemnumber,
            }
        );

        $account = Koha::Account->new({ patron_id => $borrowernumber });

        ( $status ) = CheckReserves($item1->id);
        is( $status, 'Reserved', "Hold for the itemtype1 created" );

        $start_balance = $account->balance();

        Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

        ( $status ) = CheckReserves($item1->id);
        is( $status, '', "Hold for the itemtype1 cancelled" );

        is( $account->balance() - $start_balance, 111, "Used circulation rule for itemtype1" );

# TEST: circulation rule for itemtype2 has 'expire_reserves_charge' set undef, so it should use ExpireReservesMaxPickUpDelayCharge preference
        t::lib::Mocks::mock_preference('ExpireReservesMaxPickUpDelayCharge', 222);

        $reserve_id = AddReserve(
            {
                branchcode       => $library_A_code,
                borrowernumber   => $borrowernumber,
                biblionumber     => $biblionumber,
                priority         => 1,
                itemnumber       => $item2->itemnumber,
            }
        );

        $account = Koha::Account->new({ patron_id => $borrowernumber });

        ( $status ) = CheckReserves($item2->id);
        is( $status, 'Reserved', "Hold for the itemtype2 created" );

        $start_balance = $account->balance();

        Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

        ( $status ) = CheckReserves($item2->id);
        is( $status, '', "Hold for the itemtype2 cancelled" );

        is( $account->balance() - $start_balance, 222, "Used ExpireReservesMaxPickUpDelayCharge preference as expire_reserves_charge set to undef" );

# TEST: no circulation rules for itemtype3, it should use ExpireReservesMaxPickUpDelayCharge preference
        t::lib::Mocks::mock_preference('ExpireReservesMaxPickUpDelayCharge', 333);

        $reserve_id = AddReserve(
            {
                branchcode       => $library_A_code,
                borrowernumber   => $borrowernumber,
                biblionumber     => $biblionumber,
                priority         => 1,
                itemnumber       => $item3->itemnumber,
            }
        );

        $account = Koha::Account->new({ patron_id => $borrowernumber });

        ( $status ) = CheckReserves($item3->id);
        is( $status, 'Reserved', "Hold for the itemtype3 created" );

        $start_balance = $account->balance();

        Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

        ( $status ) = CheckReserves($item3->id);
        is( $status, '', "Hold for the itemtype3 cancelled" );

        is( $account->balance() - $start_balance, 333, "Used ExpireReservesMaxPickUpDelayCharge preference as there's no circulation rules for itemtype3" );

# TEST: circulation rule for itemtype4 with library_B_code
        t::lib::Mocks::mock_preference('ExpireReservesMaxPickUpDelayCharge', 555);

        $reserve_id = AddReserve(
            {
                branchcode       => $library_B_code,
                borrowernumber   => $borrowernumber,
                biblionumber     => $biblionumber2,
                priority         => 1,
                itemnumber       => $item4->itemnumber,
            }
        );

        $account = Koha::Account->new({ patron_id => $borrowernumber });

        ( $status ) = CheckReserves($item4->id);
        is( $status, 'Reserved', "Hold for the itemtype4 created" );

        $start_balance = $account->balance();

        Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

        ( $status ) = CheckReserves($item4->id);
        is( $status, '', "Hold for the itemtype4 cancelled" );

        is( $account->balance() - $start_balance, 444, "Used circulation rule for itemtype4 with library_B_code" );

        $reserve_id = AddReserve(
            {
                branchcode       => $library_B_code,
                borrowernumber   => $borrowernumber,
                biblionumber     => $biblionumber2,
                priority         => 1,
                itemnumber       => $item4->itemnumber,
            }
        );

        $account = Koha::Account->new({ patron_id => $borrowernumber });

        ( $status ) = CheckReserves($item4->id);
        is( $status, 'Reserved', "Hold for the itemtype4 created" );

        $start_balance = $account->balance();

        Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 0 });

        ( $status ) = CheckReserves($item4->id);
        is( $status, '', "Hold for the itemtype4 cancelled" );

        is( $account->balance() - $start_balance, 0, "Patron not charged when charge_cancel_fee is 0" );
    };

    subtest 'waiting hold' => sub {
        plan tests => 1;
        my $patron = $builder->build_object({ class => 'Koha::Patrons' });
        my $reserve_id = C4::Reserves::AddReserve(
            {
                branchcode     => $library->branchcode,
                borrowernumber => $patron->borrowernumber,
                biblionumber   => $item->biblionumber,
                priority       => 1,
                title          => "title for fee",
                itemnumber     => $item->itemnumber,
                found          => 'W',
            }
        );
        Koha::Holds->find( $reserve_id )->cancel;
        my $hold_old = Koha::Old::Holds->find( $reserve_id );
        is( $hold_old->found, 'W', 'The found column should have been kept and a hold is cancelled' );
    };

    subtest 'HoldsLog' => sub {
        plan tests => 2;
        my $patron = $builder->build_object({ class => 'Koha::Patrons' });
        my $hold_info = {
            branchcode     => $library->branchcode,
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            priority       => 1,
            title          => "title for fee",
            itemnumber     => $item->itemnumber,
        };

        t::lib::Mocks::mock_preference('HoldsLog', 0);
        my $reserve_id = C4::Reserves::AddReserve($hold_info);
        Koha::Holds->find( $reserve_id )->cancel;
        my $number_of_logs = $schema->resultset('ActionLog')->search( { module => 'HOLDS', action => 'CANCEL', object => $reserve_id } )->count;
        is( $number_of_logs, 0, 'Without HoldsLog, Koha::Hold->cancel should not have logged' );

        t::lib::Mocks::mock_preference('HoldsLog', 1);
        $reserve_id = C4::Reserves::AddReserve($hold_info);
        Koha::Holds->find( $reserve_id )->cancel;
        $number_of_logs = $schema->resultset('ActionLog')->search( { module => 'HOLDS', action => 'CANCEL', object => $reserve_id } )->count;
        is( $number_of_logs, 1, 'With HoldsLog, Koha::Hold->cancel should have logged' );
    };

    subtest 'rollback' => sub {
        plan tests => 3;
        my $patron_category = $builder->build_object(
            {
                class => 'Koha::Patron::Categories',
                value => { reservefee => 0 }
            }
        );
        my $patron = $builder->build_object(
            {
                class => 'Koha::Patrons',
                value => { categorycode => $patron_category->categorycode }
            }
        );
        my $hold_info = {
            branchcode     => $library->branchcode,
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            priority       => 1,
            title          => "title for fee",
            itemnumber     => $item->itemnumber,
        };

        t::lib::Mocks::mock_preference( 'ExpireReservesMaxPickUpDelayCharge',42 );
        my $reserve_id = C4::Reserves::AddReserve($hold_info);
        my $hold       = Koha::Holds->find($reserve_id);

        # Add a row with the same id to make the cancel fails
        Koha::Old::Hold->new( $hold->unblessed )->store;

        warning_like {
            eval { $hold->cancel( { charge_cancel_fee => 1 } ) };
        }
        qr{.*DBD::mysql::st execute failed: Duplicate entry.*},
          'DBD should have raised an error about dup primary key';

        $hold = Koha::Holds->find($reserve_id);
        is( ref($hold), 'Koha::Hold', 'The hold should not have been deleted' );
        is( $patron->account->balance, 0,
'If the hold has not been cancelled, the patron should not have been charged'
        );
    };

};

subtest 'cancel with reason' => sub {
    plan tests => 7;
    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $item = $builder->build_sample_item({ library => $library->branchcode });
    my $manager = $builder->build_object( { class => "Koha::Patrons" } );
    t::lib::Mocks::mock_userenv( { patron => $manager, branchcode => $manager->branchcode } );

    my $patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { branchcode => $library->branchcode, }
        }
    );

    my $reserve_id = C4::Reserves::AddReserve(
        {
            branchcode     => $library->branchcode,
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            priority       => 1,
            itemnumber     => $item->itemnumber,
        }
    );

    my $hold = Koha::Holds->find($reserve_id);

    ok($reserve_id, "Hold created");
    ok($hold, "Hold found");

    my $av = Koha::AuthorisedValue->new( { category => 'HOLD_CANCELLATION', authorised_value => 'TEST_REASON' } )->store;
    Koha::Notice::Templates->search({ code => 'HOLD_CANCELLATION'})->delete();
    my $notice = Koha::Notice::Template->new({
        name                   => 'Hold cancellation',
        module                 => 'reserves',
        code                   => 'HOLD_CANCELLATION',
        title                  => 'Hold cancelled',
        content                => 'Your hold was cancelled.',
        message_transport_type => 'email',
        branchcode             => q{},
    })->store();

    $hold->cancel({cancellation_reason => 'TEST_REASON'});

    $hold = Koha::Holds->find($reserve_id);
    is( $hold, undef, 'Hold is not in the reserves table');
    $hold = Koha::Old::Holds->find($reserve_id);
    ok( $hold, 'Hold was found in the old reserves table');

    my $message = Koha::Notice::Messages->find({ borrowernumber => $patron->id, letter_code => 'HOLD_CANCELLATION'});
    ok( $message, 'Found hold cancellation message');
    is( $message->subject, 'Hold cancelled', 'Message has correct title' );
    is( $message->content, 'Your hold was cancelled.', 'Message has correct content');

    $notice->delete;
    $av->delete;
    $message->delete;
};

subtest 'cancel all with reason' => sub {
    plan tests => 7;
    my $library = $builder->build_object( { class => 'Koha::Libraries' } );
    my $item = $builder->build_sample_item({ library => $library->branchcode });
    my $manager = $builder->build_object( { class => "Koha::Patrons" } );
    t::lib::Mocks::mock_userenv( { patron => $manager, branchcode => $manager->branchcode } );

    my $patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { branchcode => $library->branchcode, }
        }
    );

    my $reserve_id = C4::Reserves::AddReserve(
        {
            branchcode     => $library->branchcode,
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            priority       => 1,
            itemnumber     => $item->itemnumber,
        }
    );

    my $hold = Koha::Holds->find($reserve_id);

    ok($reserve_id, "Hold created");
    ok($hold, "Hold found");

    my $av = Koha::AuthorisedValue->new( { category => 'HOLD_CANCELLATION', authorised_value => 'TEST_REASON' } )->store;
    Koha::Notice::Templates->search({ code => 'HOLD_CANCELLATION'})->delete();
    my $notice = Koha::Notice::Template->new({
        name                   => 'Hold cancellation',
        module                 => 'reserves',
        code                   => 'HOLD_CANCELLATION',
        title                  => 'Hold cancelled',
        content                => 'Your hold was cancelled.',
        message_transport_type => 'email',
        branchcode             => q{},
    })->store();

    ModReserveCancelAll($item->id, $patron->id, 'TEST_REASON');

    $hold = Koha::Holds->find($reserve_id);
    is( $hold, undef, 'Hold is not in the reserves table');
    $hold = Koha::Old::Holds->find($reserve_id);
    ok( $hold, 'Hold was found in the old reserves table');

    my $message = Koha::Notice::Messages->find({ borrowernumber => $patron->id, letter_code => 'HOLD_CANCELLATION'});
    ok( $message, 'Found hold cancellation message');
    is( $message->subject, 'Hold cancelled', 'Message has correct title' );
    is( $message->content, 'Your hold was cancelled.', 'Message has correct content');

    $av->delete;
    $message->delete;
};

subtest 'Desks' => sub {
    plan tests => 5;
    my $library = $builder->build_object( { class => 'Koha::Libraries' } );

    my $desk = Koha::Desk->new({
        desk_name  => 'my_desk_name_for_test',
        branchcode => $library->branchcode ,
                               })->store;
    ok($desk, "Desk created");
    my $item = $builder->build_sample_item({ library => $library->branchcode });
    my $manager = $builder->build_object( { class => "Koha::Patrons" } );
    t::lib::Mocks::mock_userenv( { patron => $manager, branchcode => $manager->branchcode } );

    my $patron = $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => { branchcode => $library->branchcode, }
        }
        );

    my $reserve_id = C4::Reserves::AddReserve(
        {
            branchcode     => $library->branchcode,
            borrowernumber => $patron->borrowernumber,
            biblionumber   => $item->biblionumber,
            priority       => 1,
            itemnumber     => $item->itemnumber,
        }
    );

    my $hold = Koha::Holds->find($reserve_id);

    ok($reserve_id, "Hold created");
    ok($hold, "Hold found");
    $hold->set_waiting($desk->desk_id);
    is($hold->found, 'W', 'Hold is waiting with correct status set');
    is($hold->desk_id, $desk->desk_id, 'Hold is attach to its desk');

};

subtest 'get_items_that_can_fill' => sub {
    plan tests => 2;

    my $biblio = $builder->build_sample_biblio;
    my $itype_1 = $builder->build_object({ class => 'Koha::ItemTypes' }); # For 1, 2, 3, 4
    my $itype_2 = $builder->build_object({ class => 'Koha::ItemTypes' });
    my $item_1 = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itype => $itype_1->itemtype } );
        # waiting
    my $item_2 = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itype => $itype_1->itemtype } );
    my $item_3 = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itype => $itype_1->itemtype } )
      ;    # onloan
    my $item_4 = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itype => $itype_1->itemtype } )
      ;    # in transfer
    my $item_5 = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itype => $itype_2->itemtype } );
    my $lost       = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, itemlost => 1 } );
    my $withdrawn  = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, withdrawn => 1 } );
    my $notforloan = $builder->build_sample_item( { biblionumber => $biblio->biblionumber, notforloan => 1 } );

    my $patron_1 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron_2 = $builder->build_object( { class => 'Koha::Patrons' } );
    my $patron_3 = $builder->build_object( { class => 'Koha::Patrons' } );

    t::lib::Mocks::mock_userenv( { patron => $patron_1 } );

    my $reserve_id_1 = C4::Reserves::AddReserve(
        {
            borrowernumber => $patron_1->borrowernumber,
            biblionumber   => $biblio->biblionumber,
            priority       => 1,
            itemnumber     => $item_1->itemnumber,
        }
    );

    my $reserve_id_2 = C4::Reserves::AddReserve(
        {
            borrowernumber => $patron_2->borrowernumber,
            biblionumber   => $biblio->biblionumber,
            priority       => 2,
            itemnumber     => $item_1->itemnumber,
        }
    );

    my $waiting_reserve_id = C4::Reserves::AddReserve(
        {
            borrowernumber => $patron_2->borrowernumber,
            biblionumber   => $biblio->biblionumber,
            priority       => 0,
            found          => 'W',
            itemnumber     => $item_1->itemnumber,
        }
    );

    # item 3 is on loan
    AddIssue( $patron_3->unblessed, $item_3->barcode );

    # item 4 is in transfer
    my $from = $builder->build_object( { class => 'Koha::Libraries' } );
    my $to   = $builder->build_object( { class => 'Koha::Libraries' } );
    Koha::Item::Transfer->new(
        {
            itemnumber  => $item_4->itemnumber,
            datearrived => undef,
            frombranch  => $from->branchcode,
            tobranch    => $to->branchcode
        }
    )->store;

    my $holds = Koha::Holds->search(
        {
            reserve_id => [ $reserve_id_1, $reserve_id_2, $waiting_reserve_id, ]
        }
    );

    my $items = $holds->get_items_that_can_fill;
    is_deeply( [ map { $_->itemnumber } $items->as_list ],
        [ $item_2->itemnumber, $item_5->itemnumber ], 'Only item 2 and 5 are available for filling the hold' );

    # Marking item_5 is no hold allowed
    Koha::CirculationRule->new(
        {
            rule_name  => 'holdallowed',
            rule_value => 'not_allowed',
            itemtype   => $item_5->itype
        }
    )->store;
    $items = $holds->get_items_that_can_fill;
    is_deeply( [ map { $_->itemnumber } $items->as_list ],
        [ $item_2->itemnumber ], 'Only item 1 is available for filling the hold' );

};

$schema->storage->txn_rollback;

1;
