#!/usr/bin/perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;
use Test::More tests => 4;
use Test::NoWarnings;
use FindBin qw($Bin);

use C4::Context;
use C4::Installer qw(column_exists index_exists);

my $dbh    = C4::Context->dbh;
my $update = do "$Bin/../../../installer/data/mysql/atomicupdate/bug-33013_more-pseudonymization-fields.pl";
die $@ || $! unless $update;

open my $sql_fh, '<', "$Bin/../../../installer/data/mysql/kohastructure.sql" or die $!;
my $sql = do { local $/; <$sql_fh> };
close $sql_fh;
my ($fresh) = $sql =~ /(CREATE TABLE `pseudonymized_transactions` \(.*?\n\) ENGINE=.*?;)/s;
die 'Cannot find fresh-install pseudonymized_transactions definition' unless $fresh;
$fresh =~ s/^CREATE TABLE/CREATE TEMPORARY TABLE/;

# All DDL and preference writes below affect connection-local temporary tables.
# They shadow the real tables and are discarded even if the test process fails.
$dbh->do('CREATE TEMPORARY TABLE systempreferences (variable varchar(80) PRIMARY KEY, value text)');
for my $shape ( 'missing', 'partial', 'fresh' ) {
    subtest "$shape columns" => sub {
        if ( $shape eq 'fresh' ) {
            $dbh->do($fresh);
        } else {
            $dbh->do( 'CREATE TEMPORARY TABLE pseudonymized_transactions ('
                    . 'id int PRIMARY KEY AUTO_INCREMENT, hashed_borrowernumber varchar(60), '
                    . 'sex varchar(1), transaction_type varchar(16))' );
            $dbh->do('ALTER TABLE pseudonymized_transactions ADD COLUMN age tinyint(4) DEFAULT NULL')
                if $shape eq 'partial';
        }
        $dbh->do("INSERT INTO pseudonymized_transactions (hashed_borrowernumber) VALUES ('migration-fixture')");
        $dbh->do('UPDATE pseudonymized_transactions SET age = 37')                          if $shape ne 'missing';
        $dbh->do("UPDATE pseudonymized_transactions SET interface = 'api', operator = 123") if $shape eq 'fresh';

        for my $selection ( [ '', '' ], [ 'sort1,sex', 'itemnumber,transaction_type' ] ) {
            $dbh->do('DELETE FROM systempreferences');
            my @names = qw(PseudonymizationPatronFields PseudonymizationTransactionFields);
            for my $i ( 0 .. 1 ) {
                $dbh->do(
                    'INSERT INTO systempreferences (variable,value) VALUES (?,?)', undef, $names[$i],
                    $selection->[$i]
                );
            }
            for my $run ( 1 .. 2 ) {
                my $output = '';
                open my $out, '>', \$output or die $!;
                $update->{up}->( { dbh => $dbh, out => $out } );
                close $out;
                ok( length($output), "Run $run reports completion" );
                for my $column (qw(age interface operator)) {
                    ok( column_exists( 'pseudonymized_transactions', $column ), "$column exists after run $run" );
                }
                for my $index (qw(pseudonymized_transactions_reporting_1 pseudonymized_transactions_reporting_2)) {
                    ok( index_exists( 'pseudonymized_transactions', $index ), "$index exists after run $run" );
                }
                my $values = $dbh->selectall_arrayref('SELECT value FROM systempreferences ORDER BY variable');
                is_deeply(
                    $values, [ map { [$_] } @$selection ],
                    "Run $run preserves empty or custom selections without enabling fields"
                );
                my $row = $dbh->selectrow_hashref('SELECT * FROM pseudonymized_transactions');
                is( $row->{hashed_borrowernumber}, 'migration-fixture', 'Existing data survives' );
                is(
                    $row->{age}, $shape eq 'missing' ? undef : 37,
                    'New age defaults to NULL and existing age is preserved'
                );
                is(
                    $row->{interface}, $shape eq 'fresh' ? 'api' : undef,
                    'New interface defaults to NULL and existing interface is preserved'
                );
                is(
                    $row->{operator}, $shape eq 'fresh' ? 123 : undef,
                    'New operator defaults to NULL and existing operator is preserved'
                );
            }
        }
        my $columns = $dbh->selectall_arrayref( 'SHOW COLUMNS FROM pseudonymized_transactions', { Slice => {} } );
        my %types   = map { $_->{Field} => $_->{Type} } @$columns;
        like( $types{age}, qr/^tinyint\b/, 'Age has the numeric fresh-install type' );
        is( $types{interface}, 'varchar(16)', 'Interface type agrees with fresh install' );
        like( $types{operator}, qr/^int\b/, 'Operator type agrees with fresh install' );
        $dbh->do('DROP TEMPORARY TABLE pseudonymized_transactions');
        done_testing;
    };
}
$dbh->do('DROP TEMPORARY TABLE systempreferences');
