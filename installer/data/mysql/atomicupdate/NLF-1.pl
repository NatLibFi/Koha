use C4::Context;
use Koha::AtomicUpdater;

my $dbh = C4::Context->dbh();
my $atomicUpdater = Koha::AtomicUpdater->new();

unless ($atomicUpdater->find('NLF-1')) {

    $dbh->do(q{
        ALTER TABLE search_field CHANGE COLUMN type type ENUM('', 'string', 'date', 'number', 'boolean', 'sum', 'isbn', 'stdno') NOT NULL COMMENT 'what type of data this holds, relevant when storing it in the search engine'
    });

$dbh->do("INSERT INTO atomicupdates (issue_id, filename) VALUES ('Bug14698', 'Bug14698-AtomicUpdater.pl')");

    print "Upgrade done (NLF-1: update search_field table enum)\n";
}