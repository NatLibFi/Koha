#!/usr/bin/perl

# This file is part of Koha, licensed under the GNU GPL version 3 or later.

use Modern::Perl;
use Test::More;
use C4::Context;
use Koha::Database;
use Koha::Reports::PseudonymizedCirculation;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $dbh     = C4::Context->dbh;
my $builder = t::lib::TestBuilder->new;

sub transaction {
    my ($values) = @_;
    my %record = (
        hashed_borrowernumber => 'test-pseudonym', branchcode => '',                    categorycode => '',
        transaction_type      => 'issue',          datetime   => '2099-01-02 12:00:00', %$values,
    );
    my @keys = sort keys %record;
    $dbh->do(
              'INSERT INTO pseudonymized_transactions ('
            . join( ',', @keys )
            . ') VALUES ('
            . join( ',', ('?') x @keys ) . ')',
        undef, @record{@keys}
    );
    return $dbh->last_insert_id( undef, undef, 'pseudonymized_transactions', 'id' );
}

sub metadata {
    my ( $id, $code, $value, $table ) = @_;
    $dbh->do(
        'INSERT INTO pseudonymized_metadata_values (transaction_id, tablename, `key`, value) VALUES (?, ?, ?, ?)',
        undef, $id, $table // 'borrower_attributes', $code, $value,
    );
}

