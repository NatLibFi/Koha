#!/usr/bin/perl
use Modern::Perl;

# Standard or CPAN modules used
use Getopt::Long qw( GetOptions );
use File::Slurp  qw( read_file );
use XML::LibXML;

# Koha modules used
use Koha::Biblios;

my $filePath;

GetOptions( 'f=s' => \$filePath );

if ( !$filePath ) {
    die "Usage: $0 -f [file_name]";
}

say "Trying to open a file: $filePath";

open( my $fileHandle, '<', $filePath ) or die "Can't open file $filePath: $!\n";

say "Working with got file";

my @biblionumber = read_file($fileHandle);

foreach my $num (@biblionumber) {
    chomp($num);
    xml_cleaner($num);
}

sub xml_cleaner {
    my $biblionumber = shift;
    say 'Take the: ', $biblionumber;
    my $biblio = Koha::Biblios->find($biblionumber);
    my $record = $biblio->metadata->record->as_xml();

    # Load the XML
    my $parser = XML::LibXML->new();
    my $doc    = $parser->load_xml( string => $record );

    my @required_elements = (
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
        '//*[@tag="850"]',               '//*[@tag="880"]',               '//*[@tag="990"]'
    );

    # Remove the datafield elements from the document
    foreach my $element (@required_elements) {
        my @datafields = $doc->findnodes($element);
        foreach my $datafield (@datafields) {
            $datafield->unbindNode();
        }
    }

    # Create a new element for field 520
    my $new_field = XML::LibXML::Element->new("datafield");
    $new_field->setAttribute( 'tag',  '520' );
    $new_field->setAttribute( 'ind1', ' ' );
    $new_field->setAttribute( 'ind2', ' ' );

    # Create a new subfield with a default notice for all collections
    my $new_subfield = XML::LibXML::Element->new("subfield");
    $new_subfield->setAttribute( 'code', 'a' );
    $new_subfield->appendText("Yhteensidottu nide sisältää useita julkaisuja : Samlingsbandet innehåller flera publikationer : Bound volume contains multiple items.");
    $new_field->appendChild($new_subfield);

    #Add new field 520 after field 999
    my $target_field = $doc->findnodes('//*[@tag="999"]')->[0];
    $target_field->parentNode->insertBefore( $new_field, $target_field );

    #Remove blank lines after deleted datafields
    my $content = $doc->toString();
    $content =~ s/^\s*\n//mg;

    #Update and save date in Metadata
    $biblio->metadata->metadata($content);
    $biblio->update;
    say $biblionumber, ' is updated.';
}

say 'DONE !!!'

