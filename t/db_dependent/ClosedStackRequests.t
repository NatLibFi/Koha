#!/usr/bin/perl

# Copyright 2026 Koha Development team
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
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;
use Test::More;
use Test::NoWarnings 'had_no_warnings';
use Test::MockModule;
use Storable qw( dclone );

use C4::Reserves qw( AddReserve CheckReserves IsAvailableForItemLevelRequest ModReserveAffect SuspendAll );
use Koha::Cache::Memory::Lite;
use Koha::CirculationRules;
use Koha::Database;
use Koha::Holds;
use Koha::Items;
use Koha::BackgroundJobs;
use Koha::BackgroundJob::BatchUpdateItem;
use t::lib::Mocks;
use t::lib::TestBuilder;

# Run only against a disposable test database. All fixtures are rolled back.
my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
$schema->storage->txn_begin;

my $indexer = Test::MockModule->new('Koha::SearchEngine::Indexer');
$indexer->mock( index_records => sub { return; } );    # Fixtures never reach an external search index.

t::lib::Mocks::mock_preference( 'IndependentBranches',           0 );
t::lib::Mocks::mock_preference( 'AllowHoldsOnDamagedItems',      0 );
t::lib::Mocks::mock_preference( 'item-level_itypes',             1 );
t::lib::Mocks::mock_preference( 'SkipHoldTrapOnNotForLoanValue', '' );
t::lib::Mocks::mock_preference( 'TrapHoldsOnOrder',              0 );
t::lib::Mocks::mock_preference( 'LocalHoldsPriority',            'None' );
t::lib::Mocks::mock_preference( 'LocalHoldsExclusivityPeriod',   0 );
t::lib::Mocks::mock_preference( 'UseBranchTransferLimits',       0 );
t::lib::Mocks::mock_preference( 'ReservesControlBranch',         'ItemHomeLibrary' );
t::lib::Mocks::mock_preference( 'AgeRestrictionMarker',          '' );
t::lib::Mocks::mock_preference( 'RealTimeHoldsQueue',            0 );

my $library = $builder->build_object( { class => 'Koha::Libraries' } );
my $patron  = $builder->build_object( { class => 'Koha::Patrons', value => { branchcode => $library->branchcode } } );
t::lib::Mocks::mock_userenv( { patron => $patron, branchcode => $library->branchcode } );
my $itemtype = $builder->build_object( { class => 'Koha::ItemTypes', value => { notforloan => 0 } } );
Koha::CirculationRules->set_rules(
    {
        branchcode => undef, itemtype => $itemtype->itemtype,
        rules      => { holdallowed => 'from_any_library', hold_fulfillment_policy => 'any' },
    }
);

