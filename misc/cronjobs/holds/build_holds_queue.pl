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

BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin ();
    eval { require "$FindBin::Bin/../kohalib.pl" };
}

use Koha::Script -cron;
use C4::HoldsQueue;
use C4::Log qw( cronlogaction );

sub usage {
    pod2usage( -verbose => 2 );
    exit;
}

my $help = 0;
my $dry_run;
my $verbose;

GetOptions(
    'h|?|help'   => \$help,
    'v|verbose+' => \$verbose,
    'n|dry-run'  => \$dry_run,
) or usage();
usage() if $help;

if ( $dry_run && $verbose ) {
    print "Dry run!\n";
} else {
    cronlogaction();
}

C4::HoldsQueue::CreateQueue({
    verbose => $verbose,
    dry_run => $dry_run,
});

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

=item B<--verbose|-v>

Be verbose

=item B<--dry-run|-n>

Don't change data (dry-run)

=back

=cut
