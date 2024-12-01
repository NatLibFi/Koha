#!/usr/bin/perl


# Copyright 2000-2002 Katipo Communications
# Copyright 2004-2010 BibLibre
# Copyright 2017-2019 University of Helsinki (The National Library Of Finland)
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
use CGI;
use POSIX     qw( strftime );
use Try::Tiny qw(catch try);

use C4::Output qw( output_html_with_http_headers output_and_exit );
use C4::Auth qw( get_template_and_user haspermission );
use C4::Biblio
  qw( GetMarcFromKohaField GetMarcStructure GetUsedMarcStructure TransformHtmlToMarc );
use C4::Context;
use MARC::Record;
use C4::ClassSource qw( GetClassSources );
use Koha::Biblios;
use Koha::BiblioFrameworks;
use Koha::DateUtils qw( dt_from_string );

use Koha::ItemTypes;
use Koha::Libraries;
use Koha::Holdings;

use Date::Calc qw(Today);
use MARC::File::USMARC;
use MARC::File::XML;
use URI::Escape qw( uri_escape_utf8 );

if ( C4::Context->preference('marcflavour') eq 'UNIMARC' ) {
    MARC::File::XML->default_record_format('UNIMARC');
}

our ( $tagslib, $usedTagsLib, $mandatory_z3950, $op, $changed_framework );

=head1 FUNCTIONS

=head2 build_authorized_values_list

=cut

sub build_authorized_values_list {
    my ( $tag, $subfield, $value, $dbh, $authorised_values_sth,$index_tag,$index_subfield ) = @_;

    my @authorised_values;
    my %authorised_lib;

    # builds list, depending on authorised value...

    #---- branch
    if ( $tagslib->{$tag}->{$subfield}->{'authorised_value'} eq "branches" ) {
        my $libraries = Koha::Libraries->search_filtered({}, {order_by => ['branchname']});
        while ( my $l = $libraries->next ) {
            push @authorised_values, $l->branchcode;
            $authorised_lib{$l->branchcode} = $l->branchname;
        }
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{authorised_value} eq "LOC" ) {
        push @authorised_values, "";

        my $branch_limit = C4::Context->userenv ? C4::Context->userenv->{"branch"} : "";
        my $avs = Koha::AuthorisedValues->search_with_library_limits(
            {
                category => $tagslib->{$tag}->{$subfield}->{authorised_value},
            },
            {
                order_by => [ 'category', 'lib', 'lib_opac' ],
            },
            $branch_limit
        );

        while ( my $av = $avs->next ) {
            push @authorised_values, $av->authorised_value;
            $authorised_lib{$av->authorised_value} = $av->lib;
        }
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{authorised_value} eq "cn_source" ) {
        push @authorised_values, "";

        my $class_sources = GetClassSources();

        my $default_source = C4::Context->preference("DefaultClassificationSource");

        foreach my $class_source (sort keys %$class_sources) {
            next unless $class_sources->{$class_source}->{'used'} or
                        ($value and $class_source eq $value) or
                        ($class_source eq $default_source);
            push @authorised_values, $class_source;
            $authorised_lib{$class_source} = $class_sources->{$class_source}->{'description'};
        }
        $value = $default_source unless $value;
    }
    else {
        my $branch_limit = C4::Context->userenv ? C4::Context->userenv->{"branch"} : "";
        $authorised_values_sth->execute(
            $tagslib->{$tag}->{$subfield}->{authorised_value},
            $branch_limit ? $branch_limit : (),
        );

        push @authorised_values, "";

        while ( my ( $value, $lib ) = $authorised_values_sth->fetchrow_array ) {
            push @authorised_values, $value;
            $authorised_lib{$value} = $lib;
        }
    }
    $authorised_values_sth->finish;
    return {
        type     => 'select',
        id       => "tag_".$tag."_subfield_".$subfield."_".$index_tag."_".$index_subfield,
        name     => "tag_".$tag."_subfield_".$subfield."_".$index_tag."_".$index_subfield,
        default  => $value,
        values   => \@authorised_values,
        labels   => \%authorised_lib,
    };

}

