#!/usr/bin/perl

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

use Test::NoWarnings;
use Test::More tests => 4;
use Test::MockModule;
use Test::Exception;

use Koha::Database;
use Koha::DateUtils qw(dt_from_string);
use Koha::BackgroundJobs;
use Koha::BackgroundJob::PseudonymizeStatistic;

use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
my $dtf     = $schema->storage->datetime_parser;

subtest 'enqueue() tests' => sub {

    plan tests => 4;

    $schema->storage->txn_begin;

    my $patron = $builder->build_object( { class => 'Koha::Patrons' } );
    my $item   = $builder->build_sample_item();

    throws_ok {
        Koha::BackgroundJob::PseudonymizeStatistic->new->enqueue()
    }
    'Koha::Exceptions::MissingParameter',
        "Exception thrown if 'statistic' param is missing";

    my $statistic = $builder->build_object(
        {
            class => 'Koha::Statistics',
            value => { type => 'issue', borrowernumber => $patron->id, itemnumber => $item->id }
        }
    );

    my $job_id = Koha::BackgroundJob::PseudonymizeStatistic->new->enqueue( { statistic => $statistic->unblessed } );

    my $job = Koha::BackgroundJobs->find($job_id)->_derived_class;

    is( $job->size,   1,         'Size is correct' );
    is( $job->status, 'new',     'Initial status set correctly' );
    is( $job->queue,  'default', 'PseudonymizeStatistic should use the default queue' );

    $schema->storage->txn_rollback;
};

subtest 'process() tests' => sub {

    plan tests => 4;

    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'bcrypt_settings', '$2a$08$9lmorEKnwQloheaCLFIfje' );
    t::lib::Mocks::mock_preference( 'Pseudonymization',                  1 );
    t::lib::Mocks::mock_preference( 'PseudonymizationPatronFields',      'branchcode,categorycode,sort1' );
    t::lib::Mocks::mock_preference( 'PseudonymizationTransactionFields', 'datetime' );

    my $patron    = $builder->build_object( { class => 'Koha::Patrons' } );
    my $item      = $builder->build_sample_item();
    my $statistic = $builder->build_object(
        {
            class => 'Koha::Statistics',
            value => {
                borrowernumber => $patron->id,
                datetime       => $dtf->format_datetime( dt_from_string()->subtract( days => 7 ) ),
                itemnumber     => $item->id,
                type           => 'issue',
            }
        }
    )->unblessed;

    my $job_id          = Koha::BackgroundJob::PseudonymizeStatistic->new->enqueue( { statistic => $statistic } );
    my $pt_count_before = Koha::PseudonymizedTransactions->search()->count();

    my $job = Koha::BackgroundJobs->find($job_id)->_derived_class;
    $job->process( { statistic => $statistic } );

    my $pt_after = Koha::PseudonymizedTransactions->search();
    is( $pt_after->count, $pt_count_before + 1, "Pseudonymized transaction added" );

    is( $statistic->{datetime}, $pt_after->last->datetime, "'datetime' column preserved" );

    $job->discard_changes;
    is( $job->data,     '{"data":""}', "Job data cleared after pseudonymization" );
    is( $job->progress, 1,             "Job progress is updated" );

    $schema->storage->txn_rollback;
};

