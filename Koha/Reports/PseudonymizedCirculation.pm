package Koha::Reports::PseudonymizedCirculation;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.

use Modern::Perl;

my %fields = (
    datetime                 => 'e.datetime',
    branch                   => 'e.transaction_branchcode',
    itemtype                 => 'e.itemtype',
    'borrowers.categorycode' => 'e.categorycode',
    'borrowers.branchcode'   => 'e.branchcode',
    'borrowers.sort1'        => 'e.sort1',
    'borrowers.sort2'        => 'e.sort2',
    'items.ccode'            => 'e.ccode',
    'items.location'         => 'e.location',
    'items.homebranch'       => 'e.homebranch',
    'items.holdingbranch'    => 'e.holdingbranch',
    'items.itemcallnumber'   => 'e.itemcallnumber',
);

my @filter_fields = (
    undef,                 undef,                  'borrowers.categorycode', 'itemtype', 'branch', 'items.ccode',
    'items.location',      'items.itemcallnumber', 'items.itemcallnumber',
    'borrowers.sort1',     'borrowers.sort2',      'items.homebranch',
    'items.holdingbranch', 'borrowers.branchcode',
);
my @circulation_types = qw(issue renew return onsite_checkout);
my %days   = map { $_ => 1 } qw(Monday Tuesday Wednesday Thursday Friday Saturday Sunday);
my %months = map { $_ => 1 } qw(January February March April May June July August September October November December);

=head1 NAME

Koha::Reports::PseudonymizedCirculation - Retained pseudonymized data for the circulation statistics wizard

=head1 API

=head2 Class methods

=head3 new

    my $report = Koha::Reports::PseudonymizedCirculation->new({
        dbh => $dbh, attribute_codes => [ @permitted_patron_attribute_codes ],
    });

Attribute codes must already be restricted to the user's permitted libraries.
The report never returns event identifiers or patron hashes.

=cut

