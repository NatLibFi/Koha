use Modern::Perl;

return {
    bug_number => "00000",
    description => "Fix saved data",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        my $mc = $dbh->do( "UPDATE circulation_rules
                   SET rule_value = REPLACE(rule_value, ',', '.')
                   WHERE (     rule_name LIKE 'rentaldiscount'
                            OR rule_name LIKE 'overduefinescap'
                            OR rule_name LIKE 'recall_overdue_fine'
                            OR rule_name LIKE 'fine'
                        ) AND rule_value LIKE '%,%';"
                );

        say $out "Updated $mc records";
    },
}