=head2 CreateKey

    Create a random value to set it into the input name

=cut

sub CreateKey {
    return int(rand(1000000));
}

=head2 create_input

 builds the <input ...> entry for a subfield.

=cut

sub create_input {
    my ( $tag, $subfield, $value, $index_tag, $tabloop, $rec, $authorised_values_sth,$cgi ) = @_;

    my $index_subfield = CreateKey(); # create a specific key for each subfield

    # if there is no value provided but a default value in parameters, get it
    if ( $value eq '' ) {
        $value = $tagslib->{$tag}->{$subfield}->{defaultvalue} // q{};

        # get today date & replace <<YYYY>>, <<YY>>, <<MM>>, <<DD>> if provided in the default value
        my $today_dt = dt_from_string;
        my $year = $today_dt->strftime('%Y');
        my $shortyear = $today_dt->strftime('%y');
        my $month = $today_dt->strftime('%m');
        my $day = $today_dt->strftime('%d');
        $value =~ s/<<YYYY>>/$year/g;
        $value =~ s/<<YY>>/$shortyear/g;
        $value =~ s/<<MM>>/$month/g;
        $value =~ s/<<DD>>/$day/g;
        # And <<USER>> with surname (?)
        my $username=(C4::Context->userenv?C4::Context->userenv->{'surname'}:"superlibrarian");
        $value=~s/<<USER>>/$username/g;

    }
    my $dbh = C4::Context->dbh;

    # map '@' as "subfield" label for fixed fields
    # to something that's allowed in a div id.
    my $id_subfield = $subfield;
    $id_subfield = "00" if $id_subfield eq "@";

    my %subfield_data = (
        tag        => $tag,
        subfield   => $id_subfield,
        marc_lib       => $tagslib->{$tag}->{$subfield}->{lib},
        tag_mandatory  => $tagslib->{$tag}->{mandatory},
        mandatory      => $tagslib->{$tag}->{$subfield}->{mandatory},
        important      => $tagslib->{$tag}->{$subfield}->{important},
        repeatable     => $tagslib->{$tag}->{$subfield}->{repeatable},
        kohafield      => $tagslib->{$tag}->{$subfield}->{kohafield},
        index          => $index_tag,
        id             => "tag_".$tag."_subfield_".$id_subfield."_".$index_tag."_".$index_subfield,
        value          => $value,
        maxlength      => $tagslib->{$tag}->{$subfield}->{maxlength},
        random         => CreateKey(),
    );

    if(exists $mandatory_z3950->{$tag.$subfield}){
        $subfield_data{z3950_mandatory} = $mandatory_z3950->{$tag.$subfield};
    }
    # Subfield is hidden depending of hidden and mandatory flag, and is always
    # shown if it contains anything or if its field is mandatory or important.
    my $tdef = $tagslib->{$tag};
    $subfield_data{visibility} = "display:none;"
        if $tdef->{$subfield}->{hidden} % 2 == 1 &&
           $value eq '' &&
           !$tdef->{$subfield}->{mandatory} &&
           !$tdef->{mandatory} &&
           !$tdef->{$subfield}->{important} &&
           !$tdef->{important};
    # expand all subfields of 773 if there is a host item provided in the input
    $subfield_data{visibility} ="" if ($tag eq 773 and $cgi->param('hostitemnumber'));

    # it's an authorised field
    if ( $tagslib->{$tag}->{$subfield}->{authorised_value} ) {
        $subfield_data{marc_value} =
          build_authorized_values_list( $tag, $subfield, $value, $dbh,
            $authorised_values_sth,$index_tag,$index_subfield );

    # it's a subfield $9 linking to an authority record - see bug 2206
    }
    elsif ($subfield eq "9" and
           exists($tagslib->{$tag}->{'a'}->{authtypecode}) and
           defined($tagslib->{$tag}->{'a'}->{authtypecode}) and
           $tagslib->{$tag}->{'a'}->{authtypecode} ne '') {

        $subfield_data{marc_value} = {
            type      => 'text',
            id        => $subfield_data{id},
            name      => $subfield_data{id},
            value     => $value,
            size      => 5,
            maxlength => $subfield_data{maxlength},
            readonly  => 1,
        };

    # it's a thesaurus / authority field
    }
    elsif ( $tagslib->{$tag}->{$subfield}->{authtypecode} ) {
        # when authorities auto-creation is allowed, do not set readonly
        my $is_readonly = !C4::Context->preference("BiblioAddsAuthorities");

        $subfield_data{marc_value} = {
            type      => 'text',
            id        => $subfield_data{id},
            name      => $subfield_data{id},
            value     => $value,
            size      => 67,
            maxlength => $subfield_data{maxlength},
            readonly  => ($is_readonly) ? 1 : 0,
            authtype  => $tagslib->{$tag}->{$subfield}->{authtypecode},
        };

    # it's a plugin field
    } elsif ( $tagslib->{$tag}->{$subfield}->{'value_builder'} ) {
        require Koha::FrameworkPlugin;
        my $plugin = Koha::FrameworkPlugin->new( {
            name => $tagslib->{$tag}->{$subfield}->{'value_builder'},
        });
        my $pars= { dbh => $dbh, record => $rec, tagslib => $tagslib,
            id => $subfield_data{id}, tabloop => $tabloop };
        $plugin->build( $pars );
        if( !$plugin->errstr ) {
            $subfield_data{marc_value} = {
                type           => 'text_complex',
                id             => $subfield_data{id},
                name           => $subfield_data{id},
                value          => $value,
                size           => 67,
                maxlength      => $subfield_data{maxlength},
                javascript     => $plugin->javascript,
                plugin         => $plugin->name,
                noclick        => $plugin->noclick,
            };
        } else {
            warn $plugin->errstr;
            # supply default input form
            $subfield_data{marc_value} = {
                type      => 'text',
                id        => $subfield_data{id},
                name      => $subfield_data{id},
                value     => $value,
                size      => 67,
                maxlength => $subfield_data{maxlength},
                readonly  => 0,
            };
        }

    # it's an hidden field
    } elsif ( $tag eq '' ) {
        $subfield_data{marc_value} = {
            type      => 'hidden',
            id        => $subfield_data{id},
            name      => $subfield_data{id},
            value     => $value,
            size      => 67,
            maxlength => $subfield_data{maxlength},
        };

    }
    else {
        # it's a standard field
        if (
            length($value) > 100
            or
            ( C4::Context->preference("marcflavour") eq "UNIMARC" && $tag >= 300
                and $tag < 400 && $subfield eq 'a' )
            or (    $tag >= 500
                and $tag < 600
                && C4::Context->preference("marcflavour") eq "MARC21" )
          )
        {
            $subfield_data{marc_value} = {
                type      => 'textarea',
                id        => $subfield_data{id},
                name      => $subfield_data{id},
                value     => $value,
            };

        }
        else {
            $subfield_data{marc_value} = {
                type      => 'text',
                id        => $subfield_data{id},
                name      => $subfield_data{id},
                value     => $value,
                size      => 67,
                maxlength => $subfield_data{maxlength},
                readonly  => 0,
            };

        }
    }
    $subfield_data{'index_subfield'} = $index_subfield;
    return \%subfield_data;
}


