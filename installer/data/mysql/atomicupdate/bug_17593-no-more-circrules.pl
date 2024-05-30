use Modern::Perl;

return {
    bug_number => "17593",
    description => "REMOVE ccode and shelving_location circulation rules columns",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        $dbh->do(
            "ALTER TABLE circulation_rules
                DROP INDEX `branchcode`,
                ADD UNIQUE KEY `branchcode` (`branchcode`, `categorycode`, `itemtype`, `rule_name`)"
        );

        if( column_exists( 'circulation_rules', 'ccode' ) ) {
            $dbh->do("ALTER TABLE circulation_rules DROP COLUMN ccode");
        }

        if( column_exists( 'circulation_rules', 'shelving_location' ) ) {
            $dbh->do("ALTER TABLE circulation_rules DROP COLUMN shelving_location");
        }

    },
};
