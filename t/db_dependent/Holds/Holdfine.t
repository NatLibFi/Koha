#!/usr/bin/perl

# Copyright The National Library of Finland, University of Helsinki 2020
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use C4::Context;
use Koha::CirculationRules;

use Test::More tests => 10;

use t::lib::TestBuilder;
use t::lib::Mocks;
use Koha::Holds;

use Koha::Account;
use Koha::Account::DebitTypes;

BEGIN {
    use_ok('C4::Reserves');
}

my $schema = Koha::Database->schema;
$schema->storage->txn_begin;
my $dbh = C4::Context->dbh;

my $builder = t::lib::TestBuilder->new;

my $library1 = $builder->build({
    source => 'Branch',
});

my $bib_title = "Test Title";

my $borrower = $builder->build({
    source => 'Borrower',
    value => {
        branchcode => $library1->{branchcode},
    }
});

my $borrowernumber = $borrower->{borrowernumber};
my $library_A_code = $library1->{branchcode};

my $biblio = $builder->build_sample_biblio({itemtype=>'BK'});
my $biblionumber = $biblio->biblionumber;
my $item1 = $builder->build_sample_item({
    biblionumber => $biblionumber,
    itype => 'CF',
    homebranch => $library_A_code,
    holdingbranch => $library_A_code
});
my $item2 = $builder->build_sample_item({
    biblionumber => $biblionumber,
    itype => 'MU',
    homebranch => $library_A_code,
    holdingbranch => $library_A_code
});
my $item3 = $builder->build_sample_item({
    biblionumber => $biblionumber,
    itype => 'MX',
    homebranch => $library_A_code,
    holdingbranch => $library_A_code
});

$dbh->do("DELETE FROM circulation_rules");
Koha::CirculationRules->set_rules(
    {
        itemtype     => 'CF',
        categorycode => undef,
        branchcode   => undef,
        rules        => {
            expire_reserves_charge => '111'
        }
    }
);
Koha::CirculationRules->set_rules(
    {
        itemtype     => 'MU',
        categorycode => undef,
        branchcode   => undef,
        rules        => {
            expire_reserves_charge => undef
        }
    }
);

my $reserve_id;
my $account;
my $status;
my $start_balance;

# TEST: Hold Computer File item
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
is( $status, 'Reserved', "Hold for the CF created" );

$start_balance = $account->balance();

Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

( $status ) = CheckReserves($item1->id);
is( $status, '', "Hold for the CF cancelled" );

is( $account->balance() - $start_balance, 111, "Account debt is 111" );

# TEST: Hold Music item that has 'expire_reserves_charge' set undef
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
is( $status, 'Reserved', "Hold for the MU created" );

$start_balance = $account->balance();

Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

( $status ) = CheckReserves($item2->id);
is( $status, '', "Hold for the MU cancelled" );

is( $account->balance() - $start_balance, 222, "Account debt is 222" );

# TEST: Hold MX item that has no circulation rules
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
is( $status, 'Reserved', "Hold for the MX created" );

$start_balance = $account->balance();

Koha::Holds->find( $reserve_id )->cancel({ charge_cancel_fee => 1 });

( $status ) = CheckReserves($item3->id);
is( $status, '', "Hold for the MX cancelled" );

is( $account->balance() - $start_balance, 333, "Account debt is 333" );

$schema->storage->txn_rollback;
