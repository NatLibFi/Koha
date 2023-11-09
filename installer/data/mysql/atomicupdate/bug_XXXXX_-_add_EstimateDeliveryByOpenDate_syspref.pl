use Modern::Perl;

return {
    bug_number => "XXXXX",
    description => "Add new system preference EstimateDeliveryByBasketDate",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        $dbh->do(q{INSERT IGNORE INTO systempreferences (variable,value,options,explanation,type) VALUES ('EstimateDeliveryByBasketDate', '0', NULL, 'Calculate the estimated delivery date from the time the basket is opened, instead of when it is closed.', 'YesNo') });
    },
};