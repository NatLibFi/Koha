#!/usr/bin/perl
#
# Copyright 2006 Katipo Communications.
# Parts Copyright 2009 Foundations Bible College.
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
use autouse 'Data::Dumper' => qw(Dumper);

use C4::Auth     qw( get_template_and_user );
use C4::Output   qw( output_html_with_http_headers );
use C4::Creators qw(
    get_all_layouts
    get_all_profiles
    get_all_templates
    get_batch_summary
    html_table
);
use C4::Labels;
use Koha::List::Patron qw( GetPatronLists );
use C4::Patroncards;

my $cgi = CGI->new;
my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {
        template_name => "patroncards/manage.tt",
        query         => $cgi,
        type          => "intranet",
        flagsrequired => { tools => 'label_creator' },
    }
);

my @errors = ( 'pdferr', 'errnocards', 'errba', 'errpl', 'errpt', 'errlo', 'errtpl', );
foreach my $param (@errors) {
    my $error = $cgi->param($param) ? 1 : 0;
    $template->param( 'error_' . $param => $error )
        if $error;
}

my $op           = $cgi->param('op')           || 'none';
my $card_element = $cgi->param('card_element') || 'template';    # default to template management
my $element_id =
    $cgi->param('element_id') || 0;    # there should never be an element with a id of 0 so this is a safe default

my $db_rows         = {};
my $display_columns = {
    layout => [                        # db column       => {col label                  is link?
        { layout_id   => { label => 'Layout ID', link_field => 0 } },
        { layout_name => { label => 'Layout',    link_field => 0 } },
        { _action     => { label => 'Action',    link_field => 0 } },

        #{layout_xml      => {label => 'Layout XML',     link_field      => 0}},
        { select => { label => 'Select', value => 'layout_id' } },
    ],
    template => [
        { template_id   => { label => 'Template ID',   link_field => 0 } },
        { template_code => { label => 'Template Name', link_field => 0 } },
        { template_desc => { label => 'Description',   link_field => 0 } },
        { _action       => { label => 'Action',        link_field => 0 } },
        { select        => { label => 'Select',        value      => 'template_id' } },
    ],
    profile => [
        { profile_id     => { label => 'Profile ID',    link_field => 0 } },
        { printer_name   => { label => 'Printer Name',  link_field => 0 } },
        { paper_bin      => { label => 'Paper Bin',     link_field => 0 } },
        { _template_code => { label => 'Template Name', link_field => 0 } }
        ,    # this display column does not have a corresponding db column in the profile table, hence the underscore
        { _action => { label => 'Action', link_field => 0 } },
        { select  => { label => 'Select', value      => 'profile_id' } },
    ],
    batch => [
        { batch_id    => { label => 'Batch ID',     link_field => 0 } },
        { description => { label => 'Description',  link_field => 0 } },
        { _item_count => { label => 'Patron Count', link_field => 0 } },
        { _action     => { label => 'Actions',      link_field => 0 } },
        { select      => { label => 'Select',       value      => 'batch_id' } },
    ],
};

my $errstr      = ( $cgi->param('error')     ? $cgi->param('error')             : '' );
my $branch_code = ( $card_element eq 'batch' ? C4::Context->userenv->{'branch'} : '' );

if ( $op eq 'cud-delete' ) {
    my $err         = 0;
    my @element_ids = split( /,/, $element_id );
    foreach my $element_id (@element_ids) {
        if    ( $card_element eq 'layout' ) { $err = C4::Patroncards::Layout::delete( layout_id => $element_id ); }
        elsif ( $card_element eq 'template' ) {
            $err = C4::Patroncards::Template::delete( template_id => $element_id );
        } elsif ( $card_element eq 'profile' ) {
            $err = C4::Patroncards::Profile::delete( profile_id => $element_id );
        } elsif ( $card_element eq 'batch' ) {
            $err = C4::Labels::Batch::delete( batch_id => $element_id, branch_code => $branch_code );
        } else {
            warn sprintf( "Unknown card element passed in for delete operation: %s.", $card_element );
            $errstr = 202;
        }
    }
    print $cgi->redirect( "manage.pl?card_element=$card_element" . ( $err ? "&error=102" : '' ) );
    exit;
} elsif ( $op eq 'none' ) {
    if    ( $card_element eq 'layout' ) { $db_rows = get_all_layouts( { filters => { creator => 'Patroncards' } } ); }
    elsif ( $card_element eq 'template' ) {
        $db_rows = get_all_templates( { filters => { creator => 'Patroncards' } } );
    } elsif ( $card_element eq 'profile' ) {
        $db_rows = get_all_profiles( { filters => { creator => 'Patroncards' } } );
    } elsif ( $card_element eq 'batch' ) {
        $db_rows =
            get_batch_summary( { filters => { branch_code => [ $branch_code, 'NB' ], creator => 'Patroncards' } } );
    } else {
        warn sprintf( "Unknown card element passed in: %s.", $card_element );
        $errstr = 202;
    }
} else {    # trap unsupported operations here
    warn sprintf( 'Manage interface called an unsupported operation: %s', $op );
    print $cgi->redirect("manage.pl?card_element=$card_element&error=201");
    exit;
}

my $table = html_table( $display_columns->{$card_element}, $db_rows );

$template->param( print        => 1 )                    if ( $card_element eq 'batch' );
$template->param( patron_lists => [ GetPatronLists() ] ) if ( $card_element eq 'batch' );

$template->param(
    error => $errstr,
);
$template->param(
    op                 => $op,
    element_id         => $element_id,
    table_loop         => $table,
    card_element       => $card_element,
    card_element_title => (
          $card_element eq 'layout'   ? 'Layouts'
        : $card_element eq 'template' ? 'Templates'
        : $card_element eq 'profile'  ? 'Profiles'
        : $card_element eq 'batch'    ? 'Batches'
        :                               ''
    ),
);

output_html_with_http_headers $cgi, $cookie, $template->output;
