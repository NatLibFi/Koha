use Modern::Perl;

return {
    bug_number => "BUG_NUMBER",
    description => "Update systemprefs Pseudonymization: add age and interface",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        my $res;

        $res = $dbh->do(q{UPDATE systempreferences SET options=REPLACE(options, ',sex,', ',sex,age,')
            WHERE variable='PseudonymizationPatronFields' AND options NOT LIKE '%,age,%'});
        say $out "Warning: PseudonymizationPatronFields already has 'age'"
            if $res == 0;

        $res = $dbh->do(q{UPDATE systempreferences SET options=REPLACE(options, ',transaction_type,', ',transaction_type,interface,')
            WHERE variable='PseudonymizationTransactionFields' AND options NOT LIKE '%,interface,%'});
        say $out "Warning: PseudonymizationTransactionFields already has 'interface'"
            if $res == 0;

        unless( column_exists('pseudonymized_transactions','age') ){
            $dbh->do( "ALTER TABLE pseudonymized_transactions ADD COLUMN age TINYINT DEFAULT NULL AFTER sex" );
        } else {
            say $out "Warning: pseudonymized_transactions already has 'age'"
        }

        unless( column_exists('pseudonymized_transactions','interface') ){
            $dbh->do( "ALTER TABLE pseudonymized_transactions ADD COLUMN interface VARCHAR(16) DEFAULT NULL AFTER transaction_type" );
        } else {
            say $out "Warning: pseudonymized_transactions already has 'interface'"
        }

        unless( column_exists('pseudonymized_transactions','operator') ){
            $dbh->do( "ALTER TABLE pseudonymized_transactions ADD COLUMN operator INT(11) DEFAULT NULL AFTER interface" );
        } else {
            say $out "Warning: pseudonymized_transactions already has 'operator'"
        }

    },
}
