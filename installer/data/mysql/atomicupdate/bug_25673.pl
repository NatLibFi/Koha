use Modern::Perl;
use Koha::Installer::Output qw( say_success );

return {
    bug_number  => '25673',
    description => 'Add and repair patron data disclosure logging preferences',
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @{$args}{qw( dbh out )};

        $dbh->do(
            q{
                INSERT IGNORE INTO systempreferences (variable, value)
                VALUES
                    ('StaffPatronDataDisclosureLog', '0'),
                    ('StaffPatronDataDisclosureMaxSubjects', '1000')
            }
        );

        $dbh->do(
            q{
                UPDATE systempreferences
                SET value = '0'
                WHERE variable = 'StaffPatronDataDisclosureLog'
                  AND COALESCE(value, '') NOT REGEXP '^[01]$'
            }
        );

        $dbh->do(
            q{
                UPDATE systempreferences
                SET value = '1000'
                WHERE variable = 'StaffPatronDataDisclosureMaxSubjects'
                  AND COALESCE(value, '') NOT REGEXP '^[1-9][0-9]*$'
            }
        );

        say_success( $out, 'Added or repaired patron data disclosure logging preferences' );
    },
};
