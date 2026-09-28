use Modern::Perl;
use Koha::Installer::Output qw(say_success);

return {
    bug_number  => "XXXXX",
    description => "Add MaxCheckoutsHardLimit system preference",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        $dbh->do(
            q{
            INSERT IGNORE INTO systempreferences (variable, value)
            VALUES ('MaxCheckoutsHardLimit', '')
        }
        );

        say_success( $out, "Added new system preference 'MaxCheckoutsHardLimit'" );
    },
};