sub new_item {
    my ($values) = @_;
    my $biblioitem = $builder->build_object(
        { class => 'Koha::Biblioitems', value => { itemtype => $itemtype->itemtype, agerestriction => undef } } );
    return $builder->build_object(
        {
            class => 'Koha::Items',
            value => {
                biblionumber       => $biblioitem->biblionumber, biblioitemnumber => $biblioitem->biblioitemnumber,
                homebranch         => $library->branchcode,      holdingbranch    => $library->branchcode,
                itype              => $itemtype->itemtype,       is_closed_stack  => 1,
                itemlost           => 0, withdrawn => 0, damaged => 0, notforloan => 0, onloan => undef,
                more_subfields_xml => undef,
                %{ $values // {} },
            },
        }
    )->get_from_storage;
}

sub new_hold {
    my ( $item, $values ) = @_;
    return $builder->build_object(
        {
            class => 'Koha::Holds',
            value => {
                biblionumber   => $item->biblionumber,     itemnumber => $item->itemnumber,
                borrowernumber => $patron->borrowernumber, branchcode => $library->branchcode,
                priority       => 1,     suspend      => 0,     found            => undef, reservedate => '2000-01-01',
                expirationdate => undef, waitingdate  => undef, cancellationdate => undef,
                suspend_until  => undef, itemtype     => undef, item_group_id    => undef, item_level_hold         => 1,
                hold_group_id  => undef, non_priority => 0, lowestPriority => 0, closed_stack_request_slip_printed => 0,
                %{ $values // {} },
            },
        }
    )->get_from_storage;
}

sub new_transfer {
    my ($item) = @_;
    return $builder->build_object(
        {
            class => 'Koha::Item::Transfers',
            value => {
                itemnumber  => $item->itemnumber,    frombranch    => $library->branchcode,
                tobranch    => $library->branchcode, daterequested => \'NOW()', datesent => \'NOW()',
                datearrived => undef,                datecancelled => undef,
            },
        }
    );
}

subtest 'Item flags, forcing and OPAC cancellation' => sub {
    for my $flag ( 0, 1 ) {
        my $item   = new_item( { is_closed_stack => $flag } );
        my $biblio = $item->biblio;
        Koha::CirculationRules->set_rules(
            {
                branchcode => $library->branchcode, categorycode => $patron->categorycode,
                itemtype   => $itemtype->itemtype,  rules        => { opacitemholds => 'Y' },
            }
        );
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is( $item->get_from_storage->is_closed_stack, $flag, 'Stored flag survives preference changes' );
            is(
                $item->can('uses_closed_stack_requests') ? $item->uses_closed_stack_requests : undef,
                $enabled && $flag                        ? 1                                 : 0,
                'Effective flag follows preference without replacing stored flag'
            );
            is(
                $item->is_available_for_closed_stack_request, $enabled && $flag ? 1 : 0,
                'Free item request availability'
            );
            is(
                $biblio->forced_hold_level, $enabled && $flag ? 'item' : undef,
                'Free flagged item forces only when enabled'
            );
            $item->notforloan(1)->store;
            is(
                IsAvailableForItemLevelRequest( $item, $patron ), $enabled && $flag ? 1 : 0,
                'Positive notforloan bypass needs both enabled preference and flagged item'
            );
            $item->notforloan(0)->store;
            is(
                Koha::CirculationRules->get_opacitemholds_policy( { item => $item, patron => $patron } ),
                $enabled && $flag ? 'F' : 'Y', 'Normal item-level rule remains effective when disabled'
            );
        }
        my $hold = new_hold($item);
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is(
                $hold->is_cancelable_from_opac, $enabled && $flag ? 0 : 1,
                'Pending hold cancellation follows preference'
            );
            is(
                $item->is_available_for_closed_stack_request, 0,
                'Existing hold prevents another closed stack request'
            );
            is( $biblio->forced_hold_level,      undef,  'Held item does not force via biblio' );
            is( $item->holds->forced_hold_level, 'item', 'Existing item-level hold still forces item-level holds' );
            for my $found ( 'W', 'T', 'P' ) {
                $hold->found($found)->store;
                is( $hold->is_cancelable_from_opac, 0, "Found hold $found cannot be cancelled" );
            }
            $hold->found(undef)->store;
        }
    }
};

