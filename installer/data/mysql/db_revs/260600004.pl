use Modern::Perl;
use Koha::Installer::Output qw(say_success);

return {
    bug_number  => "KOHA-85",
    description => "Add PatronPersonalDataAccessLog system preference",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        $dbh->do(
            q{
            INSERT IGNORE INTO systempreferences ( `variable`, `value`, `options`, `explanation`, `type` ) VALUES
            ('PatronPersonalDataAccessLog','0',NULL,'If ON, log staff access to patron personal data','YesNo')
        }
        );

        say_success( $out, "Added new system preference 'PatronPersonalDataAccessLog'" );
    },
};
