#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Test::More;

use Koha::Patrons;
use Koha::REST::Plugin::Query;

my $patrons = Koha::Patrons->new;

my $sort = Koha::REST::Plugin::Query::_build_order_atom(
    { string => 'branchcode', result_set => $patrons }
);
is( $sort, 'me.branchcode', 'a base column is qualified before a joined query' );

my $query_ok = eval {
    $patrons->search(
        {},
        {
            join     => 'branchcode',
            order_by => $sort,
            rows     => 1,
        }
    )->next;
    1;
};
ok( $query_ok, 'joined patron query executes without ambiguous branchcode' );
diag($@) unless $query_ok;

is(
    Koha::REST::Plugin::Query::_build_order_atom(
        { string => 'me.branchcode', result_set => $patrons }
    ),
    'me.branchcode',
    'an already qualified column is unchanged'
);

done_testing;
