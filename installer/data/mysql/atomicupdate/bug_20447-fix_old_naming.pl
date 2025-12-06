use Modern::Perl;

return {
    bug_number => "20447",
    description => "Fix old values for SummaryHoldings system preference",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        $dbh->do(q{
            UPDATE systempreferences new
            JOIN systempreferences old ON old.variable = 'MFHDEmbedTagsInBiblio'
            SET new.value = old.value
            WHERE new.variable = 'SummaryHoldingsEmbedTagsInBiblio'
        });

        $dbh->do(q{
            DELETE old
            FROM systempreferences old
            JOIN systempreferences new ON new.variable = 'SummaryHoldingsEmbedTagsInBiblio'
            WHERE old.variable = 'MFHDEmbedTagsInBiblio'
        });

        $dbh->do(q{
            UPDATE systempreferences new
            JOIN systempreferences old ON old.variable = 'MFHDEnabled'
            SET new.value = old.value
            WHERE new.variable = 'SummaryHoldings'
        });

        $dbh->do(q{
            DELETE old
            FROM systempreferences old
            JOIN systempreferences new ON new.variable = 'SummaryHoldings'
            WHERE old.variable = 'MFHDEnabled'
        });

        $dbh->do(q{
            UPDATE systempreferences
            SET explanation = 'Use Summary Holdings records (MFHD, MARC holdings) as an intermediate layer between bibliographic records and items, storing summary holdings and location information and overlaying selected MFHD fields into bibliographic records and item editor defaults.'
            WHERE variable = 'SummaryHoldings'
        });

        $dbh->do(q{
            UPDATE systempreferences
            SET explanation = 'Comma-separated list of MFHD MARC tags to embed into bibliographic records (e.g. "583,852"), used by OAI-PMH, and providing this data to search index, when MFHD is enabled. Leave empty to embed none. Use the special value "all" to embed all data tags (i.e. except control fields 00X and 999) from the MFHD holdings record.'
            WHERE variable = 'SummaryHoldingsEmbedTagsInBiblio'
        });

    },};
