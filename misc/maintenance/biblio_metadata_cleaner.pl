#!/usr/bin/perl

use Modern::Perl;
use utf8;

use Getopt::Long qw( GetOptions :config no_ignore_case bundling);
use Pod::Usage qw( pod2usage );
use Time::HiRes;
use File::Slurp  qw( read_file write_file );
use XML::LibXML;
use Koha::Script;
use C4::Context;
use C4::Biblio qw( ModBiblio );
use C4::Log qw( cronlogaction );
use Koha::Biblios;
use MARC::Field;

sub usage {
    pod2usage( -verbose => 2 );
    exit;
}

# STARTING DATA:
my $xmlpaths_elements_to_remove = [
    '//*[@tag="010"]',               '//*[@tag="015"]',               '//*[@tag="019"]',               '//*[@tag="020"]',
    '//*[@tag="022"]',               '//*[@tag="031"]',               '//*[@tag="035"]',               '//*[@tag="041"]',
    '//*[@tag="050"]',               '//*[@tag="060"]',               '//*[@tag="066"]',               '//*[@tag="072"]',
    '//*[@tag="080"]',               '//*[@tag="082"]',               '//*[@tag="100"]',               '//*[@tag="110"]',
    '//*[@tag="111"]',               '//*[@tag="130"]',               '//*[@tag="240"]',               '//*[@tag="245"]//*[@code="6"]',
    '//*[@tag="245"]//*[@code="n"]', '//*[@tag="245"]//*[@code="p"]', '//*[@tag="245"]//*[@code="c"]', '//*[@tag="246"]',
    '//*[@tag="250"]',               '//*[@tag="260"]',               '//*[@tag="264"]',               '//*[@tag="300"]',
    '//*[@tag="310"]',               '//*[@tag="362"]',               '//*[@tag="490"]',               '//*[@tag="500"]',
    '//*[@tag="501"]',               '//*[@tag="502"]',               '//*[@tag="504"]',               '//*[@tag="505"]',
    '//*[@tag="506"]',               '//*[@tag="510"]',               '//*[@tag="520"]',               '//*[@tag="530"]',
    '//*[@tag="534"]',               '//*[@tag="546"]',               '//*[@tag="561"]',               '//*[@tag="562"]',
    '//*[@tag="563"]',               '//*[@tag="588"]',               '//*[@tag="593"]',               '//*[@tag="594"]',
    '//*[@tag="597"]',               '//*[@tag="599"]',               '//*[@tag="600"]',               '//*[@tag="610"]',
    '//*[@tag="630"]',               '//*[@tag="648"]',               '//*[@tag="650"]',               '//*[@tag="651"]',
    '//*[@tag="653"]',               '//*[@tag="655"]',               '//*[@tag="700"]',               '//*[@tag="710"]',
    '//*[@tag="711"]',               '//*[@tag="720"]',               '//*[@tag="730"]',               '//*[@tag="740"]',
    '//*[@tag="752"]',               '//*[@tag="765"]',               '//*[@tag="767"]',               '//*[@tag="770"]',
    '//*[@tag="772"]',               '//*[@tag="775"]',               '//*[@tag="776"]',               '//*[@tag="780"]',
    '//*[@tag="785"]',               '//*[@tag="800"]',               '//*[@tag="810"]',               '//*[@tag="830"]',
    '//*[@tag="850"]',               '//*[@tag="856"]',               '//*[@tag="880"]',               '//*[@tag="990"]'
];