subtest 'Queue classification and ordinary visibility' => sub {
    my @holds;
    for my $case (
        [ 'pending',       {}, {},                 1 ], [ 'ordinary', { is_closed_stack => 0 }, {},               0 ],
        [ 'suspended',     {}, { suspend => 1 },   0 ], [ 'waiting',  {},                       { found => 'W' }, 0 ],
        [ 'zero priority', {}, { priority => 0 },  0 ], [ 'lost',     { itemlost => 1 },        {},               0 ],
        [ 'withdrawn',     { withdrawn => 1 }, {}, 0 ], [ 'checked out', { onloan => '2099-01-01' }, {},          0 ],
        [ 'damaged',       { damaged => 1 },   {}, 0 ], [ 'transfer',    {},                         {},          0 ],
        )
    {
        my ( $name, $item_values, $hold_values, $eligible ) = @$case;
        my $item = new_item($item_values);
        new_transfer($item) if $name eq 'transfer';
        my $hold = new_hold( $item, $hold_values );
        push @holds, $hold->id;
        my $set = Koha::Holds->search( { 'me.reserve_id' => $hold->id } );
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is(
                $set->filter_by_closed_stack_requests->count, $enabled ? $eligible : 0,
                "$name classification, enabled=$enabled"
            );
            is(
                $set->filter_out_closed_stack_requests->count, $enabled ? 1 - $eligible : 1,
                "$name ordinary visibility, enabled=$enabled"
            );
        }
        if ( $name eq 'damaged' ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
            t::lib::Mocks::mock_preference( 'AllowHoldsOnDamagedItems',  1 );
            is( $set->filter_by_closed_stack_requests->count, 1, 'Damaged request allowed by normal damaged policy' );
            t::lib::Mocks::mock_preference( 'AllowHoldsOnDamagedItems', 0 );
        }
    }
    my $item   = new_item();
    my $first  = new_hold($item);
    my $second = new_hold( $item, { priority => 2 } );
    my $set    = $item->holds;
    t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
    is_deeply(
        [ $set->filter_by_closed_stack_requests->get_column('reserve_id') ], [ $first->id ],
        'Only top priority pending request is classified'
    );
    is_deeply(
        [ $set->filter_out_closed_stack_requests->get_column('reserve_id') ], [ $second->id ],
        'Next priority remains an ordinary hold'
    );
    t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 0 );
    is(
        $set->filter_out_closed_stack_requests->count, 2,
        'Disabling restores both pending requests to ordinary holds'
    );
    my $all = Koha::Holds->search( { 'me.reserve_id' => { -in => \@holds } } );
    is( $all->filter_out_closed_stack_requests->count, scalar @holds, 'All fixture holds remain visible OFF' );
};

