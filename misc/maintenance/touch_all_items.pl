#!/usr/bin/perl

# Copyright (C) 2011 ByWater Solutions
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
use Getopt::Long qw( GetOptions :config no_ignore_case bundling);
use Pod::Usage qw( pod2usage );
use Time::HiRes;

use Koha::Script;
use C4::Context;
use C4::Log qw( cronlogaction );
use Koha::Items;

sub usage {
    pod2usage( -verbose => 2 );
    exit;
}

# Database handle
my $dbh = C4::Context->dbh;

# Benchmarking variables
my $startime;
my $goodcount  = 0;
my $badcount   = 0;
my $totalcount = 0;

# Options
my $help = 0;
my $dry_run;
my $verbose;
my $whereclause = '';
my $outfile;

GetOptions(
    'h|?|help'   => \$help,
    'v|verbose+' => \$verbose,
    'n|dry-run'  => \$dry_run,
    'o|output:s' => \$outfile,
    'where:s'    => \$whereclause,
) or usage();
usage() if $help;

if ( $dry_run && $verbose ) {
    print "Dry run!\n";
} else {
    cronlogaction();
}

if ($whereclause) {
    $whereclause = "WHERE $whereclause";
}

# output log or STDOUT
my $fh;
if ( defined $outfile ) {
    open( $fh, '>', $outfile ) || die("Cannot open output file");
} else {
    open( $fh, '>&', \*STDOUT ) || die("Couldn't duplicate STDOUT: $!");
}

# Let's estimate how big the task is:
my $sth_ctr = $dbh->prepare("SELECT COUNT(*) AS total FROM items $whereclause");
$sth_ctr->execute();
my $res                = $sth_ctr->fetchrow_hashref;
my $records_to_process = $res->{'total'};
print $fh "$records_to_process records will be processed ...\n" if $verbose;

# FIXME Would be better to call Koha::Items->search here
my $sth_fetch = $dbh->prepare("SELECT biblionumber, itemnumber, itemcallnumber FROM items $whereclause");
$sth_fetch->execute();

$startime = Time::HiRes::time();
my $time_step_mark = $startime;
my $notification_step = $verbose > 3 ? 10 : $verbose > 2 ? 100 : 1000;

# fetch info from the search
while ( my ( $biblionumber, $itemnumber, $itemcallnumber ) = $sth_fetch->fetchrow_array ) {

    my $item = Koha::Items->find($itemnumber);
    next unless $item;

    if ( $dry_run ) {
        print $fh "Would have touched item $itemnumber\n" if $verbose && $verbose > 4;
    } else {

        for my $c (qw( itemcallnumber cn_source )) {
            $item->make_column_dirty($c);
        }

        eval { $item->store };
        my $modok = $@ ? 0 : 1;

        if ($modok) {
            $goodcount++;
            print $fh "Touched item $itemnumber\n" if $verbose && $verbose > 2;
        } else {
            $badcount++;
            print $fh "ERROR WITH ITEM $itemnumber !!!!\n";
        }
    }

    if ( $verbose && $totalcount && !( $totalcount % $notification_step ) ) {
        my $total_timedelta = Time::HiRes::time() - $startime;
        my $step_timedelta  = Time::HiRes::time() - $time_step_mark;
        my $recs_left       = $records_to_process - $totalcount;
        if ( $verbose > 1 ) {
            printf $fh "Processed: %d. Rps speed, per %d: %.3f, all: %.3f rps. %d recs left: %.2f hours.\n",
              $totalcount,
              $notification_step,
              $step_timedelta / $notification_step,
              $total_timedelta / $totalcount,
              $recs_left,
              $recs_left * $total_timedelta / $totalcount / 3600;
        } else {
            printf $fh "Processed: %d. Time left: %.2f hours.\n", $totalcount, $recs_left * $total_timedelta / $totalcount / 3600;
        }
        $time_step_mark = Time::HiRes::time();
    }

    $totalcount++;

}
close($fh);

# Benchmarking
my $endtime     = Time::HiRes::time();
my $time        = int( $endtime - $startime );
my $accuracy    = $totalcount ? ( $goodcount / $totalcount ) * 100 : 0; # this is a percentage
my $averagetime = 0;
$averagetime    = $time / $totalcount if $totalcount;
print "Good: $goodcount, Bad: $badcount (of $totalcount) in $time seconds\n";
printf "Accuracy: %.2f%%\nAverage time per record: %.6f seconds\n", $accuracy, $averagetime if $verbose;

=head1 NAME

touch_all_items.pl

=head1 SYNOPSIS

  touch_all_items.pl
  touch_all_items.pl -v
  touch_all_items.pl --where=STRING

=head1 DESCRIPTION

When changes are made to ModItem (or the routines that are called by it), it is
sometimes necessary to run ModItem on all or some records in the catalog when
upgrading. This script does that.

=over 8

=item B<--help>

Prints this help

=item B<-v>

Provide verbose log information.

=item B<--where>

Limits the search with a user-specified WHERE clause.

=back

=cut