sub parameters {
    my ( $branch, $extra ) = @_;
    return {
        line => 'branch', column => 'datetime', metric => 1,
        filters => [ '2099-01-02', '2099-01-03', '', '', $branch ], %{ $extra // {} },
    };
}

subtest 'Retained reporting survives statistics cleanup and live-record changes' => sub {
    $schema->storage->txn_begin;
    my $branch = $builder->build( { source => 'Branch' } )->{branchcode};
    my $patron = $builder->build( { source => 'Borrower', value => { sort1 => 'before' } } );
    my $item   = $builder->build( { source => 'Item' } );
    my $report = Koha::Reports::PseudonymizedCirculation->new( { dbh => $dbh } );

    for my $datetime ( '2099-01-02 00:00:00', '2099-01-03 23:59:59' ) {
        transaction(
            {
                transaction_branchcode => $branch,                 datetime   => $datetime,
                itemnumber             => $item->{itemnumber},     sort1      => 'before', sort2 => 'retained',
                categorycode           => $patron->{categorycode}, branchcode => $patron->{branchcode},
            }
        );
        $dbh->do(
            'INSERT INTO statistics (datetime, type, branch, itemnumber, borrowernumber) VALUES (?, ?, ?, ?, ?)',
            undef, $datetime, 'issue', $branch, $item->{itemnumber}, $patron->{borrowernumber},
        );
    }
    my $params = parameters($branch);
    my $before = $report->generate($params);
    is( $before->{total}, 2, 'Two retained transactions at inclusive date boundaries' );
    my ( $raw_events, $raw_items ) = $dbh->selectrow_array(
        'SELECT COUNT(*), COUNT(DISTINCT itemnumber) FROM statistics WHERE branch = ?', undef,
        $branch
    );
    is( $before->{total}, $raw_events, 'The same eligible transactions have the same count in either source' );
    is(
        $report->generate( parameters( $branch, { metric => 3 } ) )->{total}, $raw_items,
        'The same eligible item identifiers have the same distinct count'
    );
    is_deeply( [ map { $_->{totalcol} } @{ $before->{loopfooter} } ], [ 1, 1 ], 'Both dates are available' );
    for my $metric ( 2, 3 ) {
        my $table = $report->generate( parameters( $branch, { metric => $metric } ) );
        is( $table->{total},                1, "Metric $metric counts the identity once across dates" );
        is( $table->{looprow}[0]{totalrow}, 1, 'Row total is not a sum of date cells' );
        is_deeply(
            [ map { $_->{value} } @{ $table->{looprow}[0]{loopcell} } ], [ 1, 1 ],
            'Both date cells have that identity'
        );
    }

    # Only fixture-owned raw history is removed. Pseudonymized records must not
    # depend on statistics or on the current patron/item records.
    $dbh->do( 'DELETE FROM statistics WHERE branch = ?',                 undef, $branch );
    $dbh->do( 'UPDATE borrowers SET sort1 = ? WHERE borrowernumber = ?', undef, 'after', $patron->{borrowernumber} );
    $dbh->do( 'DELETE FROM items WHERE itemnumber = ?',                  undef, $item->{itemnumber} );
    $dbh->do( 'DELETE FROM borrowers WHERE borrowernumber = ?',          undef, $patron->{borrowernumber} );
    is_deeply( $report->generate($params), $before, 'Cleanup and entity deletion do not change retained results' );
    my $sorts = $report->generate( parameters( $branch, { line => 'borrowers.sort1', column => 'borrowers.sort2' } ) );
    is( $sorts->{looprow}[0]{rowtitle}, 'before',   'Stored sort1 survives the patron change/deletion' );
    is( $sorts->{loopcol}[0]{coltitle}, 'retained', 'Stored sort2 remains reportable' );
    $schema->storage->txn_rollback;
};

subtest 'Repeatable metadata membership never multiplies transactions or totals' => sub {
    $schema->storage->txn_begin;
    my $branch = $builder->build( { source => 'Branch' } )->{branchcode};
    my $a =
        $builder->build( { source => 'BorrowerAttributeType', value => { keep_for_pseudonymization => 0 } } )->{code};
    my $b       = $builder->build( { source => 'BorrowerAttributeType' } )->{code};
    my $private = $builder->build( { source => 'BorrowerAttributeType' } )->{code};
    my $report  = Koha::Reports::PseudonymizedCirculation->new( { dbh => $dbh, attribute_codes => [ $a, $b ] } );
    my $id      = transaction( { transaction_branchcode => $branch, itemnumber => 12345 } );
    metadata( $id, $a,       $_ ) for ( 'a1', 'a1', 'a2' );
    metadata( $id, $b,       $_ ) for ( 'b1', 'b2' );
    metadata( $id, $a,       'wrong namespace', 'illrequests' );
    metadata( $id, $private, 'not permitted' );
    is_deeply(
        [ sort @{ $report->retained_attribute_codes } ], [ sort( $a, $b ) ],
        'Retained keys respect permissions and survive collection being disabled'
    );

    my $table = $report->generate(
        parameters( $branch, { line => "borrower_attributes.$a", column => "borrower_attributes.$b" } ) );
    is_deeply(
        [ map { $_->{rowtitle} } @{ $table->{looprow} } ], [ 'a1', 'a2' ],
        'No duplicate or foreign-namespace row'
    );
    is_deeply( [ map { $_->{coltitle} } @{ $table->{loopcol} } ], [ 'b1', 'b2' ], 'Both second-attribute memberships' );
    for my $row ( @{ $table->{looprow} } ) {
        is_deeply( [ map { $_->{value} } @{ $row->{loopcell} } ], [ 1, 1 ], 'One event in each matching intersection' );
        is( $row->{totalrow}, 1, 'Independent row total' );
    }
    is_deeply( [ map { $_->{totalcol} } @{ $table->{loopfooter} } ], [ 1, 1 ], 'Independent column totals' );
    is( $table->{total}, 1, 'One transaction, despite four memberships' );
    my $filtered = $report->generate( parameters( $branch, { attribute_filters => { $a => 'a*', $b => 'b*' } } ) );
    is( $filtered->{total}, 1, 'Filter-only repeatable attributes do not cause fan-out' );
    $filtered = $report->generate(
        parameters( $branch, { line => "borrower_attributes.$a", attribute_filters => { $a => 'a1' } } ) );
    is_deeply(
        [ map { $_->{rowtitle} } @{ $filtered->{looprow} } ], ['a1'],
        'A selected dimension filter limits memberships'
    );
    my $same_axis = $report->generate(
        parameters( $branch, { line => "borrower_attributes.$a", column => "borrower_attributes.$a" } ) );
    is_deeply(
        [ map { $_->{value} } @{ $same_axis->{looprow}[0]{loopcell} } ], [ 1, 0 ],
        'The same attribute on both axes gives diagonal membership'
    );
    is( $same_axis->{total}, 1, 'Same-axis grand total stays distinct' );
    $schema->storage->txn_rollback;
};

subtest 'Source coverage and missing values are explicit' => sub {
    $schema->storage->txn_begin;
    my $branch = $builder->build( { source => 'Branch' } )->{branchcode};
    my $report = Koha::Reports::PseudonymizedCirculation->new( { dbh => $dbh } );
    for my $type (qw(issue renew return onsite_checkout illreq_created illreq_comp localuse)) {
        transaction( { transaction_branchcode => $branch, transaction_type => $type } );
    }
    transaction( { transaction_branchcode => $branch, datetime => '2099-01-04 00:00:00' } );
    my $table = $report->generate( parameters($branch) );
    is( $table->{total}, 4, 'All circulation types excludes ILL and local use, and the following day' );
    for my $type (qw(issue renew return onsite_checkout)) {
        is( $report->generate( parameters( $branch, { type => $type } ) )->{total}, 1, "Can select $type" );
    }
    $table = $report->generate( parameters( $branch, { metric => 3, line => 'items.location' } ) );
    ok( !defined $table->{total}, 'No collected item identifiers is unknown, not zero' );
    is( $table->{missing_metric},     4, 'Missing measure coverage is counted once per event' );
    is( $table->{missing_dimensions}, 4, 'Missing grouping coverage is counted once per event' );
    ok( $table->{looprow}[0]{missing}, 'Missing dimension has its own group' );
    my @filters = ( '2099-01-02', '2099-01-03', '', '', q{' OR 1=1 --} );
    is( $report->generate( { filters => \@filters } )->{total}, 0, 'SQL-looking filter remains a value' );
    $schema->storage->txn_rollback;
};

done_testing;