subtest 'Operator eligibility is frozen through JSON and base-class dispatch' => sub {
    $schema->storage->txn_begin;

    t::lib::Mocks::mock_config( 'bcrypt_settings', '$2a$04$9lmorEKnwQloheaCLFIfje' );
    t::lib::Mocks::mock_preference( 'Pseudonymization',                  1 );
    t::lib::Mocks::mock_preference( 'PseudonymizationPatronFields',      '' );
    t::lib::Mocks::mock_preference( 'PseudonymizationTransactionFields', 'operator,interface,itemnumber' );

    # Keep real enqueue/storage/dispatch; only isolate the external broker.
    my $broker = Test::MockModule->new('Koha::BackgroundJob');
    $broker->mock( connect => sub { return } );

    my $target    = $builder->build_object( { class => 'Koha::Patrons', value => { flags => 0 } } );
    my $item      = $builder->build_sample_item;
    my $statistic = {
        type   => 'issue',           borrowernumber => $target->id,  itemnumber => $item->id,
        branch => $item->homebranch, ccode          => $item->ccode, itemtype   => $item->effective_itemtype,
    };

    my @cases = (
        { flags => 0,     name     => 'ordinary patron' },
        { flags => undef, name     => 'NULL flags patron' },
        { flags => 2,     eligible => 1, name     => 'module staff' },
        { flags => 0,     granular => 1, eligible => 1, name => 'granular staff' },
        {
            flags => 2, before_enqueue => 'revoke',
            name  => 'module permissions revoked before enqueue with stale session flags'
        },
        {
            flags => 0, before_enqueue => 'grant', eligible => 1,
            name  => 'module permissions granted before enqueue with stale session flags'
        },
        { flags => 2, before_enqueue => 'delete', name => 'operator deleted before enqueue with stale session flags' },
        { flags => 0, change         => 'grant',  name => 'permissions granted after enqueue' },
        { flags => 0, change         => 'grant_granular', name => 'granular permissions granted after enqueue' },
        { flags => 2, change         => 'revoke', eligible => 1, name => 'module permissions revoked after enqueue' },
        {
            flags => 0, granular => 1, change => 'revoke', eligible => 1,
            name  => 'granular permissions revoked after enqueue'
        },
        { flags => 2, change => 'delete', eligible => 1, name => 'operator deleted after enqueue' },
        {
            flags => 0, granular => 1, change => 'delete', eligible => 1,
            name  => 'granular operator deleted after enqueue'
        },
        { flags => 2, no_userenv => 1, name   => 'maintenance without userenv' },
        { flags => 0, granular   => 1, legacy => 1, enqueue_eligible => 1, name => 'legacy zero bitmask fails closed' },
        {
            flags => 0, legacy => 1, change => 'grant',
            name  => 'legacy ordinary patron granted permissions after enqueue'
        },
        { flags => undef, legacy   => 1, name       => 'legacy NULL bitmask fails closed' },
        { flags => 2,     legacy   => 1, eligible   => 1, name => 'legacy module bitmask proves eligibility' },
        { flags => 0,     legacy   => 1, no_context => 1, name => 'legacy missing context fails closed' },
        { flags => 2,     disabled => 1, name       => 'operator disabled at enqueue' },
        { flags => 2,     disable_processing => 1, eligible => 1, name => 'operator disabled at processing' },
    );
    for my $case (@cases) {
        subtest $case->{name} => sub {
            my $actor    = $builder->build_object( { class => 'Koha::Patrons', value => { flags => $case->{flags} } } );
            my $actor_id = $actor->id;
            $actor->_result->user_permissions->create( { module_bit => 1, code => 'circulate_remaining_permissions' } )
                if $case->{granular};
            t::lib::Mocks::mock_userenv( { patron => $actor } );
            C4::Context->userenv->{flags} = $case->{flags};
            C4::Context->interface('api');
            t::lib::Mocks::mock_preference(
                'PseudonymizationTransactionFields',
                $case->{disabled} ? 'interface,itemnumber' : 'operator,interface,itemnumber'
            );
            if ( $case->{before_enqueue} ) {
                if ( $case->{before_enqueue} eq 'delete' ) {
                    $actor->delete;
                } else {
                    $actor->flags( $case->{before_enqueue} eq 'grant' ? 2 : 0 )->store;
                }
                is(
                    C4::Context->userenv->{flags}, $case->{flags},
                    'Session flags deliberately remain stale at enqueue'
                );
            }
            my $enqueue_context;
            if ( $case->{no_userenv} ) {
                $enqueue_context = Test::MockModule->new('C4::Context');
                $enqueue_context->mock( userenv => sub { return } );
            }
            my $id = Koha::BackgroundJob::PseudonymizeStatistic->new->enqueue( { statistic => $statistic } );
            $enqueue_context->unmock('userenv') if $enqueue_context;
            my $job = Koha::BackgroundJobs->find($id);
            is( ref($job), 'Koha::BackgroundJob', 'Dispatch starts from the base class' );
            my $data = $job->decoded_data;
            ok( exists $data->{operator}, 'New jobs store an explicit operator decision, including NULL' );
            is(
                $data->{operator}, $case->{eligible} || $case->{enqueue_eligible} ? $actor_id : undef,
                'JSON preserves the enqueue decision'
            );

            if ( $case->{legacy} ) {
                delete $data->{operator};
                $job->data( $job->json->encode($data) )->store;
            }
            $job->context(undef)->store if $case->{no_context};
            if ( ( $case->{change} // '' ) eq 'grant' ) {
                $actor->flags(2)->store;
            } elsif ( ( $case->{change} // '' ) eq 'grant_granular' ) {
                $actor->_result->user_permissions->create(
                    { module_bit => 1, code => 'circulate_remaining_permissions' } );
            } elsif ( ( $case->{change} // '' ) eq 'revoke' ) {
                $actor->flags(0)->store;
                $actor->_result->user_permissions->delete;
            } elsif ( ( $case->{change} // '' ) eq 'delete' ) {
                $actor->delete;
            }
            my $expected = $case->{eligible} && !$case->{disable_processing} ? $actor_id : undef;

            # Supply a different, privileged worker context: only stored job evidence may be used.
            t::lib::Mocks::mock_userenv( { patron => $target, flags => 2 } );
            C4::Context->interface('cron');
            t::lib::Mocks::mock_preference(
                'PseudonymizationTransactionFields',
                $case->{disable_processing} ? 'interface,itemnumber' : 'operator,interface,itemnumber'
            );
            my $before = Koha::PseudonymizedTransactions->search( { itemnumber => $item->id } )->count;
            if ( $case->{no_context} ) {

                # Base dispatch logs the absent legacy context; silence only that logger.
                my $logger = Test::MockModule->new('Koha::Logger');
                $logger->mock( get => sub { return bless {}, 'PseudonymizationTestLogger' } );
                $job->process( $job->decoded_data );
            } else {
                $job->process( $job->decoded_data );
            }
            my $transactions = Koha::PseudonymizedTransactions->search(
                { itemnumber => $item->id },
                { order_by   => { -desc => 'id' } }
            );
            is( $transactions->count, $before + 1, 'One fixture-owned transaction was created' );
            my $pseudo = $transactions->next;
            is( $pseudo->operator, $expected, 'Processing uses enqueue eligibility despite later changes' );
            is(
                $pseudo->interface, $case->{no_context} ? 'cron' : 'api',
                'Base dispatch restores the saved interface'
            );
            is( $job->get_from_storage->data, '{"data":""}', 'Finished job clears its captured arguments' );
            done_testing;
        };
    }
    $schema->storage->txn_rollback;
    done_testing;
};

{

    package PseudonymizationTestLogger;
    sub warn { return }
}