=head2 format_indicator

Translate indicator value for output form - specifically, map
indicator = ' ' to ''.  This is for the convenience of a cataloger
using a mouse to select an indicator input.

=cut

sub format_indicator {
    my $ind_value = shift;
    return '' if not defined $ind_value;
    return '' if $ind_value eq ' ';
    return $ind_value;
}

sub build_tabs {
    my ( $template, $record, $dbh, $encoding,$input ) = @_;

    # fill arrays
    my @loop_data = ();
    my $tag;

    my $branch_limit = C4::Context->userenv ? C4::Context->userenv->{"branch"} : "";
    my $query = "SELECT authorised_value, lib
                FROM authorised_values";
    $query .= qq{ LEFT JOIN authorised_values_branches ON ( id = av_id )} if $branch_limit;
    $query .= " WHERE category = ?";
    $query .= " AND ( branchcode = ? OR branchcode IS NULL )" if $branch_limit;
    $query .= " ORDER BY lib, lib_opac";
    my $authorised_values_sth = $dbh->prepare( $query );

    # in this array, we will push all the 10 tabs
    # to avoid having 10 tabs in the template : they will all be in the same BIG_LOOP
    my @BIG_LOOP;
    my %seen;
    my @tab_data; # all tags to display

    my $max_num_tab=-1;
    my ( $itemtag, $itemsubfield ) = GetMarcFromKohaField( "items.itemnumber" );
    foreach my $used ( @$usedTagsLib ){
        push @tab_data,$used->{tagfield} if not $seen{$used->{tagfield}};
        $seen{$used->{tagfield}}++;
        if (   $used->{tab} > -1
            && $used->{tab} >= $max_num_tab
            && $used->{tagfield} ne $itemtag )
        {
            $max_num_tab = $used->{tab};
        }
    }
    if($max_num_tab >= 9){
        $max_num_tab = 9;
    }
    # loop through each tab 0 through 9
    for ( my $tabloop = 0 ; $tabloop <= $max_num_tab ; $tabloop++ ) {
        my @loop_data = (); #innerloop in the template.
        my $i = 0;
        foreach my $tag (sort @tab_data) {
            $i++;
            next if ! $tag;
            my ($indicator1, $indicator2);
            my $index_tag = CreateKey;

            # if MARC::Record is not empty =>use it as master loop, then add missing subfields that should be in the tab.
            # if MARC::Record is empty => use tab as master loop.
            if ( $record ne -1 && ( $record->field($tag) || $tag eq '000' ) ) {
                my @fields;
                if ( $tag ne '000' ) {
                            @fields = $record->field($tag);
                }
                else {
                push @fields, $record->leader(); # if tag == 000
                }
                # loop through each field
                foreach my $field (@fields) {

                    my @subfields_data;
                    if ( $tag < 10 ) {
                        my ( $value, $subfield );
                        if ( $tag ne '000' ) {
                            $value    = $field->data();
                            $subfield = "@";
                        }
                        else {
                            $value    = $field;
                            $subfield = '@';
                        }
                        next if ( $tagslib->{$tag}->{$subfield}->{tab} ne $tabloop );
                        next
                          if ( $tagslib->{$tag}->{$subfield}->{kohafield} eq
                            'biblio.biblionumber' );
                        push(
                            @subfields_data,
                            &create_input(
                                $tag, $subfield, $value, $index_tag, $tabloop, $record,
                                $authorised_values_sth,$input
                            )
                        );
                    }
                    else {
                        my @subfields = $field->subfields();
                        foreach my $subfieldcount ( 0 .. $#subfields ) {
                            my $subfield = $subfields[$subfieldcount][0];
                            my $value    = $subfields[$subfieldcount][1];
                            next if ( length $subfield != 1 );
                            next if ( $tagslib->{$tag}->{$subfield}->{tab} ne $tabloop );
                            push(
                                @subfields_data,
                                &create_input(
                                    $tag, $subfield, $value, $index_tag, $tabloop,
                                    $record, $authorised_values_sth,$input
                                )
                            );
                        }
                    }

                    # now, loop again to add parameter subfield that are not in the MARC::Record
                    foreach my $subfield ( sort( keys %{ $tagslib->{$tag} } ) )
                    {
                        next if ( length $subfield != 1 );
                        next if ( defined $tagslib->{$tag}->{$subfield}->{tab} and
                            $tagslib->{$tag}->{$subfield}->{tab} ne $tabloop );
                        next if ( $tag < 10 );
                        next
                          if ( ( $tagslib->{$tag}->{$subfield}->{hidden} <= -4 )
                            or ( $tagslib->{$tag}->{$subfield}->{hidden} >= 5 ) )
                            and not ( $subfield eq "9" and
                                      exists($tagslib->{$tag}->{'a'}->{authtypecode}) and
                                      defined($tagslib->{$tag}->{'a'}->{authtypecode}) and
                                      $tagslib->{$tag}->{'a'}->{authtypecode} ne ""
                                    )
                          ;    #check for visibility flag
                               # if subfield is $9 in a field whose $a is authority-controlled,
                               # always include in the form regardless of the hidden setting - bug 2206
                        next if ( defined( $field->subfield($subfield) ) );
                        push(
                            @subfields_data,
                            &create_input(
                                $tag, $subfield, '', $index_tag, $tabloop, $record,
                                $authorised_values_sth,$input
                            )
                        );
                    }
                    if ( $#subfields_data >= 0 ) {
                        # build the tag entry.
                        # note that the random() field is mandatory. Otherwise, on repeated fields, you'll
                        # have twice the same "name" value, and cgi->param() will return only one, making
                        # all subfields to be merged in a single field.
                        my %tag_data = (
                            tag           => $tag,
                            index         => $index_tag,
                            tag_lib       => $tagslib->{$tag}->{lib},
                            repeatable       => $tagslib->{$tag}->{repeatable},
                            mandatory       => $tagslib->{$tag}->{mandatory},
                            important       => $tagslib->{$tag}->{important},
                            subfield_loop => \@subfields_data,
                            fixedfield    => $tag < 10?1:0,
                            random        => CreateKey,
                        );
                        if ($tag >= 10){ # no indicator for 00x tags
                           $tag_data{indicator1} = format_indicator($field->indicator(1)),
                           $tag_data{indicator2} = format_indicator($field->indicator(2)),
                        }
                        push( @loop_data, \%tag_data );
                    }
                 } # foreach $field end

                # if breeding is empty
            }
            else {
                my @subfields_data;
                foreach my $subfield (
                    sort { $a->{display_order} <=> $b->{display_order} || $a->{subfield} cmp $b->{subfield} }
                    grep { ref($_) && %$_ } # Not a subfield (values for "important", "lib", "mandatory", etc.) or empty
                    values %{ $tagslib->{$tag} } )
                {
                    next
                      if ( ( $subfield->{hidden} <= -4 )
                        or ( $subfield->{hidden} >= 5 ) )
                      and not ( $subfield->{subfield} eq "9" and
                                exists($tagslib->{$tag}->{'a'}->{authtypecode}) and
                                defined($tagslib->{$tag}->{'a'}->{authtypecode}) and
                                $tagslib->{$tag}->{'a'}->{authtypecode} ne ""
                              )
                      ;    #check for visibility flag
                           # if subfield is $9 in a field whose $a is authority-controlled,
                           # always include in the form regardless of the hidden setting - bug 2206
                    next
                      if ( $subfield->{tab} ne $tabloop );
                    push(
                        @subfields_data,
                        &create_input(
                            $tag, $subfield->{subfield}, '', $index_tag, $tabloop, $record,
                            $authorised_values_sth,$input
                        )
                    );
                }
                if ( $#subfields_data >= 0 ) {
                    my %tag_data = (
                        tag              => $tag,
                        index            => $index_tag,
                        tag_lib          => $tagslib->{$tag}->{lib},
                        repeatable       => $tagslib->{$tag}->{repeatable},
                        mandatory       => $tagslib->{$tag}->{mandatory},
                        important       => $tagslib->{$tag}->{important},
                        indicator1       => ( $indicator1 || $tagslib->{$tag}->{ind1_defaultvalue} ), #if not set, try to load the default value
                        indicator2       => ( $indicator2 || $tagslib->{$tag}->{ind2_defaultvalue} ), #use short-circuit operator for efficiency
                        subfield_loop    => \@subfields_data,
                        tagfirstsubfield => $subfields_data[0],
                        fixedfield       => $tag < 10?1:0,
                    );

                    push @loop_data, \%tag_data ;
                }
            }
        }
        if ( $#loop_data >= 0 ) {
            push @BIG_LOOP, {
                number    => $tabloop,
                innerloop => \@loop_data,
            };
        }
    }
    $authorised_values_sth->finish;
    $template->param( BIG_LOOP => \@BIG_LOOP );
}

