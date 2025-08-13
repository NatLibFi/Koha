use Modern::Perl;

return {
    bug_number => "XXXXX",
    description => "Add new system preference MaxCheckoutsHardLimit",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        $dbh->do(q{INSERT IGNORE INTO systempreferences (variable,value,options,explanation,type) VALUES ('MaxCheckoutsHardLimit', '', NULL, 'If not empty, sets the global hard limit of number of checkouts ANY borrower can have in total, overlapping any other values calculated by other means or rules', 'integer') });
    },
};
