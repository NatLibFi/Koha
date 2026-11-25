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
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use Capture::Tiny qw( capture_stdout );
use Test::More;

use C4::Reserves qw( CancelExpiredReserves );
use Koha::Database;
use Koha::DateUtils qw( dt_from_string );
use Koha::Holds;
use Koha::Items;
use Koha::Old::Holds;
use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

t::lib::Mocks::mock_preference( 'ExpireReservesOnHolidays',     1 );
t::lib::Mocks::mock_preference( 'ExpireReservesMaxPickUpDelay', 1 );
t::lib::Mocks::mock_preference( 'ExpireReservesAutoFill',       0 );
t::lib::Mocks::mock_preference( 'RealTimeHoldsQueue',           0 );
t::lib::Mocks::mock_preference( 'UseKohaPlugins',               0 );

my $today   = dt_from_string();
my $expired = $today->clone->subtract( days => 1 )->ymd;

sub build_hold {
    my ($status) = @_;
    my $item = $builder->build_object( { class => 'Koha::Items' } );
    return $builder->build_object(
        {
            class => 'Koha::Holds',
            value => {
                biblionumber           => $item->biblionumber,
                itemnumber             => $item->itemnumber,
                reservedate            => $today->ymd,
                expirationdate         => $expired,
                patron_expiration_date => undef,
                cancellationdate       => undef,
                found                  => $status,
                priority               => defined $status ? 0           : 1,
                waitingdate            => defined $status ? $today->ymd : undef,
            },
        }
    );
}

for my $status ( undef, 'W' ) {
    my $label = $status // 'queued';
    subtest "Dry run previews an expired $label hold" => sub {
        $schema->storage->txn_begin;
        my $hold = build_hold($status);
        my $id   = $hold->id;

        my $error;
        my $preview = capture_stdout {
            eval { CancelExpiredReserves( undef, { dry_run => 1 } ) };
            $error = $@;
        };

        is( $error, '', 'The preview completes without an exception' );
        like( $preview, qr/\b\Q$id\E\b/, 'The preview identifies the eligible hold' );
        my $active = Koha::Holds->find($id);
        is_deeply( $active && $active->unblessed, $hold->unblessed, 'The active hold is unchanged' );
        ok( !Koha::Old::Holds->find($id), 'The hold has not been archived' );

        $schema->storage->txn_rollback;
    };
}

subtest 'An ordinary run still cancels expired waiting and queued holds' => sub {
    $schema->storage->txn_begin;
    my $queued  = build_hold(undef);
    my $waiting = build_hold('W');

    CancelExpiredReserves();
    for my $hold ( $queued, $waiting ) {
        ok( !Koha::Holds->find( $hold->id ),     'The hold is removed from the active queue' );
        ok( Koha::Old::Holds->find( $hold->id ), 'The cancelled hold is archived' );
    }

    $schema->storage->txn_rollback;
};

done_testing;
