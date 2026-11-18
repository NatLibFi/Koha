use Modern::Perl;
use Koha::Installer::Output qw(say_success);

return {
    bug_number  => "38666",
    description => "Add EnableClosedStackRequests system preference",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        $dbh->do(q{INSERT IGNORE INTO systempreferences (variable, value) VALUES ('EnableClosedStackRequests', '1')});

        say_success( $out, "Added system preference EnableClosedStackRequests" );
    },
};
