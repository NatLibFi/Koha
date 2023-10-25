use Modern::Perl;

return {
    bug_number  => "XXXXX",
    description => "Extend matchpoint in identity_providers",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        # Do you stuffs here
        # now is `matchpoint` enum('email','phone','userid','cardnumber') NOT NULL COMMENT
        $dbh->do(q{
            ALTER TABLE `identity_providers`
            MODIFY COLUMN `matchpoint` enum('email','phone','userid','cardnumber') NOT NULL COMMENT 'The field of the patron that will be used to match the user from the identity provider';

            });

        # Print useful stuff here
        # tables
        say $out "Extend 'matchpoint' field in 'identity_providers'";

    },
};