subtest 'Normal item query and filling holds' => sub {
    for my $item_level ( 0, 1 ) {
        t::lib::Mocks::mock_preference( 'item-level_itypes', $item_level );
        my $item     = new_item();
        my $ordinary = new_item( { is_closed_stack => 0 } );
        my $items    = Koha::Items->search( { 'me.itemnumber' => [ $item->id, $ordinary->id ] } );
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is( $items->filter_by_for_hold->count,     $enabled ? 1 : 2, 'Free closed stack item only excluded ON' );
            is( $items->filter_by_closed_stack->count, $enabled ? 1 : 0, 'Closed stack count is zero OFF' );
        }
        my $hold = new_hold($item);
        new_hold( $item, { priority => 2 } );
        new_hold($ordinary);
        new_hold( $ordinary, { priority => 2 } );
        my $loan     = new_item( { onloan => '2099-01-01' } );
        my $checkout = $builder->build_object(
            {
                class => 'Koha::Checkouts',
                value => {
                    itemnumber => $loan->id,            borrowernumber  => $patron->id,
                    branchcode => $library->branchcode, date_due        => '2099-01-01',
                    issuedate  => '2000-01-01',         onsite_checkout => 0, auto_renew => 0,
                },
            }
        );
        $items = Koha::Items->search( { 'me.itemnumber' => [ $item->id, $ordinary->id, $loan->id ] } );
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is(
                $item->holds->get_items_that_can_fill->count, $enabled ? 0 : 1,
                'OFF permits flagged item to fill ordinary holds without duplicate join rows'
            );
            my $filtered = $items->filter_by_for_hold;
            is( $filtered->count, 3, "Each held or loaned item is counted once, enabled=$enabled" );
            my @matches = $filtered->as_list;
            is( scalar @matches, 3, "Iteration has no duplicate hold joins, enabled=$enabled" );
            is_deeply(
                [ sort { $a <=> $b } map { $_->id } @matches ],
                [ sort { $a <=> $b } ( $item->id, $ordinary->id, $loan->id ) ],
                "Exact item identities include held flagged, ordinary and loaned controls, enabled=$enabled"
            );
            is(
                $filtered->search( { 'me.itemnumber' => $ordinary->id } )->count, 1,
                "Caller item filter preserves the ordinary control, enabled=$enabled"
            );
        }
        my $other_library = $builder->build_object( { class => 'Koha::Libraries' } );
        my $remote        = new_item( { is_closed_stack => 0, homebranch => $other_library->branchcode } );
        my $branch_items  = Koha::Items->search( { 'me.itemnumber' => [ $ordinary->id, $remote->id ] } );
        t::lib::Mocks::mock_userenv( { patron => $patron, branchcode => $library->branchcode, flags => 2 } );
        t::lib::Mocks::mock_preference( 'IndependentBranches', 1 );
        ok( C4::Context->only_my_library, 'Branch restriction is active for the query control' );
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is_deeply(
                [ map { $_->id } $branch_items->filter_by_for_hold->as_list ], [ $ordinary->id ],
                "Only-my-library and caller item scope are preserved, enabled=$enabled"
            );
        }
        t::lib::Mocks::mock_preference( 'IndependentBranches', 0 );
        t::lib::Mocks::mock_userenv( { patron => $patron, branchcode => $library->branchcode } );
        $item->itemlost(1)->store;
        t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 0 );
        is( $item->holds->get_items_that_can_fill->count, 0, 'Normal lost policy still blocks filling OFF' );
        $item->itemlost(0)->onloan('2099-01-01')->store;
        is( $item->holds->get_items_that_can_fill->count, 0, 'Normal checkout policy still blocks filling OFF' );
        $item->onloan(undef)->store;
        new_transfer($item);
        is( $item->holds->get_items_that_can_fill->count, 0, 'Normal transfer policy still blocks filling OFF' );
    }
    t::lib::Mocks::mock_preference( 'item-level_itypes', 1 );
    my $item = new_item();
    t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
    ok( $item->is_available_for_closed_stack_request, 'Free flagged item is requestable ON' );
    my $checkout = $builder->build_object(
        { class => 'Koha::Checkouts', value => { itemnumber => $item->id, borrowernumber => $patron->id } } );
    is( $item->is_available_for_closed_stack_request, 0, 'Checkout blocks a closed stack request' );
    $checkout->delete;
    new_transfer($item);
    is( $item->is_available_for_closed_stack_request, 0, 'Transfer blocks a closed stack request' );
};

subtest 'Item-level request and hold trapping policies' => sub {
    my $item = new_item();
    Koha::CirculationRules->set_rules(
        {
            branchcode => $library->branchcode, categorycode => $patron->categorycode,
            itemtype   => $itemtype->itemtype,
            rules      => { reservesallowed => 1000, holds_per_record => 100, holds_per_day => 1000 },
        }
    );
    Koha::CirculationRules->set_rule(
        {
            branchcode => $library->branchcode, categorycode => $patron->categorycode,
            rule_name  => 'max_holds',          rule_value   => 1000
        }
    );
    for my $onshelf ( 0, 1, 2 ) {
        Koha::CirculationRules->set_rules(
            {
                branchcode => $library->branchcode, categorycode => $patron->categorycode,
                itemtype   => $itemtype->itemtype,  rules        => { onshelfholds => $onshelf },
            }
        );
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            Koha::Cache::Memory::Lite->get_instance->clear_from_cache(
                sprintf 'ItemsAnyAvailableAndNotRestricted:%s:%s', $patron->id, $item->biblionumber );
            is(
                !!IsAvailableForItemLevelRequest( $item, $patron ), $enabled || $onshelf == 1 ? 1 : '',
                "Free flagged item uses normal onshelf=$onshelf policy OFF"
            );
        }
    }
    my $hold = new_hold($item);
    for my $notforloan ( -1, 0, 1 ) {
        $item->notforloan($notforloan)->store;
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            my ($status) = CheckReserves($item);
            is(
                $status, $enabled || $notforloan == 0 ? 'Reserved' : undef,
                "Hold trapping respects notforloan=$notforloan OFF"
            );
        }
    }
    $item->notforloan(1)->store;
    t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 0 );
    is( IsAvailableForItemLevelRequest( $item, $patron ), 0, 'Positive item notforloan blocks request OFF' );
    t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
    is( IsAvailableForItemLevelRequest( $item, $patron ), 1, 'Flagged item bypasses notforloan ON' );
    $item->notforloan(0)->store;
    $itemtype->notforloan(1)->store;

    for my $enabled ( 0, 1 ) {
        t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
        is( IsAvailableForItemLevelRequest( $item, $patron ), $enabled, 'Itemtype notforloan bypass only ON' );
        my ($status) = CheckReserves($item);
        is( $status, $enabled ? 'Reserved' : undef, 'Itemtype notforloan trapping bypass only ON' );
    }
    $itemtype->notforloan(0)->store;
    for my $field ( 'itemlost', 'withdrawn', 'damaged' ) {
        $item->$field(1)->store;
        for my $enabled ( 0, 1 ) {
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            is( IsAvailableForItemLevelRequest( $item, $patron ), 0, "$field still blocks request, enabled=$enabled" );
        }
        $item->$field(0)->store;
    }
};

