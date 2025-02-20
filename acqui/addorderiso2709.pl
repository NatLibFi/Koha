#!/usr/bin/perl

#A script that lets the user populate a basket from an iso2709 file
#the script first displays a list of import batches, then when a batch is selected displays all the biblios in it.
#The user can then pick which biblios they want to order

# Copyright 2008 - 2011 BibLibre SARL
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;
use CGI qw ( -utf8 );
use List::MoreUtils;
use Encode;
use Scalar::Util qw( looks_like_number );

use C4::Context;
use C4::Auth        qw( get_template_and_user );
use C4::Output      qw( output_html_with_http_headers );
use C4::ImportBatch qw( SetImportBatchStatus );
use C4::Matcher;
use C4::Search qw( FindDuplicate );
use C4::Biblio qw(
    AddBiblio
    GetMarcFromKohaField
    GetMarcPrice
    GetMarcQuantity
    TransformHtmlToXml
);
use C4::Items   qw( PrepareItemrecordDisplay AddItemFromMarc );
use C4::Budgets qw( GetBudget GetBudgets GetBudgetHierarchy CanUserUseBudget );
use C4::Suggestions;    # GetSuggestion
use C4::Members;

use Koha::Number::Price;
use Koha::Libraries;
use Koha::Acquisition::Baskets;
use Koha::Acquisition::Currencies;
use Koha::Acquisition::Orders;
use Koha::Acquisition::Booksellers;
use Koha::ImportBatches;
use Koha::Import::Records;
use Koha::Patrons;
use Koha::MarcOrder;

my $input = CGI->new;
my ( $template, $loggedinuser, $cookie, $userflags ) = get_template_and_user(
    {
        template_name => "acqui/addorderiso2709.tt",
        query         => $input,
        type          => "intranet",
        flagsrequired => { acquisition => 'order_manage' },
    }
);

my $cgiparams    = $input->Vars;
my $op           = $cgiparams->{'op'} || '';
my $booksellerid = $input->param('booksellerid');
my $allmatch     = $input->param('allmatch');
my $bookseller   = Koha::Acquisition::Booksellers->find($booksellerid);

$template->param(
    scriptname     => "/cgi-bin/koha/acqui/addorderiso2709.pl",
    booksellerid   => $booksellerid,
    booksellername => $bookseller->name,
);

if ( $cgiparams->{'import_batch_id'} && $op eq "" ) {
    $op = "batch_details";
}

#Needed parameters:
if ( !$cgiparams->{'basketno'} ) {
    die "Basketnumber required to order from iso2709 file import";
}
my $basket = Koha::Acquisition::Baskets->find( $cgiparams->{basketno} );

