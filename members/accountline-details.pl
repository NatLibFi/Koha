#!/usr/bin/perl

# This file is part of Koha.
#
# Copyright 2017 ByWater Solutions
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
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use CGI        qw ( -utf8 );
use C4::Auth   qw( get_template_and_user );
use C4::Output qw( output_html_with_http_headers );
use C4::Context;
use Koha::Patrons;
use Koha::Account::Lines;
use Koha::Patron::Disclosure;

my $input = CGI->new;

my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {
        template_name => "members/accountline-details.tt",
        query         => $input,
        type          => "intranet",
        flagsrequired => {
            borrowers     => 'edit_borrowers',
            updatecharges => 'remaining_permissions'
        },
    }
);

my $accountlines_id = $input->param('accountlines_id');

my $accountline        = Koha::Account::Lines->find($accountlines_id);
my $disclosure_enabled = Koha::Patron::Disclosure->enabled;
my $logged_in_user     = $disclosure_enabled ? Koha::Patrons->find($loggedinuser) : undef;
my $patron;
my %manager_patron_ids;

if ($accountline) {
    my $account_offsets = Koha::Account::Offsets->search(
        [
            { credit_id => $accountline->accountlines_id },
            { debit_id  => $accountline->accountlines_id }
        ],
        { order_by => 'created_on' }
    );

    if ($disclosure_enabled) {
        $manager_patron_ids{ $accountline->manager_id } = 1 if $accountline->manager_id;
        for my $offset ( $account_offsets->search->as_list ) {
            my $offset_accountline;
            if ( defined $offset->credit_id && $offset->credit_id == $accountline->id ) {
                $offset_accountline = $offset->debit;
            } elsif ( defined $offset->debit_id && $offset->debit_id == $accountline->id ) {
                $offset_accountline = $offset->credit;
            }
            $manager_patron_ids{ $offset_accountline->manager_id } = 1
                if $offset_accountline && $offset_accountline->manager_id;
        }
    }

    $template->param(
        accountline                 => $accountline,
        account_offsets             => $account_offsets,
        additional_field_values     => $accountline->get_additional_field_values_for_template,
        available_additional_fields => Koha::AdditionalFields->search(
            { tablename => $accountline->credit_type_code ? 'accountlines:credit' : 'accountlines:debit' }
        ),
        finesview => 1,
    );

    $patron = Koha::Patrons->find( $accountline->borrowernumber );
    $template->param( patron => $patron );
}

my $extra_options;
if ( $disclosure_enabled && $patron ) {
    my %classes_by_patron = (
        $patron->id => {
            map { $_ => 1 } (
                @{ Koha::Patron::Disclosure->staff_sidebar_data_classes( { logged_in_user => $logged_in_user } ) },
                @{ Koha::Patron::Disclosure->staff_toolbar_data_classes( { logged_in_user => $logged_in_user } ) },
                qw( circulation_current circulation_history financial )
            )
        },
    );

    for my $manager_id ( sort { $a <=> $b } keys %manager_patron_ids ) {
        my $manager = Koha::Patrons->find($manager_id);
        next unless $manager;

        my $data_class =
               $logged_in_user
            && $logged_in_user->can_see_patron_infos($manager)
            && !C4::Context->preference('HidePatronName') ? 'identity' : 'profile';
        $classes_by_patron{$manager_id}->{$data_class} = 1;
    }

    my @subjects = map {
        {
            patron_id    => $_,
            data_classes => [ sort keys %{ $classes_by_patron{$_} } ],
        }
    } sort { $a <=> $b } keys %classes_by_patron;

    $extra_options = {
        patron_disclosure => {
            surface  => 'patrons.account.line_details',
            subjects => \@subjects,
        }
    };
}

output_html_with_http_headers( $input, $cookie, $template->output, undef, $extra_options );
