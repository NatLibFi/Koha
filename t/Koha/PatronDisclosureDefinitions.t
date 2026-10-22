#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use FindBin;
use Test::More;
use YAML::XS qw( LoadFile );

use Koha::Patron::Disclosure::Definitions;

my $definitions = 'Koha::Patron::Disclosure::Definitions';
my $path_dir    = "$FindBin::Bin/../../api/v1/swagger/paths";
my @files = qw(
    biblios.yaml bookings.yaml items.yaml patrons.yaml
    patrons_checkouts.yaml patrons_holds.yaml patrons_recalls.yaml
);
my @references;

for my $file (@files) {
    my $paths = LoadFile("$path_dir/$file");
    for my $path ( sort keys %{$paths} ) {
        for my $method ( sort keys %{ $paths->{$path} } ) {
            next unless ref( $paths->{$path}->{$method} ) eq 'HASH';
            my $operation = $paths->{$path}->{$method};
            next unless exists $operation->{'x-koha-patron-disclosure'};

            my $reference = $operation->{'x-koha-patron-disclosure'};
            is( $reference, uc($method) . " $path", "binding identifies $method $path" );
            push @references, $reference;

            my $policy = $definitions->rest_operation($reference);
            ok( $policy, "$reference has a policy" );
            next unless $policy;
            ok( $definitions->surface_breadth( $policy->{surface} ), "$reference has a known surface" );
            ok( scalar keys %{ $policy->{strategies} }, "$reference has a collection strategy" );
            for my $status ( keys %{ $policy->{success_statuses} } ) {
                ok( exists $operation->{responses}->{$status}, "$reference declares success $status" );
            }
            if ( $policy->{path_patron} ) {
                my %valid = map { $_ => 1 } @{ $definitions->valid_data_classes };
                ok( !grep( { !$valid{$_} } @{ $policy->{path_patron}->{data_classes} } ),
                    "$reference uses known path classes" );
            }
            if ( $policy->{max_page_size} ) {
                ok( $policy->{subjects_per_page_item} > 0, "$reference has a positive page fanout" );
            }
        }
    }
}

is_deeply(
    [ sort @references ],
    $definitions->rest_operation_keys,
    'every annotated operation has exactly one policy and no policy is orphaned'
);
is( scalar @{ $definitions->valid_data_classes }, 12, 'the accepted class vocabulary is complete' );
is( scalar @{ $definitions->surface_ids }, 31, 'the accepted surface vocabulary is complete' );

done_testing;