sub new {
    my ( $class, $args ) = @_;
    return bless {
        dbh        => $args->{dbh},
        attributes => { map { $_ => 1 } @{ $args->{attribute_codes} // [] } },
    }, $class;
}

=head3 retained_attribute_codes

Return permitted attribute codes with retained metadata. The current
keep_for_pseudonymization setting does not describe previously retained values.

=cut

sub retained_attribute_codes {
    my ($self) = @_;
    my @codes = sort keys %{ $self->{attributes} };
    return [] unless @codes;
    my $placeholders = join ',', ('?') x @codes;
    return $self->{dbh}->selectcol_arrayref(
        "SELECT DISTINCT `key` FROM pseudonymized_metadata_values WHERE tablename = ? AND `key` IN ($placeholders)",
        undef, 'borrower_attributes', @codes,
    );
}

=head3 query

Compile validated pseudonymized-report parameters into SQL and bind values,
or return an error code. One statement combines four aggregation levels of the
retained records, so cells and totals use the same database snapshot. No live
patron/item data or statistics rows are joined.

=cut

sub query {
    my ( $self, $params ) = @_;
    my %p = %$params;
    $p{metric} //= 1;
    my %metrics = map { $_ => 1 } ( 1, 2, 3 );
    return { error => 'unsupported_metric' } unless $metrics{ $p{metric} };
    $p{line}       //= 'branch';
    $p{column}     //= 'datetime';
    $p{display_by} //= '';
    return { error => 'invalid_grouping' } unless $p{display_by} =~ /\A[1-4]?\z/;
    my %types = map { $_ => 1 } @circulation_types;
    return { error => 'unsupported_type' } if length( $p{type}  // '' ) && !$types{ $p{type} };
    return { error => 'invalid_day' }      if length( $p{day}   // '' ) && !$days{ $p{day} };
    return { error => 'invalid_month' }    if length( $p{month} // '' ) && !$months{ $p{month} };
    my @filters = @{ $p{filters} // [] };
    return { error => 'invalid_filters' } if @filters > @filter_fields;

    for my $index ( 0, 1 ) {
        return { error => 'invalid_date' }
            if length( $filters[$index] // '' ) && !_valid_date( $filters[$index] );
    }
    return { error => 'invalid_period' }
        if length( $filters[0] // '' ) && length( $filters[1] // '' ) && $filters[0] gt $filters[1];
    my %attribute_filters = %{ $p{attribute_filters} // {} };
    for my $code ( keys %attribute_filters ) {
        return { error => 'unsupported_attribute' } unless $self->{attributes}{$code};
    }

    my ( @joins, @join_bind, %aliases );
    for my $axis (qw(line column)) {
        my $field = $p{$axis};
        next if $field ne 'items.itemcallnumber' && exists $fields{$field};
        my ($code) = $field =~ /\Aborrower_attributes\.(.+)\z/;
        return { error => 'unsupported_dimension' } unless defined $code && $self->{attributes}{$code};
        next if exists $aliases{$code};
        my $alias = 'a' . scalar( keys %aliases );
        $aliases{$code} = $alias;

        # The distinct aggregates already handle duplicate attribute values.
        # Join through transaction_id to avoid materializing all retained metadata.
        push @joins,
            "LEFT JOIN pseudonymized_metadata_values $alias ON $alias.transaction_id = e.id"
            . " AND $alias.tablename = ? AND $alias.`key` = ?";
        push @join_bind, 'borrower_attributes', $code;
    }

    my $column = sub {
        my ($field) = @_;
        return $fields{$field} if exists $fields{$field};
        my ($code) = $field =~ /\Aborrower_attributes\.(.+)\z/;
        return "$aliases{$code}.value";
    };
    my ( @event_where, @event_bind );
    if ( length( $filters[0] // '' ) ) {
        push @event_where, 's.datetime >= ?';
        push @event_bind,  $filters[0];
    }
    if ( length( $filters[1] // '' ) ) {
        push @event_where, 's.datetime < DATE_ADD(?, INTERVAL 1 DAY)';
        push @event_bind,  $filters[1];
    }
    if ( length( $p{type} // '' ) ) {
        push @event_where, 's.transaction_type = ?';
        push @event_bind,  $p{type};
    } else {
        push @event_where, 's.transaction_type IN (' . join( ',', ('?') x @circulation_types ) . ')';
        push @event_bind,  @circulation_types;
    }
    my $event_where = @event_where ? ' WHERE ' . join( ' AND ', @event_where ) : '';
    my $from        = "(SELECT s.* FROM pseudonymized_transactions s$event_where) e";
    $from .= ' ' . join( ' ', @joins ) if @joins;

    my ( @where, @where_bind );
    for my $index ( 2 .. $#filter_fields ) {
        next unless length( $filters[$index] // '' );
        my $operator = $index == 7 ? '>=' : $index == 8 ? '<' : 'LIKE';
        push @where, $column->( $filter_fields[$index] ) . " $operator ?";
        my $value = $filters[$index];
        $value =~ s/\*/%/g if $operator eq 'LIKE';
        push @where_bind, $value;
    }
    if ( length( $p{day} // '' ) ) {
        push @where,      'DAYNAME(e.datetime) = ?';
        push @where_bind, $p{day};
    }
    if ( length( $p{month} // '' ) ) {
        push @where,      'MONTHNAME(e.datetime) = ?';
        push @where_bind, $p{month};
    }
    for my $code ( sort keys %attribute_filters ) {
        next unless length( $attribute_filters{$code} // '' );
        my $value = $attribute_filters{$code};
        $value =~ s/\*/%/g;
        if ( exists $aliases{$code} ) {
            push @where,      "$aliases{$code}.value LIKE ?";
            push @where_bind, $value;
        } else {
            push @where,
                'EXISTS (SELECT 1 FROM pseudonymized_metadata_values f WHERE f.transaction_id = e.id AND f.tablename = ? AND f.`key` = ? AND f.value LIKE ?)';
            push @where_bind, 'borrower_attributes', $code, $value;
        }
    }
    my $where = @where ? ' WHERE ' . join( ' AND ', @where ) : '';
    my ( $row, $row_order ) = _dimension( $column->( $p{line} ), $p{line}, $p{display_by} );
    my ( $col, $col_order ) = _dimension( $column->( $p{column} ), $p{column}, $p{display_by} );
    my $event_key = 'e.id';
    my $metric_key =
          $p{metric} == 1 ? $event_key
        : $p{metric} == 2 ? 'e.hashed_borrowernumber'
        :                   'e.itemnumber';
    my ( @queries, @bind );
    for my $level (qw(cell row column total)) {
        my $has_row    = $level eq 'cell' || $level eq 'row';
        my $has_col    = $level eq 'cell' || $level eq 'column';
        my $row_select = $has_row ? $row              : 'NULL';
        my $col_select = $has_col ? $col              : 'NULL';
        my $row_sort   = $has_row ? "MIN($row_order)" : 'NULL';
        my $col_sort   = $has_col ? "MIN($col_order)" : 'NULL';
        my $sql =
              "SELECT '$level' AS level, $row_select AS row_value, $col_select AS col_value,"
            . " $row_sort AS row_order, $col_sort AS col_order, COUNT(DISTINCT $metric_key) AS value,"
            . " COUNT(DISTINCT $event_key) AS events,"
            . " COUNT(DISTINCT CASE WHEN $metric_key IS NULL THEN $event_key END) AS missing_metric,"
            . " COUNT(DISTINCT CASE WHEN $row IS NULL OR $col IS NULL THEN $event_key END) AS missing_dimensions"
            . " FROM $from$where";
        my @group = ( $has_row ? ('row_value') : (), $has_col ? ('col_value') : () );
        $sql .= ' GROUP BY ' . join( ', ', @group ) if @group;
        push @queries, $sql;
        push @bind, @event_bind, @join_bind, @where_bind;
    }
    return {
        sql    => join( ' UNION ALL ', @queries ) . ' ORDER BY row_order, row_value, col_order, col_value',
        bind   => \@bind,
        source => 'pseudonymized',
        metric => $p{metric},
        line   => $p{line},
        column => $p{column},
    };
}

=head3 generate

Return cells and independently aggregated row, column and grand totals in the
wizard's template structure. Missing values have their own group. Distinct
totals are never inferred by adding the displayed cells.

=cut

sub generate {
    my ( $self, $params ) = @_;
    my $query = $self->query($params);
    return $query if $query->{error};
    my $rows = $self->{dbh}->selectall_arrayref( $query->{sql}, { Slice => {} }, @{ $query->{bind} } );
    return $self->table( $query, $rows );
}

=head3 table

Build the display matrix from the four aggregation levels. This method is pure
and can also be used to verify grouping and distinct totals without a database.

=cut

sub table {
    my ( $self, $query, $data ) = @_;
    my ( @rows, @cols, %cells, %row_totals, %col_totals, $total, $events, $missing_metric, $missing_dimensions );
    my $has_total = 0;
    for my $record (@$data) {
        if (   ( $record->{events} // 0 ) > 0
            && ( $record->{missing_metric} // 0 ) == $record->{events} )
        {
            # No recorded identifiers is not evidence of zero distinct items.
            $record = { %$record, value => undef };
        }
        my $r = _key( $record->{row_value} );
        my $c = _key( $record->{col_value} );
        if ( $record->{level} eq 'cell' ) {
            $cells{$r}{$c} = $record->{value};
        } elsif ( $record->{level} eq 'row' ) {
            push @rows, {
                rowtitle => $record->{row_value}, rowtitle_display => $record->{row_value},
                missing  => defined $record->{row_value} ? 0 : 1,
            };
            $row_totals{$r} = $record->{value};
        } elsif ( $record->{level} eq 'column' ) {
            push @cols, {
                coltitle => $record->{col_value}, coltitle_display => $record->{col_value},
                missing  => defined $record->{col_value} ? 0 : 1,
            };
            $col_totals{$c} = $record->{value};
        } elsif ( $record->{level} eq 'total' ) {
            $has_total = 1;
            ( $total, $events, $missing_metric, $missing_dimensions ) =
                @$record{qw(value events missing_metric missing_dimensions)};
        }
    }
    for my $row (@rows) {
        my $key = _key( $row->{rowtitle} );
        $row->{loopcell} = [
            map {
                my $column_key = _key( $_->{coltitle} );
                { value => exists $cells{$key}{$column_key} ? $cells{$key}{$column_key} : 0 }
            } @cols
        ];
        $row->{totalrow} = $row_totals{$key};
    }
    return {
        source     => $query->{source}, metric  => $query->{metric}, line => $query->{line}, column => $query->{column},
        looprow    => \@rows,           loopcol => \@cols,
        loopfooter => [ map { { totalcol => $col_totals{ _key( $_->{coltitle} ) } } } @cols ],
        total      => $has_total ? $total : 0, events => $events // 0,
        missing_metric => $missing_metric // 0, missing_dimensions => $missing_dimensions // 0,
    };
}

=head2 Internal methods

=head3 _dimension

Return a whitelisted dimension expression and its chronological sort expression.

=cut

sub _dimension {
    my ( $expression, $field, $display ) = @_;
    if ( $field eq 'datetime' ) {
        return ( "DAYNAME($expression)",   "WEEKDAY($expression)" ) if $display eq '1';
        return ( "MONTHNAME($expression)", "MONTH($expression)" )   if $display eq '2';
        return ( "YEAR($expression)",      "YEAR($expression)" )    if $display eq '3';
        return ( "HOUR($expression)",      "HOUR($expression)" )    if $display eq '4';
        return ( "DATE($expression)",      "DATE($expression)" );
    }
    return ( "NULLIF(TRIM($expression), '')", "NULLIF(TRIM($expression), '')" );
}

=head3 _key

Keep missing values separate from every actual string, including "NULL" or zero.

=cut

sub _key {
    return defined $_[0] ? 'v' . $_[0] : 'n';
}

=head3 _valid_date

Validate a Gregorian YYYY-MM-DD value before it is passed to SQL.

=cut

sub _valid_date {
    my ($date) = @_;
    my ( $year, $month, $day ) = $date =~ /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/;
    return 0 unless defined $year && $year > 0 && $month >= 1 && $month <= 12;
    my @days = ( 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
    $days[1]++ if $year % 4 == 0 && ( $year % 100 != 0 || $year % 400 == 0 );
    return $day >= 1 && $day <= $days[ $month - 1 ] ? 1 : 0;
}

1;
