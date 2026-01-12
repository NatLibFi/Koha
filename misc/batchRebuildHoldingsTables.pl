#!/usr/bin/perl
# Small script that rebuilds the non-MARC Holdings DB

use strict;
use warnings;

BEGIN {
    # find Koha's Perl modules
    # test carefully before changing this
    use FindBin;
    eval { require "$FindBin::Bin/kohalib.pl" };
}

# Koha modules used
use Koha::Holdings;

use Getopt::Long;

my ($input_marc_file, $number) = ('', 0);
my ($help, $confirm);
GetOptions(
    'c' => \$confirm,
    'h' => \$help,
);

if ($help || !$confirm) {
    print <<EOF
This script rebuilds the non-MARC Holdings DB from the MARC values.
You can/must use it when you change the mappings.

Example: you decide to map holdings.callnumber to 852\$k\$l\$m (it was previously mapped to 852\$k).

Syntax:
\t./batchRebuildHoldingsTables.pl -h (or without arguments => shows this screen)
\t./batchRebuildHoldingsTables.pl -c (c like confirm => rebuild non-MARC DB (may take long)
EOF
;
    exit;
}

my $starttime = time();

$| = 1; # flushes output

my $count = 0;
my $page = 0;
my $rows = 1000;
while (1) {
    ++$page;
    my $holdings = Koha::Holdings->search({}, {page => $page, rows => $rows});
    my $i = 0;
    while (my $holding = $holdings->next()) {
        my $metadata = $holding->metadata();
        next unless $metadata;
        $holding->set_marc({ record => $metadata->record() });
        $holding->store();
        ++$i;
    }
    last unless $i;
    $count += $i;
    my $timeneeded = time() - $starttime;
    print "$count records processed in $timeneeded seconds\n";
}
my $timeneeded = time() - $starttime;
print "Completed with $count records processed in $timeneeded seconds\n";
