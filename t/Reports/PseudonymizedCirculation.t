#!/usr/bin/perl

# This file is part of Koha, licensed under the GNU GPL version 3 or later.

use Modern::Perl;
use Test::More;
use Koha::Reports::PseudonymizedCirculation;

my $report = Koha::Reports::PseudonymizedCirculation->new( { attribute_codes => [ 'A', 'B' ] } );

subtest 'Validate requests before accessing the database' => sub {
    my @invalid = (
        [ { metric            => 5 },                                 'unsupported_metric' ],
        [ { metric            => 4 },                                 'unsupported_metric' ],
        [ { line              => 'datetime; DROP TABLE statistics' }, 'unsupported_dimension' ],
        [ { column            => 'borrower_attributes.PRIVATE' },     'unsupported_dimension' ],
        [ { attribute_filters => { PRIVATE => 'x' } },                'unsupported_attribute' ],
        [ { type              => 'localuse' },                        'unsupported_type' ],
        [ { type              => 'illreq_created' },                  'unsupported_type' ],
        [ { display_by        => 'COUNT(*)' },                        'invalid_grouping' ],
        [ { day               => 'Funday' },                          'invalid_day' ],
        [ { month             => '13' },                              'invalid_month' ],
        [ { filters           => ['2100-02-29'] },                    'invalid_date' ],
        [ { filters           => ['2026-02-30'] },                    'invalid_date' ],
        [ { filters           => [ '2026-12-31', '2026-01-01' ] },    'invalid_period' ],
        [ { filters           => [ ('') x 15 ] },                     'invalid_filters' ],
    );
    for my $case (@invalid) {
        is_deeply( $report->generate( $case->[0] ), { error => $case->[1] }, $case->[1] );
    }
    for my $metric ( 1, 2, 3 ) {
        ok( !$report->query( { metric => $metric } )->{error}, "Supported metric $metric" );
    }
    ok( !$report->query( { filters => ['2000-02-29'] } )->{error}, 'Gregorian leap date is valid' );
};

subtest 'Bind untrusted values and attribute codes' => sub {
    my $payload  = q{x' OR 1=1 --};
    my $code     = q{quote'code};
    my $compiler = Koha::Reports::PseudonymizedCirculation->new( { attribute_codes => [$code] } );
    my $query    = $compiler->query(
        {
            line              => "borrower_attributes.$code", column => 'datetime',
            filters           => [ '2026-01-01', '2026-01-31', $payload ],
            attribute_filters => { $code => $payload },
        }
    );
    ok( !$query->{error}, 'Permitted attribute with a quote' );
    is( index( $query->{sql}, $payload ),                      -1, 'Filter cannot become executable SQL' );
    is( index( $query->{sql}, $code ),                         -1, 'Attribute code cannot become SQL syntax' );
    is( scalar( grep { $_ eq $payload } @{ $query->{bind} } ),  8, 'Both filters bound at every level' );
    is( scalar( grep { $_ eq $code } @{ $query->{bind} } ),     4, 'Selected attribute bound at every level' );
};

subtest 'Distinct totals, missing groups and a real zero are independent' => sub {

    # The same identifier can occur in both columns and in several attribute
    # memberships. The total counts identities, not memberships or cell sums.
    my @data = (
        { level => 'cell',   row_value => undef,  col_value => 'x', value => 1 },
        { level => 'cell',   row_value => 'NULL', col_value => 'x', value => 1 },
        { level => 'cell',   row_value => '0',    col_value => 'x', value => 1 },
        { level => 'cell',   row_value => '0',    col_value => 'y', value => 1 },
        { level => 'row',    row_value => undef,  value     => 1 },
        { level => 'row',    row_value => 'NULL', value     => 1 },
        { level => 'row',    row_value => '0',    value     => 1 },
        { level => 'column', col_value => 'x',    value     => 1 },
        { level => 'column', col_value => 'y',    value     => 1 },
        { level => 'total',  value     => 1,      events    => 4, missing_metric => 0, missing_dimensions => 1 },
    );
    my $table = $report->table( { metric => 3 }, \@data );
    is_deeply(
        [ map { $_->{rowtitle} } @{ $table->{looprow} } ], [ undef, 'NULL', '0' ],
        'Missing, literal NULL and zero remain separate'
    );
    is_deeply( [ map { $_->{value} } @{ $table->{looprow}[0]{loopcell} } ], [ 1, 0 ], 'Absent intersections are zero' );
    is_deeply(
        [ map { $_->{value} } @{ $table->{looprow}[2]{loopcell} } ], [ 1, 1 ],
        'Both cells count the identifier'
    );
    is( $table->{looprow}[2]{totalrow}, 1, 'Row total is not the cell sum' );
    is_deeply(
        [ map { $_->{totalcol} } @{ $table->{loopfooter} } ], [ 1, 1 ],
        'Column totals come from their aggregates'
    );
    is( $table->{total},              1, 'Grand total is not the row or column sum' );
    is( $table->{events},             4, 'Transaction coverage remains distinct from the selected measure' );
    is( $table->{missing_dimensions}, 1, 'Missing dimension coverage is retained' );
};

subtest 'No retained identifier is unknown, not zero' => sub {
    my @data = map { { level => $_, row_value => 'a', col_value => 'b', value => 0, events => 2, missing_metric => 2 } }
        qw(cell row column total);
    my $table = $report->table( { metric => 3 }, \@data );
    ok( !defined $table->{looprow}[0]{loopcell}[0]{value}, 'Cell with no identifiers is unknown' );
    ok( !defined $table->{looprow}[0]{totalrow},           'Row with no identifiers is unknown' );
    ok( !defined $table->{loopfooter}[0]{totalcol},        'Column with no identifiers is unknown' );
    ok( !defined $table->{total},                          'Grand total with no identifiers is unknown' );
    my $empty = $report->table(
        { metric => 3 },
        [ { level => 'total', value => 0, events => 0, missing_metric => 0 } ]
    );
    is( $empty->{total}, 0, 'No matching transactions is a real zero' );
    $data[-1]{events} = 3;
    $data[-1]{value}  = 1;
    $table            = $report->table( { metric => 3 }, \@data );
    is( $table->{total},          1, 'Partial coverage counts recorded identifiers' );
    is( $table->{missing_metric}, 2, 'Partial coverage warning is not lost' );
};

done_testing;
