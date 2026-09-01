#!/usr/bin/perl

use Modern::Perl;

use Test::More;

use C4::Context;
use Koha::CirculationRules;
use Koha::Database;
use Koha::Holds;
use Koha::Items;
use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

subtest 'closed stack request classification' => sub {
    plan tests => 6;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_preference( 'IndependentBranches',      0 );
    t::lib::Mocks::mock_preference( 'AllowHoldsOnDamagedItems', 0 );
    t::lib::Mocks::mock_preference( 'item-level_itypes',        1 );

    Koha::CirculationRules->set_rule(
        {
            branchcode => undef,
            itemtype   => undef,
            rule_name  => 'holdallowed',
            rule_value => 'from_any_library',
        }
    );

    my $item = $builder->build_sample_item(
        {
            is_closed_stack => 1,
            itemlost        => 0,
            withdrawn       => 0,
            damaged         => 0,
            notforloan      => 0,
            onloan          => undef,
        }
    );
    my $library = $builder->build_object( { class => 'Koha::Libraries' } );

    my @holds;
    for my $priority ( 1, 2 ) {
        my $patron = $builder->build_object( { class => 'Koha::Patrons' } );
        push @holds,
            $builder->build_object(
            {
                class => 'Koha::Holds',
                value => {
                    biblionumber     => $item->biblionumber,
                    itemnumber       => $item->itemnumber,
                    borrowernumber   => $patron->borrowernumber,
                    branchcode       => $library->branchcode,
                    priority         => $priority,
                    suspend          => 0,
                    found            => undef,
                    cancellationdate => undef,
                },
            }
            );
    }

    my $closed_stack_requests =
        Koha::Holds->search( { itemnumber => $item->itemnumber } )->filter_by_closed_stack_requests;
    is( $closed_stack_requests->count,    1, 'Only the top-priority hold is classified as a closed stack request' );
    is( $closed_stack_requests->next->id, $holds[0]->id, 'The top-priority hold is classified' );

    is(
        Koha::Items->search( { itemnumber => $item->itemnumber } )->filter_by_for_hold->count,
        1,
        'A closed stack item with multiple holds is returned only once by filter_by_for_hold'
    );

TODO: {
        local $TODO = 'Bug 38666 does not persist closed stack request identity on a hold';

        ok(
            $holds[1]->is_cancelable_from_opac,
            'A regular queued hold on a closed stack item remains OPAC-cancelable'
        );

        $holds[0]->delete;
        is(
            Koha::Holds->search( { itemnumber => $item->itemnumber } )->filter_by_closed_stack_requests->count,
            0,
            'Removing a closed stack request does not reclassify the next regular hold'
        );

        $item->is_closed_stack(0)->store;
        is(
            Koha::Holds->search( { reserve_id => $holds[1]->id } )->filter_by_closed_stack_requests->count,
            1,
            'Changing the current item flag does not erase the original request type'
        );
    }

    $schema->storage->txn_rollback;
};

done_testing;
