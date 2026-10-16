use Modern::Perl;

return {
    bug_number  => "33013",
    description => "Add age, interface and operator to pseudonymized transactions",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        unless ( column_exists( 'pseudonymized_transactions', 'age' ) ) {
            $dbh->do("ALTER TABLE pseudonymized_transactions ADD COLUMN `age` TINYINT(4) DEFAULT NULL AFTER `sex`");
        }

        unless ( column_exists( 'pseudonymized_transactions', 'interface' ) ) {
            $dbh->do(
                "ALTER TABLE pseudonymized_transactions ADD COLUMN `interface` VARCHAR(16) DEFAULT NULL AFTER `transaction_type`"
            );
        }

        unless ( column_exists( 'pseudonymized_transactions', 'operator' ) ) {
            $dbh->do("ALTER TABLE pseudonymized_transactions ADD COLUMN `operator` INT(11) DEFAULT NULL AFTER `interface`");
        }

        unless ( index_exists( 'pseudonymized_transactions', 'pseudonymized_transactions_reporting_1' ) ) {
            $dbh->do(
                "ALTER TABLE pseudonymized_transactions ADD INDEX `pseudonymized_transactions_reporting_1` (`interface`)"
            );
        }

        unless ( index_exists( 'pseudonymized_transactions', 'pseudonymized_transactions_reporting_2' ) ) {
            $dbh->do(
                "ALTER TABLE pseudonymized_transactions ADD INDEX `pseudonymized_transactions_reporting_2` (`operator`)"
            );
        }
    },
};
