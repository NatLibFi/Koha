$DBversion = 'XXX';  # will be replaced by the RM
if( CheckVersion($DBversion) ) {

    # since: $DBversion = '19.12.00.018';
    # issuingrules table replaced by circulation_rules table

    if( ! column_exists( 'circulation_rules', 'ccode' ) ) {
        $dbh->do(
            "ALTER TABLE circulation_rules
            ADD COLUMN ccode varchar(10) DEFAULT NULL AFTER itemtype"
        );
    }

    if( ! column_exists( 'circulation_rules', 'shelving_location' ) ) {
        $dbh->do(
            "ALTER TABLE circulation_rules
            ADD COLUMN `shelving_location` varchar(80) DEFAULT NULL AFTER `ccode`"
        );
    }

    $dbh->do(
        "ALTER TABLE circulation_rules
            DROP INDEX IF EXISTS branchcode,
            ADD UNIQUE KEY (`branchcode`,`categorycode`,`itemtype`,`ccode`,`shelving_location`,`rule_name`)"
    );

    # Always end with this (adjust the bug info)
    NewVersion( $DBversion, 17593, "Adding ccode and shelving_location circulation rules" );
}