##########################
#          MAIN
##########################
my $input = CGI->new;
my $error = $input->param('error');
my $biblionumber  = $input->param('biblionumber');
my $holding_id    = $input->param('holding_id'); # if holding_id exists, it's a modification, not a new holding.
my $mode          = $input->param('mode') // q{};
my $frameworkcode = $input->param('frameworkcode');
my $redirect      = $input->param('redirect');
my $searchid      = $input->param('searchid') // "";
my $userflags     = 'edit_items';

# Set default values for global variable
$op                = $input->param('op') // q{};
$changed_framework = 0;

if ( $op eq 'cud-change-framework' ) {
    $op = $input->param('original_op');
    $changed_framework = 1;
}

my ($template, $loggedinuser, $cookie) = get_template_and_user(
    {
        template_name   => "cataloguing/addholding.tt",
        query           => $input,
        type            => "intranet",
        flagsrequired   => { editcatalogue => $userflags },
    }
);

my $logged_in_patron = Koha::Patrons->find($loggedinuser);
my $holding;

if ($holding_id) {

    $holding = Koha::Holdings->find($holding_id);

    # just in case $biblionumber obtained from CGI contains weird characters like spaces
    $holding_id = $holding->holding_id if $holding;
    if ($holding) {
        unless ( $holding->can_be_edited($logged_in_patron) ) {
            print $input->redirect("/cgi-bin/koha/errors/403.pl");    # escape early
            exit;
        }

        $frameworkcode = $holding->frameworkcode;

    } else {
        $holding_id = undef;
        $template->param( holding_doesnt_exist => 1 );
    }
} else {
    $holding = Koha::Holding->new();
    $holding->frameworkcode($frameworkcode);
    $holding->biblionumber($biblionumber);
}

