use C4::Context;
use Koha::AtomicUpdater;

my $dbh = C4::Context->dbh();
my $atomicUpdater = Koha::AtomicUpdater->new();

unless ($atomicUpdater->find('NLF-4')) {

    $dbh->do(q{
        ALTER TABLE deletedholdings CHANGE COLUMN holdingnumber holding_id int(11) NOT NULL auto_increment
    });
    if ($dbh->errstr) {
	    die "Could not change deletedholdings table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE deletedholdings_metadata CHANGE COLUMN holdingnumber holding_id int(11)
    });
    if ($dbh->errstr) {
	    die "Could not change deletedholdings_metadata table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE deleteditems CHANGE COLUMN holdingnumber holding_id int(11)
    });
    if ($dbh->errstr) {
	    die "Could not change deleteditems table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE holdings CHANGE COLUMN holdingnumber holding_id int(11) NOT NULL auto_increment
    });
    if ($dbh->errstr) {
	    die "Could not change holdings table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE holdings_metadata CHANGE COLUMN holdingnumber holding_id int(11)
    });
    if ($dbh->errstr) {
	    die "Could not change holdings_metadata table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE items CHANGE COLUMN holdingnumber holding_id int(11)
    });
    if ($dbh->errstr) {
	    die "Could not change items table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE items ADD KEY `hldid_idx` (`holding_id`)
    });
    if ($dbh->errstr) {
	    die "Could not add holding_id key to items table: " . $dbh->errstr . "\n";
	}

    print "Upgrade done (NLF-4: Rename holdingnumber to holding_id)\n";
}