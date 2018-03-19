use C4::Context;
use Koha::AtomicUpdater;

my $dbh = C4::Context->dbh();
my $atomicUpdater = Koha::AtomicUpdater->new();

unless ($atomicUpdater->find('NLF-5')) {

    $dbh->do(q{
        ALTER TABLE holdings ADD COLUMN `deleted_on` DATETIME DEFAULT NULL
    });
    if ($dbh->errstr) {
	    die "Could not change holdings table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE holdings_metadata ADD COLUMN `deleted_on` DATETIME DEFAULT NULL
    });
    if ($dbh->errstr) {
	    die "Could not change holdings_metadata table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        DROP TABLE deletedholdings_metadata
    });
    if ($dbh->errstr) {
	    die "Could not remove deletedholdings_metadata table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        DROP TABLE deletedholdings
    });
    if ($dbh->errstr) {
	    die "Could not remove deletedholdings table: " . $dbh->errstr . "\n";
	}

    print "Upgrade done (NLF-5: Eliminate deletedholdings and deletedholdings_metadata)\n";
}