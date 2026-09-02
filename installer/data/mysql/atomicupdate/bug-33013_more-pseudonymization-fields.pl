use Modern::Perl;

return {
    bug_number  => "33013",
    description => "Update systemprefs Pseudonymization: add age and interface",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        my $res;

        $res = $dbh->do(
            q{UPDATE systempreferences SET options=REPLACE(options, ',sex,', ',sex,age,')
            WHERE variable='PseudonymizationPatronFields' AND options NOT LIKE '%,age,%'}
        );

        $res = $dbh->do(
            q{UPDATE systempreferences SET options=REPLACE(options, ',transaction_type,', ',transaction_type,interface,')
            WHERE variable='PseudonymizationTransactionFields' AND options NOT LIKE '%,interface,%'}
        );

        unless ( column_exists( 'pseudonymized_transactions', 'age' ) ) {
            $dbh->do("ALTER TABLE pseudonymized_transactions ADD COLUMN age TINYINT DEFAULT NULL AFTER sex");
        }

        unless ( column_exists( 'pseudonymized_transactions', 'interface' ) ) {
            $dbh->do(
                "ALTER TABLE pseudonymized_transactions ADD COLUMN interface VARCHAR(16) DEFAULT NULL AFTER transaction_type"
            );
        }

        unless ( column_exists( 'pseudonymized_transactions', 'operator' ) ) {
            $dbh->do("ALTER TABLE pseudonymized_transactions ADD COLUMN operator INT(11) DEFAULT NULL AFTER interface");
        }

        $dbh->do(
            "ALTER TABLE pseudonymized_transactions ADD INDEX IF NOT EXISTS `pseudonymized_transactions_reporting_1` (`interface`)"
        );
        $dbh->do(
            "ALTER TABLE pseudonymized_transactions ADD INDEX IF NOT EXISTS `pseudonymized_transactions_reporting_2` (`operator`)"
        );
    },
    }