subtest 'Queued batch edits use the execution preference without changing the payload' => sub {
    my $jobs = Test::MockModule->new('Koha::BackgroundJob');
    $jobs->mock( connect => sub { return; } );    # No external message broker.

    for my $case (
        [ 'direct set',  0, 1, 0 ], [ 'direct clear',        1, 0, 0 ],
        [ 'regex clear', 1, 0, 1 ], [ 'regex set from zero', 0, 1, 1 ],
        )
    {
        my ( $name, $stored_flag, $requested_flag, $regex ) = @$case;
        for my $enabled ( 0, 1 ) {
            my $item =
                new_item( { is_closed_stack => $stored_flag, itemnotes => 'old note', copynumber => 'old copy' } );
            my $outside = new_item( { is_closed_stack => $stored_flag, itemnotes => 'outside' } );
            $item->biblio->frameworkcode('')->store;
            my $args = {
                record_ids => [ $item->id ],
                new_values => { itemnotes  => 'new note' },
                regex_mod  => { copynumber => { search => 'old', replace => 'new', modifiers => '' } },
            };
            if ($regex) {
                $args->{regex_mod}->{is_closed_stack} = {
                    search => "$stored_flag", replace => "$requested_flag", modifiers => '',
                };
            } else {
                $args->{new_values}->{is_closed_stack} = $requested_flag;
            }
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
            my $job_id         = Koha::BackgroundJob::BatchUpdateItem->new->enqueue($args);
            my $job            = Koha::BackgroundJobs->find($job_id)->_derived_class;
            my $queued         = dclone( $job->decoded_data );
            my $execution_args = dclone($queued);
            t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
            $job->process($execution_args);

            # Existing regex handling skips false old values, including flag 0.
            my $expected_flag = $enabled && !( $regex && !$stored_flag ) ? $requested_flag : $stored_flag;
            my $stored        = $item->get_from_storage;
            is( $stored->is_closed_stack,              $expected_flag, "$name honors execution preference=$enabled" );
            is( $stored->itemnotes,                    'new note',     'Ordinary direct update still runs' );
            is( $stored->copynumber,                   'new copy',     'Ordinary regex update still runs' );
            is( $outside->get_from_storage->itemnotes, 'outside',      'Frozen job IDs exclude other items' );
            is_deeply( $execution_args, $queued, 'Execution argument hashes are untouched' );
            my $finished = $job->get_from_storage->decoded_data;
            is_deeply( $finished->{new_values}, $queued->{new_values}, 'Stored direct payload survives execution' );
            is_deeply( $finished->{regex_mod},  $queued->{regex_mod},  'Stored regex payload survives execution' );
            is_deeply( $finished->{record_ids}, $queued->{record_ids}, 'Stored target IDs survive execution' );
            is_deeply( $finished->{report}->{errors}, [],              'No batch errors' );
            is_deeply(
                $finished->{report}->{modified_itemnumbers}, [ $item->id ],
                'Report names only the modified target'
            );
            is( $finished->{report}->{total_records}, 1, 'Job size remains unchanged' );
            is(
                $finished->{report}->{modified_fields}, 2 + ( $stored_flag != $expected_flag ? 1 : 0 ),
                'Report counts only effective ordinary and enabled flag changes'
            );
        }
    }
};