# STARTING DATA:
my $tags_to_be_deleted = [
         { t => '010' },           { t => '015' },           { t => '019' },           { t => '020' },
         { t => '022' },           { t => '031' },           { t => '035' },           { t => '041' },
         { t => '050' },           { t => '060' },           { t => '066' },           { t => '072' },
         { t => '080' },           { t => '082' },           { t => '100' },           { t => '110' },
         { t => '111' },           { t => '130' },           { t => '240' },           { t => '245', s => '6' },
         { t => '245', s => 'n' }, { t => '245', s => 'p' }, { t => '245', s => 'c' }, { t => '246' },
         { t => '250' },           { t => '260' },           { t => '264' },           { t => '300' },
         { t => '310' },           { t => '362' },           { t => '490' },           { t => '500' },
         { t => '501' },           { t => '502' },           { t => '504' },           { t => '505' },
         { t => '506' },           { t => '510' },           { t => '520' },           { t => '530' },
         { t => '534' },           { t => '546' },           { t => '561' },           { t => '562' },
         { t => '563' },           { t => '588' },           { t => '593' },           { t => '594' },
         { t => '597' },           { t => '599' },           { t => '600' },           { t => '610' },
         { t => '630' },           { t => '648' },           { t => '650' },           { t => '651' },
         { t => '653' },           { t => '655' },           { t => '700' },           { t => '710' },
         { t => '711' },           { t => '720' },           { t => '730' },           { t => '740' },
         { t => '752' },           { t => '765' },           { t => '767' },           { t => '770' },
         { t => '772' },           { t => '775' },           { t => '776' },           { t => '780' },
         { t => '785' },           { t => '800' },           { t => '810' },           { t => '830' },
         { t => '850' },           { t => '856' },           { t => '880' },           { t => '990' }
];

sub record_changer {
    my $record = shift;

    # use Data::Dumper (); warn Data::Dumper->new( [{
    #     field => \[map $field],
    # }],[ __PACKAGE__ . ":" . __LINE__ ])->Sortkeys(sub{return [sort { lc $a cmp lc $b } keys %{ $_[0] }];})
    #     ->Maxdepth(2)->Indent(1)->Purity(0)->Deepcopy(1)->Dump. "\n";

    foreach(@$tags_to_be_deleted) {
        my $tag = $_->{t};
        my $subfield = $_->{s};

        foreach my $field ($record->field($tag)) {
            if ($subfield) {
                if ($field->subfield($subfield)) {
                    $field->delete_subfield(code => $subfield);
                    warn "Field " . $field->tag() ." subfield $subfield DELETED.\n" if $ENV{DEBUG};
                }
            } else {
                $record->delete_field($field);
                warn "Field " . $field->tag() ." DELETED.\n" if $ENV{DEBUG};
            }
        }
    }

    # add needed fields:
    my $field = MARC::Field->new('520',' ',' ',
        'a' => 'Yhteensidottu nide sisältää useita julkaisuja : Samlingsbandet innehåller flera publikationer : Bound volume contains multiple items.');
    $record->insert_fields_before( $record->field('999'), $field );

    return $record;

    # my $xml_doc_modified = shift;

    # # Remove the datafield elements from the document
    # foreach my $element (@$xmlpaths_elements_to_remove) {
    #     my @datafields = $xml_doc->findnodes($element);
    #     foreach my $datafield (@datafields) {
    #         $datafield->unbindNode();
    #     }
    # }

    # # Create a new element for field 520
    # my $new_field = XML::LibXML::Element->new("datafield");
    # $new_field->setAttribute( 'tag',  '520' );
    # $new_field->setAttribute( 'ind1', ' ' );
    # $new_field->setAttribute( 'ind2', ' ' );

    # # Create a new subfield with a default notice for all collections
    # my $new_subfield = XML::LibXML::Element->new("subfield");
    # $new_subfield->setAttribute( 'code', 'a' );
    # $new_subfield->appendText("Yhteensidottu nide sisältää useita julkaisuja : Samlingsbandet innehåller flera publikationer : Bound volume contains multiple items.");
    # $new_field->appendChild($new_subfield);

    # #Add new field 520 after field 999
    # my $target_field = $xml_doc_modified->findnodes('//*[@tag="999"]')->[0];
    # $target_field->parentNode->insertBefore( $new_field, $target_field );

    # return;
}


# Database handle
my $dbh = C4::Context->dbh;

# Benchmarking variables
my $startime;
my $goodcount  = 0;
my $badcount   = 0;
my $totalcount = 0;

# Options
my $biblist_file;
my $help = 0;
my $dry_run;
my $verbose;
my $whereclause = '';
my $outfile;
my $touch_records;
my $records_backup_path;