$frameworkcode = 'HLD' if not defined $frameworkcode or $frameworkcode eq '';

# TODO: support in advanced editor?
#if ( $op ne "delete" && C4::Context->preference('EnableAdvancedCatalogingEditor') && C4::Auth::haspermission(C4::Context->userenv->{id},{'editcatalogue'=>'advanced_editor'}) && $input->cookie( 'catalogue_editor_' . $loggedinuser ) eq 'advanced' ) {
#    print $input->redirect( '/cgi-bin/koha/cataloguing/editor.pl#catalog/' . $biblionumber . '/holdings/' . ( $holding_id ? $holding_id : '' ) );
#    exit;
#}

# Set more default values for global variable
$tagslib           = &GetMarcStructure( 1, $frameworkcode );
$usedTagsLib       = &GetUsedMarcStructure($frameworkcode);
# $mandatory_z3950   = GetMandatoryFieldZ3950($frameworkcode);

my ( $biblionumbertagfield, $biblionumbertagsubfield ) =
    &GetMarcFromKohaField( "biblio.biblionumber" );

if ($op eq 'cud-addholding') {
    $template->param(
        biblionumberdata => $biblionumber,
    );
    # Convert HTML input to MARC
    my @params = $input->multi_param();
    my $record = TransformHtmlToMarc( $input, 1 );

    $holding->frameworkcode($frameworkcode);
    $holding->biblionumber($biblionumber);
    $holding->set_marc({ record => $record });
    $holding->store();

    $holding_id = $holding->holding_id;

    if ($redirect eq 'items' || ($mode ne 'popup' && $redirect ne 'view' && $redirect ne 'just_save')) {
        print $input->redirect("/cgi-bin/koha/catalogue/detail.pl?biblionumber=$biblionumber&searchid=$searchid");
        exit;
    } elsif ($holding_id && $redirect eq 'view') {
        print $input->redirect("/cgi-bin/koha/catalogue/detail.pl?biblionumber=$biblionumber&searchid=$searchid");
        exit;
    } elsif ($redirect eq 'just_save') {
        my $tab = $input->param('current_tab');
        print $input->redirect("/cgi-bin/koha/cataloguing/addholding.pl?biblionumber=$biblionumber&holding_id=$holding_id&frameworkcode=$frameworkcode&tab=$tab&searchid=$searchid");
        exit;
    } else {
        $template->param(
            biblionumber => $biblionumber,
            holding_id   => $holding_id,
            done         => 1,
            popup        => $mode,
        );
        output_html_with_http_headers($input, $cookie, $template->output);
        exit;
    }
} elsif ($op eq 'delete') {
    if ($holding->items()->count()) {
        $template->param(
            error_items_exist => 1
        );
    } elsif (!$holding->delete()) {
        $template->param(
            error_delete_failed => 1
        );
    } else {
        print $input->redirect("/cgi-bin/koha/catalogue/detail.pl?biblionumber=$biblionumber&searchid=$searchid");
        exit;
    }
}

