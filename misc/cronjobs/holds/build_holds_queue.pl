#!/usr/bin/perl 

# Copyright 2017 Koha Development team
# Copyright Liblime 2008
# Copyright 2021 University of Helsinki (The National Library Of Finland)
#
# This file is part of Koha.
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
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use Getopt::Long qw( GetOptions :config no_ignore_case );
use Pod::Usage qw( pod2usage );

use C4::Context;
use C4::HoldsQueue qw(CreateQueue);
use C4::Log qw( cronlogaction );
use Koha::Script -cron;

sub usage {
    pod2usage( -exitval => 0, -verbose => 2 );
    exit;
}

my $help  = 0;
my $man   = 0;
my $force = 0;
my $dry_run;
my $verbose;

my $command_line_options = join( " ", @ARGV );

GetOptions(
    'h|?|help'   => \$help,
    'm|man'      => \$man,
    'f|force'    => \$force,
    'v|verbose+' => \$verbose,
    'n|dry-run'  => \$dry_run,
) or usage();
pod2usage(1) if $help;
usage() if $man;

my $rthq = C4::Context->preference('RealTimeHoldsQueue');

if ( $rthq && !$force ) {
    say "RealTimeHoldsQueue system preference is enabled, holds queue not built.";
    say "Use --force to force building the holds queue.";
    exit(1);
}

if ( $dry_run && $verbose ) {
    print "Dry run!\n";
} else {
    cronlogaction();
}

CreateQueue({
    verbose => $verbose,
    dry_run => $dry_run,
});

unless ( $dry_run ) {
    cronlogaction({ action => 'End', info => "COMPLETED" });
}

=head1 NAME

build_holds_queue.pl - builds a holds queue in the tmp_holdsqueue table

=head1 SYNOPSIS

  ./build_holds_queue.pl ...

=head1 DESCRIPTION

This script calls C4::Reserves::CancelExpiredReserves which will find and cancel all expired reseves in the system.

=cut

=head1 OPTIONS

=over 8

=item B<--help>

Print a brief help message and exits.

=item B<--man>

Prints the manual page and exits.

=item B<--force>

Allows this script to rebuild the entire holds queue even if the RealTimeHoldsQueue system preference is enabled.

=item B<--verbose|-v>

Be verbose

=item B<--dry-run|-n>

Don't change data (dry-run)

=back

=cut