GetOptions(
    'h|?|help'   => \$help,
    'v|verbose+' => \$verbose,
    'n|dry-run'  => \$dry_run,
    'o|output:s' => \$outfile,
    'w|where:s'  => \$whereclause,
    'f|file=s'   => \$biblist_file,
    't|touch'    => \$touch_records,
    'b|backup:s' => \$records_backup_path,
) or usage();
usage() if $help;

if ( $dry_run && $verbose ) {
    print "Dry run!\n";
} else {
    cronlogaction();
}

if ($records_backup_path && ! -d $records_backup_path) {
    die "Backup path '$records_backup_path' does not exist";
}

if ($whereclause && $biblist_file) {
    die "Can't use both where clause and file";
}

# output log or STDOUT
my $out_fh;
if ( defined $outfile ) {
    open( $out_fh, '>', $outfile ) || die("Cannot open output file");
} else {
    open( $out_fh, '>&', \*STDOUT ) || die("Couldn't duplicate STDOUT: $!");
}

if ($whereclause) {
    $whereclause = "WHERE $whereclause";
} elsif ($biblist_file) {
    my @biblist = read_file($biblist_file);
    for (my $i = 0; $i < @biblist; $i++) {
        chomp $biblist[$i];
        if ( $biblist[$i] !~ /^\d+$/) {
            print $out_fh "Warning: ignoring non-integer in biblionumber list: '$biblist[$i]'.\n";
            splice @biblist, $i, 1;
            $i--;
        }
    }
    $whereclause = "WHERE biblionumber IN (" . join( ',', @biblist ) . ")";
}

# Let's estimate how big the task is:
my $sth_ctr = $dbh->prepare("SELECT COUNT(1) AS total FROM biblio $whereclause");
$sth_ctr->execute();
my $res                = $sth_ctr->fetchrow_hashref;
my $records_to_process = $res->{'total'};
print $out_fh "$records_to_process records will be processed ...\n" if $verbose;

my $sth_fetch = $dbh->prepare("SELECT biblionumber, frameworkcode FROM biblio $whereclause");
$sth_fetch->execute();

$startime = Time::HiRes::time();
my $time_step_mark = $startime;
my $notification_step = $verbose > 2 ? 10 : $verbose > 1 ? 100 : 1000;

my $timestamp = POSIX::strftime("%Y%m%d%H%M%S", localtime);

while ( my ( $biblionumber, $frameworkcode ) = $sth_fetch->fetchrow_array ) {
    my $biblio = Koha::Biblios->find($biblionumber);
    my $record = $biblio->metadata->record;

    my $str_record_in = $record->as_xml();
    my $parser  = XML::LibXML->new();
    my $xml_doc = $parser->load_xml( string => $str_record_in );
    my $nodes_in_ctr = $xml_doc->findnodes('//*')->size();
    my $lines_in_ctr = scalar split /\n/, $str_record_in;
    if($records_backup_path) {
        my $backup_file = "$records_backup_path/$timestamp-$biblionumber-in.xml";
        write_file($backup_file, $str_record_in);
    }

    $record = record_changer($record->clone());

    my $str_record_out = $xml_doc->toString();
    $str_record_out =~ s/^\s*\n//mg;
    my $nodes_out_ctr = $xml_doc->findnodes('//*')->size();
    my $lines_out_ctr = scalar split /\n/, $str_record_out;


    if($records_backup_path) {
        my $backup_file = "$records_backup_path/$timestamp-$biblionumber-out.xml";
        write_file($backup_file, $str_record_out);
    }

    print $out_fh "Record $biblionumber processed: $lines_in_ctr -> $lines_out_ctr lines, $nodes_in_ctr -> $nodes_out_ctr nodes.\n"
        if $verbose && $verbose > 3;

    if ( $dry_run ) {
        print $out_fh "Dry-run: expected to update biblio $biblionumber\n" if $verbose && $verbose > 3;
    } else {
        if (ModBiblio( $record, $biblionumber, $frameworkcode )) {
            $goodcount++;
            print $out_fh "Modified biblio $biblionumber\n" if $verbose && $verbose > 3;
        } else {
            $badcount++;
            print $out_fh "ERROR WITH BIBLIO $biblionumber !!!!\n";
        }

        if( $touch_records ) {
            $dbh->do( q|UPDATE biblio SET timestamp=NOW() WHERE biblionumber=?|,
                undef, $biblionumber );
            print $out_fh "Touched biblio $biblionumber\n" if $verbose && $verbose > 4;
        }
    }

    if ( $verbose && $totalcount && !( $totalcount % $notification_step ) ) {
        my $total_timedelta = Time::HiRes::time() - $startime;
        my $step_timedelta  = Time::HiRes::time() - $time_step_mark;
        my $recs_left       = $records_to_process - $totalcount;
        if ( $verbose > 1 ) {
            printf $out_fh "Processed: %d. Rps speed, per %d: %.3f, all: %.3f rps. %d recs left: %.2f hours.\n",
              $totalcount,
              $notification_step,
              $step_timedelta / $notification_step,
              $total_timedelta / $totalcount,
              $recs_left,
              $recs_left * $total_timedelta / $totalcount / 3600;
        } else {
            printf $out_fh "Processed: %d. Time left: %.2f hours.\n", $totalcount, $recs_left * $total_timedelta / $totalcount / 3600;
        }
        $time_step_mark = Time::HiRes::time();
    }

    $totalcount++;

}
close($out_fh);

