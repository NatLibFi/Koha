use C4::Context;
use Koha::AtomicUpdater;

my $dbh = C4::Context->dbh();
my $atomicUpdater = Koha::AtomicUpdater->new();

unless ($atomicUpdater->find('NLF-2')) {
    $dbh->do(q{
        CREATE TABLE `holdings` ( -- table that stores summary holdings information
        `holdingnumber` int(11) NOT NULL auto_increment, -- unique identifier assigned to each holding record
        `biblionumber` int(11) NOT NULL default 0, -- foreign key from biblio table used to link this record to the right bib record
        `biblioitemnumber` int(11) NOT NULL default 0, -- foreign key from the biblioitems table to link record to additional information
        `frameworkcode` varchar(4) NOT NULL default '', -- foreign key from the biblio_framework table to identify which framework was used in cataloging this record
        `holdingbranch` varchar(10) default NULL, -- foreign key from the branches table for the library that owns this holding (MARC21 852$a)
        `location` varchar(80) default NULL, -- authorized value for the shelving location for this item (MARC21 852$b)
        `callnumber` varchar(255) default NULL, -- call number (852$h+$i in MARC21)
        `suppress` tinyint(1) default NULL, -- Boolean indicating whether the holding is suppressed in OPAC
        `timestamp` timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP, -- date and time this record was last touched
        `datecreated` DATE NOT NULL, -- the date this record was added to Koha
        PRIMARY KEY  (`holdingnumber`),
        KEY `hldnoidx` (`holdingnumber`),
        KEY `hldbinoidx` (`biblioitemnumber`),
        KEY `hldbibnoidx` (`biblionumber`),
        CONSTRAINT `holdings_ibfk_1` FOREIGN KEY (`biblionumber`) REFERENCES `biblio` (`biblionumber`) ON DELETE CASCADE ON UPDATE CASCADE,
        CONSTRAINT `holdings_ibfk_2` FOREIGN KEY (`biblioitemnumber`) REFERENCES `biblioitems` (`biblioitemnumber`) ON DELETE CASCADE ON UPDATE CASCADE,
        CONSTRAINT `holdings_ibfk_3` FOREIGN KEY (`holdingbranch`) REFERENCES `branches` (`branchcode`) ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci
    });
    if ($dbh->errstr) {
	    die "Could not add holdings table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        CREATE TABLE holdings_metadata (
        `id` INT(11) NOT NULL AUTO_INCREMENT,
        `holdingnumber` INT(11) NOT NULL,
        `format` VARCHAR(16) NOT NULL,
        `marcflavour` VARCHAR(16) NOT NULL,
        `metadata` LONGTEXT NOT NULL,
        PRIMARY KEY(id),
        UNIQUE KEY `holdings_metadata_uniq_key` (`holdingnumber`,`format`,`marcflavour`),
        KEY `hldnoidx` (`holdingnumber`),
        CONSTRAINT `holdings_metadata_fk_1` FOREIGN KEY (holdingnumber) REFERENCES holdings (holdingnumber) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci
    });
    if ($dbh->errstr) {
	    die "Could not add holdings_metadata table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        CREATE TABLE `deletedholdings` ( -- table that stores summary holdings information
        `holdingnumber` int(11) NOT NULL auto_increment, -- unique identifier assigned to each holding record
        `biblionumber` int(11) NOT NULL default 0, -- foreign key from biblio table used to link this record to the right bib record
        `biblioitemnumber` int(11) NOT NULL default 0, -- foreign key from the biblioitems table to link record to additional information
        `frameworkcode` varchar(4) NOT NULL default '', -- foreign key from the biblio_framework table to identify which framework was used in cataloging this record
        `holdingbranch` varchar(10) default NULL, -- foreign key from the branches table for the library that owns this holding (MARC21 852$a)
        `location` varchar(80) default NULL, -- authorized value for the shelving location for this item (MARC21 852$c)
        `callnumber` varchar(255) default NULL, -- call number (852$h+$i in MARC21)
        `suppress` tinyint(1) default NULL, -- Boolean indicating whether the holding is suppressed from patrons
        `timestamp` timestamp NOT NULL default CURRENT_TIMESTAMP on update CURRENT_TIMESTAMP, -- date and time this record was last touched
        `datecreated` DATE NOT NULL, -- the date this record was added to Koha
        PRIMARY KEY  (`holdingnumber`),
        KEY `hldnoidx` (`holdingnumber`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci
    });
    if ($dbh->errstr) {
	    die "Could not add deletedholdings table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        CREATE TABLE deletedholdings_metadata (
            `id` INT(11) NOT NULL AUTO_INCREMENT,
            `holdingnumber` INT(11) NOT NULL,
            `format` VARCHAR(16) NOT NULL,
            `marcflavour` VARCHAR(16) NOT NULL,
            `metadata` LONGTEXT NOT NULL,
            PRIMARY KEY(id)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci
    });
    if ($dbh->errstr) {
	    die "Could not add deletedholdings_metadata table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE `items` ADD COLUMN `holdingnumber` int(11) default NULL
    });
    if ($dbh->errstr) {
	    die "Could not add holdingnumber column to items table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE `items` ADD CONSTRAINT `items_ibfk_5` FOREIGN KEY (`holdingnumber`) REFERENCES `holdings` (`holdingnumber`) ON DELETE CASCADE ON UPDATE CASCADE
    });
    if ($dbh->errstr) {
	    die "Could not add holdingnumber constraint to items table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        ALTER TABLE `deleteditems` ADD COLUMN `holdingnumber` int(11) default NULL
    });
    if ($dbh->errstr) {
	    die "Could not add holdingnumber column to items table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        INSERT INTO authorised_value_categories( category_name )
        VALUES ('holdings')
    });
    if ($dbh->errstr) {
	    die "Could not add 'holdings' to authorised_value_categories table: " . $dbh->errstr . "\n";
	}

    $dbh->do(q{
        INSERT INTO `marc_subfield_structure` (`tagfield`, `tagsubfield`, `liblibrarian`, `libopac`, `repeatable`, `mandatory`, `kohafield`, `tab`, `authorised_value`, `authtypecode`, `value_builder`, `isurl`, `hidden`, `frameworkcode`, `seealso`, `link`, `defaultvalue`) VALUES
        ('952', 'V', 'Holding record',  'Holding record',  0, 0, 'items.holdingnumber', 10, 'holdings', '', '', NULL, 0,  '', '', '', NULL)
    });
    if ($dbh->errstr) {
	    die "Could not add items.holdingnumber to marc_subfield_structure table: " . $dbh->errstr . "\n";
	}

    print "Upgrade done (NLF-2: add holdings)\n";
}