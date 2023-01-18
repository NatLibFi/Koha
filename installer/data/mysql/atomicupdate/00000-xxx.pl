use Modern::Perl;

return {
    bug_number => "BUG_NUMBER",
    description => "A single line description",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        unless ( column_exists( 'borrower_attribute_types', 'trim_value' ) ) {
            $dbh->do( "ALTER TABLE `borrower_attribute_types` ADD COLUMN `trim_value` tinyint(1) NOT NULL DEFAULT 0 COMMENT 'defines if this value needs to be trimmed of whitespaces (1 for yes, 0 for no)' AFTER unique_id" );
        }
    },
};