# Benchmarking
my $endtime     = Time::HiRes::time();
my $time        = int( $endtime - $startime );
my $accuracy    = $totalcount ? ( $goodcount / $totalcount ) * 100 : 0; # this is a percentage
my $averagetime = 0;
$averagetime    = $time / $totalcount if $totalcount;
print "Good: $goodcount, Bad: $badcount (of $totalcount) in $time seconds\n";
printf "Accuracy: %.2f%%\nAverage time per record: %.6f seconds\n", $accuracy, $averagetime if $verbose;

#########
# SUBS:
#########

sub xml_updater {
    my $biblionumber = shift;
    my $xmlpaths_elements_to_remove = shift;
    my $out_fh       = shift;
    my $params       = shift;
    my $custom_callback = shift;

    # print $out_fh 'Take the: ', $biblionumber, "\n" if $verbose;

    my $biblio = Koha::Biblios->find($biblionumber);
    if ( ! $biblio ) {
        print $out_fh "Not found biblio [$biblionumber]. Skipped.\n";
        return;
    }




    # Load the XML
    my $record = $biblio->metadata->record;
    my $str_record = $record->as_xml();
    my $parser  = XML::LibXML->new();
    my $xml_doc = $parser->load_xml( string => $str_record );
    my $nodes_in_ctr = $xml_doc->findnodes('//*')->size();
    my $lines_in_ctr = scalar split /\n/, $record;

    # Remove the datafield elements from the document
    foreach my $element (@$xmlpaths_elements_to_remove) {
        my @datafields = $xml_doc->findnodes($element);
        foreach my $datafield (@datafields) {
            $datafield->unbindNode();
        }
    }

    # TODO: not cloned so modifications done in-place, but better to make clone later
    $custom_callback->($xml_doc);

    my $nodes_out_ctr = $xml_doc->findnodes('//*')->size();

    # # get list of node names:
    # foreach my $node ( $xml_doc->findnodes('//*') ) {
    #     print $out_fh " - ", $node->nodeName, ": [", $node->nodePath, "] [", $node->parentNode->nodeName, "] [", $node->parentNode->nodePath, "]\n";
    # }


    #Remove blank lines after deleted datafields
    my $content = $xml_doc->toString();
    $content =~ s/^\s*\n//mg;
    my $lines_out_ctr = scalar split /\n/, $content;

    if( ! $params->{dry_run} ) {
        #Update and save date in Metadata
        $biblio->metadata->metadata($content);
        $biblio->update;
    } else {
        print $out_fh "Record $biblionumber processed: $lines_in_ctr -> $lines_out_ctr lines, $nodes_in_ctr -> $nodes_out_ctr nodes.\n";
        print $out_fh "FULL CONTENT DUMP:\n$content\n\n" if $params->{verbose} && $params->{verbose} > 4;
    }
    # print $out_fh "$biblionumber, is updated." if $verbose;

    return 1;
}
