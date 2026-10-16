use Modern::Perl;
use Koha::Installer::Output qw(say_success);

return {
    bug_number  => "28400",
    description => "Add response_message column to message_queue table",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        unless ( column_exists( 'message_queue', 'response_message' ) ) {
            $dbh->do(
                q{
                ALTER TABLE `message_queue`
                ADD COLUMN `response_message` mediumtext DEFAULT NULL
            }
            );

            say_success( $out, "Added column 'message_queue.response_message'" );
        }
    },
};
