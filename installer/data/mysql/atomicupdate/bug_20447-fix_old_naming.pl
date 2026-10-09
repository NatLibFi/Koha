use Modern::Perl;
use Koha::Installer::Output qw(say_success say_info);

return {
    bug_number => "20447",
    description => "Normalize SummaryHoldings sysprefs text and defaults",
    up => sub {
        my ($args) = @_;
        my ($dbh, $out) = @$args{qw(dbh out)};

        my $res = $dbh->do(q{
            UPDATE systempreferences
            SET explanation = 'Use Summary Holdings records (MFHD, MARC holdings) as an intermediate layer between bibliographic records and items, storing summary holdings and location information and overlaying selected MFHD fields into bibliographic records and item editor defaults.'
            WHERE variable = 'SummaryHoldings'
        });

        $res += $dbh->do(q{
            UPDATE systempreferences
            SET explanation = 'Comma-separated list of MFHD tags to embed into bibliographic records for export (e.g. OAI-PMH) when SummaryHoldings is enabled. Each entry can be a tag (852), a tag with included subfields (852abch), or a tag with excluded subfields (852!x). Leave empty to embed none. Use "all" to embed all MFHD data fields. Control fields (00X) and Koha-internal 999 are never embedded.',
                value = '852!x'
            WHERE variable = 'SummaryHoldingsEmbedTagsInBiblio'
        });

        $res += $dbh->do(q{
            UPDATE systempreferences
            SET explanation = 'Comma-separated list of MFHD tags to embed into bibliographic records for search indexing when SummaryHoldings is enabled. Each entry can be a tag (852), a tag with included subfields (852abch), or a tag with excluded subfields (852!x). Leave empty to embed none. Use "all" to embed all MFHD data fields. Control fields (00X) and Koha-internal 999 are never embedded. Changing this preference requires reindexing.',
                value = '583,852'
            WHERE variable = 'SummaryHoldingsEmbedTagsInSearch'
        });

        # We account 0E0's from above, but if DO's (migration) fails it'll crash on level above.
        if ($res) {
            say_success($out, "Updated SummaryHoldings* system preferences' explanations and values to base ones among all our libraries");
        } else {
            say_info($out, "SummaryHoldings*: Nothing to update, all already set");
        }

    },};