#
# 1st step = choose the file to import into acquisition
#
if ( $op eq "" ) {
    $template->param( "basketno" => $cgiparams->{'basketno'} );

    #display batches
    my $batches_list = Koha::MarcOrder->import_batches_list();
    $template->param(
        batch_list  => $batches_list->{list},
        num_results => $batches_list->{num_results}
    );
    #
    # 2nd step = display the content of the chosen file
    #
} elsif ( $op eq "batch_details" ) {

    #display lines inside the selected batch

    $template->param(
        "batch_details" => 1,
        "basketno"      => $cgiparams->{'basketno'},

        # get currencies (for change rates calcs if needed)
        currencies => Koha::Acquisition::Currencies->search,
        bookseller => $bookseller,
        "allmatch" => $allmatch,
    );
    my $biblios_list   = Koha::MarcOrder->import_biblios_list( $cgiparams->{'import_batch_id'} );
    my $overlay_action = $biblios_list->{overlay_action};
    my $nomatch_action = $biblios_list->{nomatch_action};
    my $item_action    = $biblios_list->{item_action};
    my $batch          = $biblios_list->{batch};

    $template->param(
        import_biblio_list                 => $biblios_list->{import_biblio_list},
        num_results                        => $biblios_list->{num_results},
        import_batch_id                    => $biblios_list->{import_batch_id},
        "overlay_action_${overlay_action}" => 1,
        overlay_action                     => $overlay_action,
        "nomatch_action_${nomatch_action}" => 1,
        nomatch_action                     => $nomatch_action,
        "item_action_${item_action}"       => 1,
        item_action                        => $biblios_list->{item_action},
        item_error                         => $biblios_list->{item_error},
        libraries                          => Koha::Libraries->search,
        locationloop                       => $biblios_list->{locationloop},
        itemtypes                          => Koha::ItemTypes->search,
        ccodeloop                          => $biblios_list->{ccodeloop},
        notforloanloop                     => $biblios_list->{notforloanloop},
        can_commit                         => $biblios_list->{can_commit},
        can_revert                         => $biblios_list->{can_revert},
        current_matcher_id                 => $biblios_list->{current_matcher_id},
        current_matcher_code               => $biblios_list->{current_matcher_code},
        current_matcher_description        => $biblios_list->{current_matcher_description},
        available_matchers                 => $biblios_list->{available_matchers},
        batch_info                         => 1,
        file_name                          => $batch->{'file_name'},
        comments                           => $batch->{'comments'},
        import_status                      => $batch->{'import_status'},
        upload_timestamp                   => $batch->{'upload_timestamp'},
        num_records                        => $batch->{'num_records'},
        num_items                          => $batch->{'num_items'}
    );

    if ( $basket->effective_create_items eq 'ordering' && !$basket->is_standing ) {

        # prepare empty item form
        my $cell = PrepareItemrecordDisplay( '', '', undef, 'ACQ' );

        #     warn "==> ".Data::Dumper::Dumper($cell);
        unless ($cell) {
            $cell = PrepareItemrecordDisplay( '', '', undef, '' );
            $template->param( 'NoACQframework' => 1 );
        }
        my @itemloop;
        push @itemloop, $cell;

        $template->param( items => \@itemloop );
    }
    #
    # 3rd step = import the records
    #
} elsif ( $op eq 'cud-import_records' ) {

    #import selected lines
    $template->param( 'basketno' => $cgiparams->{'basketno'} );

    # Budget_id is mandatory for adding an order, we just add a default, the user needs to modify this aftewards
    my $budgets = GetBudgets();
    if ( scalar @$budgets == 0 ) {
        die "No budgets defined, can't continue";
    }
    my $budget_id = @$budgets[0]->{'budget_id'};

    #get all records from a batch, and check their import status to see if they are checked.
    #(default values: quantity 1, uncertainprice yes, first budget)

    # retrieve the file you want to import
    my $import_batch_id = $cgiparams->{'import_batch_id'};
    my $import_batch    = Koha::ImportBatches->find($import_batch_id);
    my $overlay_action  = $import_batch->overlay_action;
    my $import_records  = Koha::Import::Records->search(
        {
            import_batch_id => $import_batch_id,
        }
    );
    my $duplinbatch;
    my $imported                  = 0;
    my @import_record_id_selected = $input->multi_param("import_record_id");
    my $matcher_id                = $input->param('matcher_id');
    my $active_currency           = Koha::Acquisition::Currencies->get_active;

    while ( my $import_record = $import_records->next ) {
        my $marcrecord        = $import_record->get_marc_record || die "couldn't translate marc information";
        my @homebranches      = $input->multi_param( 'homebranch_' . $import_record->import_record_id );
        my @holdingbranches   = $input->multi_param( 'holdingbranch_' . $import_record->import_record_id );
        my @itypes            = $input->multi_param( 'itype_' . $import_record->import_record_id );
        my @nonpublic_notes   = $input->multi_param( 'nonpublic_note_' . $import_record->import_record_id );
        my @public_notes      = $input->multi_param( 'public_note_' . $import_record->import_record_id );
        my @locs              = $input->multi_param( 'loc_' . $import_record->import_record_id );
        my @ccodes            = $input->multi_param( 'ccode_' . $import_record->import_record_id );
        my @notforloans       = $input->multi_param( 'notforloan_' . $import_record->import_record_id );
        my @uris              = $input->multi_param( 'uri_' . $import_record->import_record_id );
        my @copynos           = $input->multi_param( 'copyno_' . $import_record->import_record_id );
        my @budget_codes      = $input->multi_param( 'budget_code_' . $import_record->import_record_id );
        my @itemprices        = $input->multi_param( 'itemprice_' . $import_record->import_record_id );
        my @replacementprices = $input->multi_param( 'itemreplacementprice_' . $import_record->import_record_id );
        my @itemcallnumbers   = $input->multi_param( 'itemcallnumber_' . $import_record->import_record_id );
        my @coded_location_qualifiers =
            $input->multi_param( 'coded_location_qualifier_' . $import_record->import_record_id );
        my @barcodes           = $input->multi_param( 'barcode_' . $import_record->import_record_id );
        my @enumchrons         = $input->multi_param( 'enumchron_' . $import_record->import_record_id );
        my @tags               = $input->multi_param('tag');
        my @subfields          = $input->multi_param('subfield');
        my @field_values       = $input->multi_param('field_value');
        my @serials            = $input->multi_param('serial');
        my $order_internalnote = $cgiparams->{'all_order_internalnote'};
        my $order_vendornote   = $cgiparams->{'all_order_vendornote'};
        my $all_currency       = $cgiparams->{'all_currency'};

        my $client_item_fields = {
            quantity                  => scalar(@homebranches),
            homebranches              => \@homebranches,
            holdingbranches           => \@holdingbranches,
            itypes                    => \@itypes,
            nonpublic_notes           => \@nonpublic_notes,
            public_notes              => \@public_notes,
            locs                      => \@locs,
            ccodes                    => \@ccodes,
            notforloans               => \@notforloans,
            uris                      => \@uris,
            copynos                   => \@copynos,
            budget_codes              => \@budget_codes,
            itemprices                => \@itemprices,
            replacementprices         => \@replacementprices,
            itemcallnumbers           => \@itemcallnumbers,
            coded_location_qualifiers => \@coded_location_qualifiers,
            barcodes                  => \@barcodes,
            enumchrons                => \@enumchrons,
            tags                      => \@tags,
            subfields                 => \@subfields,
            field_values              => \@field_values,
            serials                   => \@serials,
            c_quantity                => $input->param( 'quantity_' . $import_record->import_record_id )
                || GetMarcQuantity( $marcrecord, C4::Context->preference('marcflavour') )
                || 1,
            c_budget_id => $input->param( 'budget_id_' . $import_record->import_record_id )
                || $input->param('all_budget_id')
                || $budget_id,
            c_discount => $input->param( 'discount_' . $import_record->import_record_id ),
            c_sort1 => $input->param( 'sort1_' . $import_record->import_record_id ) || $input->param('all_sort1') || '',
            c_sort2 => $input->param( 'sort2_' . $import_record->import_record_id ) || $input->param('all_sort2') || '',
            c_replacement_price => $input->param( 'replacementprice_' . $import_record->import_record_id ),
            c_price             => $input->param( 'price_' . $import_record->import_record_id )
                || GetMarcPrice( $marcrecord, C4::Context->preference('marcflavour') ),
            order_internalnote => $order_internalnote,
            order_vendornote   => $order_vendornote,
            all_currency       => $all_currency,
        };

        my $args = {
            import_batch_id           => $import_batch_id,
            import_record             => $import_record,
            matcher_id                => $matcher_id,
            overlay_action            => $overlay_action,
            agent                     => 'client',
            import_record_id_selected => \@import_record_id_selected,
            client_item_fields        => $client_item_fields,
            basket_id                 => $cgiparams->{'basketno'},
            vendor                    => $bookseller,
            budget_id                 => $budget_id,
        };
        my $result = Koha::MarcOrder->import_record_and_create_order_lines($args);

        $duplinbatch = $result->{duplicates_in_batch} if $result->{duplicates_in_batch};
        next if $result->{skip};    # If a duplicate is found, or the import record wasn't selected it will be skipped

        $imported++;
    }

    # If all bibliographic records from the batch have been imported we modifying the status of the batch accordingly
    SetImportBatchStatus( $import_batch_id, 'imported' )
        if Koha::Import::Records->search( { import_batch_id => $import_batch_id, status => 'imported' } )->count ==
        Koha::Import::Records->search( { import_batch_id => $import_batch_id } )->count;

    # go to basket page
    if ($imported) {
        print $input->redirect(
            "/cgi-bin/koha/acqui/basket.pl?basketno=" . $cgiparams->{'basketno'} . "&amp;duplinbatch=$duplinbatch" );
    } else {
        print $input->redirect( "/cgi-bin/koha/acqui/addorderiso2709.pl?import_batch_id=$import_batch_id&amp;basketno="
                . $cgiparams->{'basketno'}
                . "&amp;booksellerid=$booksellerid&amp;allmatch=1" );
    }
    exit;
}

my $budgets   = GetBudgets();
my $budget_id = @$budgets[0]->{'budget_id'};

# build bookfund list
my $patron = Koha::Patrons->find($loggedinuser)->unblessed;
my $budget = GetBudget($budget_id);

# build budget list
my $budget_loop       = [];
my $budgets_hierarchy = GetBudgetHierarchy;
foreach my $r ( @{$budgets_hierarchy} ) {
    next unless ( CanUserUseBudget( $patron, $r, $userflags ) );
    push @{$budget_loop},
        {
        b_id            => $r->{budget_id},
        b_txt           => $r->{budget_name},
        b_code          => $r->{budget_code},
        b_sort1_authcat => $r->{'sort1_authcat'},
        b_sort2_authcat => $r->{'sort2_authcat'},
        b_active        => $r->{budget_period_active},
        b_sel           => ( $r->{budget_id} == $budget_id ) ? 1 : 0,
        };
}

@{$budget_loop} =
    sort { uc( $a->{b_txt} ) cmp uc( $b->{b_txt} ) } @{$budget_loop};

$template->param( budget_loop => $budget_loop, );

output_html_with_http_headers $input, $cookie, $template->output;
