use Modern::Perl;
use Koha::Installer::Output qw(say_success);

return {
    bug_number  => "00000",
    description => "Add HoldsCallnumberSortQueue system preference",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        $dbh->do(
            q{
            INSERT IGNORE INTO systempreferences ( `variable`, `value` )
            VALUES ('HoldsCallnumberSortQueue', 'classification')
        }
        );

        say_success( $out, "Added system preference HoldsCallnumberSortQueue" );
    },
};
