use Modern::Perl;

return {
    bug_number => "XXXXX",
    description => "Add new system preference AllowSipRenewal",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        $dbh->do(q{INSERT IGNORE INTO systempreferences (variable,value,options,explanation,type) VALUES ('AllowSIPRenewal', '0', NULL, 'Allow loan renewal via SIP', 'YesNo') });
    },
};
