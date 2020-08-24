use Modern::Perl;

return {
    bug_number => "17593",
    description => "Adding ccode and shelving_location circulation rules",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        # issuingrules table replaced by circulation_rules table
        # since: $DBversion = '19.12.00.018';
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
    },
};