subtest 'OFF to ON retains title-level holds and printed slips' => sub {
    my $item = new_item();
    my $title_hold =
        new_hold( $item, { itemnumber => undef, item_level_hold => 0, closed_stack_request_slip_printed => 1 } );
    my $printed_item = new_item();
    my $printed_hold = new_hold( $printed_item, { closed_stack_request_slip_printed => 1 } );
    for my $enabled ( 0, 1, 0, 1 ) {
        t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
        my $title = Koha::Holds->search( { 'me.reserve_id' => $title_hold->id } );
        is(
            $title->filter_out_closed_stack_requests->count, 1,
            'Existing title-level hold remains visible as an ordinary hold'
        );
        is(
            $title->filter_by_closed_stack_requests->count, 0,
            'Title-level hold never becomes a closed stack request'
        );
        is(
            $title_hold->get_from_storage->itemnumber, undef,
            'Preference toggles do not convert the title-level hold'
        );
        is(
            $title_hold->get_from_storage->closed_stack_request_slip_printed, 1,
            'Title-level printed marker is preserved'
        );
        is( $item->get_from_storage->is_closed_stack, 1, 'Stored item flag is preserved' );
        is(
            $title->get_items_that_can_fill->count, $enabled ? 0 : 1,
            'Existing feature excludes the free closed stack item from filling a title-level hold ON'
        );
        is(
            $item->biblio->forced_hold_level, $enabled ? 'item' : undef,
            'Free item forces new item-level holds only ON'
        );
        is(
            $item->is_available_for_closed_stack_request, $enabled,
            'Title-level hold does not count as an attached item hold for request availability'
        );
        my $printed = Koha::Holds->search( { 'me.reserve_id' => $printed_hold->id } );
        is(
            $printed->filter_by_closed_stack_requests->count, $enabled,
            'Re-enabling restores the existing item request to the CSR queue'
        );
        is(
            $printed->filter_out_closed_stack_requests->count, $enabled ? 0 : 1,
            'Disabling makes the printed item request visible as an ordinary hold'
        );
        is(
            $printed_hold->get_from_storage->closed_stack_request_slip_printed, 1,
            'Re-enabled request keeps its old printed-slip marker'
        );
    }
};

