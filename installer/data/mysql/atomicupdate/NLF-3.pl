use C4::Context;
use Koha::AtomicUpdater;

my $dbh = C4::Context->dbh();
my $atomicUpdater = Koha::AtomicUpdater->new();

unless ($atomicUpdater->find('NLF-3')) {

    $dbh->do(q{
        INSERT IGNORE INTO auth_types (authtypecode, authtypetext, auth_tag_to_report, summary) VALUES
		    ('MED_PERFOR', 'Medium of Performance', '162', 'Medium of Performance')
    });
    if ($dbh->errstr) {
	    die "Could not insert row to auth_types table: " . $dbh->errstr . "\n";
	}

    print "Upgrade done (NLF-3: Add Medium of Performance to auth_types)\n";
}