#----------------------------------------------------------------------------
# If we're in a duplication case, we have to clear the holding_id
# as we'll save the holding as a new one.
$template->param(
    holding_iddata => $holding_id,
    op             => $op,
);
if ($op eq 'duplicate') {
    $holding_id = '';
}

my $record = -1;
if ($changed_framework) {
    $record = TransformHtmlToMarc($input, 1);
}

if ( $holding ) {
    if( $record == -1 ) {
        if( my $metadata = $holding->metadata() ) {
            eval { $record = $metadata->record };
            if ($@) {
                my $exception = $@;
                warn "Invalid metadata found for holding $holding_id";
                $exception->rethrow unless ( $exception->isa('Koha::Exceptions::Metadata::Invalid') );
                $record = $holding->metadata->record_strip_nonxml;
                $template->param( INVALID_METADATA => $exception );
            }
        }
        # else {
        #     # warn "No metadata found for holding $holding (holding_id=".($holding_id // '-undef-')."), record=$record";
        #     $record = -1;
        # }
    }
    elsif ( !$record ) {
        warn "Unexpected error: record is empty for holding $holding_id";
        $record = -1;
    }
}

if (!$biblionumber) {
    # we must have a holdings record if we don't have a biblionumber
    $biblionumber = $holding->biblionumber;
}
my $biblio;
$biblio = Koha::Biblios->find($biblionumber) if $biblionumber;

output_and_exit( $input, $cookie, $template, 'unknown_biblio')
    unless $biblio;

build_tabs($template, $record, C4::Context->dbh, '', $input);
$template->param(
    holding_id               => $holding_id,
    biblionumber             => $biblionumber,
    biblionumbertagfield     => $biblionumbertagfield,
    biblionumbertagsubfield  => $biblionumbertagsubfield,
    title                    => $biblio->title,
    author                   => $biblio->author
);

my @frameworks = Koha::BiblioFrameworks->search({}, { order_by => ['frameworktext'] })->as_list();
$template->param(
    frameworks => \@frameworks,
    popup => $mode,
    frameworkcode => $frameworkcode,
    itemtype => $frameworkcode,
    borrowernumber => $loggedinuser,
    tab => scalar $input->param('tab')
);
$template->{'VARS'}->{'searchid'} = $searchid;

output_html_with_http_headers($input, $cookie, $template->output);
