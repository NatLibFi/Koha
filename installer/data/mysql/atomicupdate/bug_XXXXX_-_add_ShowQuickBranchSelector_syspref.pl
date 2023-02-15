use Modern::Perl;

return {
    bug_number => "XXXXX",
    description => "Add new system preference ShowQuickBranchSelector",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        $dbh->do(q{INSERT IGNORE INTO systempreferences (variable,value) VALUES ('ShowQuickBranchSelector', '1') });
    },
};