subtest 'Placing a local hold does not skip closed stack retrieval' => sub {
    t::lib::Mocks::mock_preference( 'ReservesNeedReturns',            0 );
    t::lib::Mocks::mock_preference( 'HoldsNeedProcessingSIP',         0 );
    t::lib::Mocks::mock_preference( 'AllowHoldDateInFuture',          0 );
    t::lib::Mocks::mock_preference( 'HoldFeeMode',                    'any_time_is_collected' );
    t::lib::Mocks::mock_preference( 'emailLibrarianWhenHoldIsPlaced', 0 );
    t::lib::Mocks::mock_preference( 'EmailPatronWhenHoldIsPlaced',    0 );
    for my $enabled ( 0, 1 ) {
        t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
        for my $flagged ( 0, 1 ) {
            my $item = new_item( { is_closed_stack => $flagged } );
            my $id   = AddReserve(
                {
                    branchcode      => $library->branchcode, borrowernumber => $patron->id,
                    biblionumber    => $item->biblionumber,  itemnumber     => $item->id,
                    priority        => 1,     found                         => undef, reservation_date => '2000-01-01',
                    expiration_date => undef, patron_expiration_date        => undef, non_priority     => 0,
                }
            );
            my $hold   = Koha::Holds->find($id);
            my $queued = $enabled && $flagged;
            is( $hold->found,    $queued ? undef : 'W', "Placement found state: enabled=$enabled flagged=$flagged" );
            is( $hold->priority, $queued ? 1     : 0,   "Placement priority: enabled=$enabled flagged=$flagged" );
            is(
                Koha::Holds->search( { 'me.reserve_id' => $id } )->filter_by_closed_stack_requests->count,
                $queued ? 1 : 0, "Placement queue membership: enabled=$enabled flagged=$flagged"
            );
            if ($queued) {
                is( ModReserveAffect( $item->id, $patron->id, 0, $id ), 1, 'Retrieved item can still fill the hold' );
                $hold = $hold->get_from_storage;
                is( $hold->found,    'W', 'Retrieval sets the request waiting' );
                is( $hold->priority, 0,   'Retrieval clears queue priority' );
                is(
                    Koha::Holds->search( { 'me.reserve_id' => $id } )->filter_by_closed_stack_requests->count,
                    0, 'Retrieved request leaves the retrieval queue'
                );
            }
        }
    }
};

subtest 'Bulk suspension protects the current retrieval queue and resumes legacy holds' => sub {
    for my $enabled ( 0, 1 ) {
        t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', $enabled );
        my $borrower =
            $builder->build_object( { class => 'Koha::Patrons', value => { branchcode => $library->branchcode } } );
        my $ordinary = new_hold( new_item( { is_closed_stack => 0 } ), { borrowernumber => $borrower->id } );
        my $request  = new_hold( new_item(),                           { borrowernumber => $borrower->id } );
        my $legacy =
            new_hold( new_item(), { borrowernumber => $borrower->id, suspend => 1, suspend_until => '2099-01-01' } );
        my $waiting = new_hold(
            new_item( { is_closed_stack => 0 } ),
            { borrowernumber => $borrower->id, found => 'W', priority => 0, waitingdate => '2000-01-01' }
        );
        my $outside = new_hold( new_item( { is_closed_stack => 0 } ) );
        is(
            Koha::Holds->search( { 'me.reserve_id' => $request->id } )->filter_by_closed_stack_requests->count,
            $enabled, "Request is classified before suspension, enabled=$enabled"
        );
        SuspendAll( borrowernumber => $borrower->id, suspend => 1, suspend_until => '2099-12-31' );
        $request = $request->get_from_storage;
        is( $ordinary->get_from_storage->suspend, 1,                'Ordinary hold is suspended' );
        is( $request->suspend,                    $enabled ? 0 : 1, 'Only the enabled retrieval queue is protected' );
        is(
            $request->suspend_until, $enabled ? undef : '2099-12-31 00:00:00',
            'Protected request has no suspension date'
        );
        is( $legacy->get_from_storage->suspend,  1,   'Existing suspended flagged hold remains suspended' );
        is( $waiting->get_from_storage->suspend, 0,   'Found control remains unchanged' );
        is( $waiting->found,                     'W', 'Found control keeps its status' );
        is( $outside->get_from_storage->suspend, 0,   'Another patron is unchanged' );

        $request->suspend(1)->suspend_until('2099-01-01')->store;
        SuspendAll( borrowernumber => $borrower->id, suspend => 0 );
        for my $hold ( $ordinary, $request, $legacy ) {
            $hold = $hold->get_from_storage;
            is( $hold->suspend,       0,     'Bulk resume includes ordinary and legacy flagged holds' );
            is( $hold->suspend_until, undef, 'Bulk resume clears the suspension date' );
        }
        is( $waiting->get_from_storage->found,   'W', 'Resume preserves found control' );
        is( $outside->get_from_storage->suspend, 0,   'Resume preserves another patron' );
    }
};

$schema->storage->txn_rollback;
had_no_warnings;
done_testing;
