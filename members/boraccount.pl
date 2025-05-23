#!/usr/bin/perl

#written 11/1/2000 by chris@katipo.oc.nz
#script to display borrowers account details

# Copyright 2000-2002 Katipo Communications
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
use URI::Escape qw( uri_unescape );

use C4::Auth   qw( get_template_and_user );
use C4::Output qw( output_and_exit_if_error output_and_exit output_html_with_http_headers );
use CGI        qw ( -utf8 );
use C4::Members;
use C4::Accounts;
use C4::Letters;
use Koha::Cash::Registers;
use Koha::Patrons;
use Koha::Patron::Categories;
use Koha::Items;
use Koha::Token;

my $input = CGI->new;

my ( $template, $loggedinuser, $cookie ) = get_template_and_user(
    {
        template_name => "members/boraccount.tt",
        query         => $input,
        type          => "intranet",
        flagsrequired => {
            borrowers     => 'edit_borrowers',
            updatecharges => 'remaining_permissions'
        },
    }
);

my $schema         = Koha::Database->new->schema;
my $borrowernumber = $input->param('borrowernumber');
my $payment_id     = $input->param('payment_id');
my $change_given   = $input->param('change_given');
my $op             = $input->param('op') || '';
my @renew_results  = $input->multi_param('renew_result');

my $logged_in_user = Koha::Patrons->find($loggedinuser);
my $library_id     = C4::Context->userenv->{'branch'};
my $patron         = Koha::Patrons->find($borrowernumber);
unless ($patron) {
    print $input->redirect("/cgi-bin/koha/circ/circulation.pl?borrowernumber=$borrowernumber");
    exit;
}

output_and_exit_if_error(
    $input, $cookie, $template,
    { module => 'members', logged_in_user => $logged_in_user, current_patron => $patron }
);

my $registerid = $input->param('registerid');

if ( $op eq 'cud-void' ) {
    output_and_exit_if_error( $input, $cookie, $template, { check => 'csrf_token' } );
    my $payment_id = scalar $input->param('accountlines_id');
    my $payment    = Koha::Account::Lines->find($payment_id);
    my $note       = scalar $input->param('void_note');
    $payment->void(
        {
            branch    => $library_id,
            staff_id  => $logged_in_user->id,
            interface => 'intranet',
            note      => $note
        }
    );
}

if ( $op eq 'cud-payout' ) {
    output_and_exit_if_error( $input, $cookie, $template, { check => 'csrf_token' } );
    my $payment_id  = scalar $input->param('accountlines_id');
    my $payment     = Koha::Account::Lines->find($payment_id);
    my $amount      = scalar $input->param('amount');
    my $payout_type = scalar $input->param('payout_type');
    my $note        = scalar $input->param('payout_note');
    if ( $payment_id eq "" ) {
        $schema->txn_do(
            sub {
                $patron->account->payout_amount(
                    {
                        payout_type   => $payout_type,
                        branch        => $library_id,
                        staff_id      => $logged_in_user->id,
                        cash_register => $registerid,
                        interface     => 'intranet',
                        amount        => $amount,
                    }
                );
            }
        );
    } else {
        my $payment = Koha::Account::Lines->find($payment_id);
        $schema->txn_do(
            sub {
                my $payout = $payment->payout(
                    {
                        payout_type   => $payout_type,
                        branch        => $library_id,
                        staff_id      => $logged_in_user->id,
                        cash_register => $registerid,
                        interface     => 'intranet',
                        amount        => $amount,
                        note          => $note
                    }
                );
            }
        );
    }
}

if ( $op eq 'cud-refund' ) {
    output_and_exit_if_error( $input, $cookie, $template, { check => 'csrf_token' } );
    my $charge_id   = scalar $input->param('accountlines_id');
    my $charge      = Koha::Account::Lines->find($charge_id);
    my $amount      = scalar $input->param('amount');
    my $refund_type = scalar $input->param('refund_type');
    my $note        = scalar $input->param('refund_note');

    $schema->txn_do(
        sub {

            my $refund = $charge->reduce(
                {
                    reduction_type => 'REFUND',
                    branch         => $library_id,
                    staff_id       => $logged_in_user->id,
                    interface      => 'intranet',
                    amount         => $amount,
                    note           => $note
                }
            );
            unless ( $refund_type eq 'AC' ) {
                my $payout = $refund->payout(
                    {
                        payout_type   => $refund_type,
                        branch        => $library_id,
                        staff_id      => $logged_in_user->id,
                        cash_register => $registerid,
                        interface     => 'intranet',
                        amount        => $amount,
                        note          => $note
                    }
                );
            }
        }
    );
}

if ( $op eq 'cud-discount' ) {
    output_and_exit_if_error( $input, $cookie, $template, { check => 'csrf_token' } );
    my $charge_id = scalar $input->param('accountlines_id');
    my $charge    = Koha::Account::Lines->find($charge_id);
    my $amount    = scalar $input->param('amount');
    my $note      = scalar $input->param('apply_discount_note');

    $schema->txn_do(
        sub {

            my $discount = $charge->reduce(
                {
                    reduction_type => 'DISCOUNT',
                    branch         => $library_id,
                    staff_id       => $logged_in_user->id,
                    interface      => 'intranet',
                    amount         => $amount,
                    note           => $note,
                }
            );
        }
    );
}

my $receipt_sent = 0;
if ( $op eq 'cud-send_receipt' ) {
    my $credit_id      = scalar $input->param('accountlines_id');
    my $credit         = Koha::Account::Lines->find($credit_id);
    my @credit_offsets = $credit->credit_offsets( { type => 'APPLY' } )->as_list;
    if (
        my $letter = C4::Letters::GetPreparedLetter(
            module                 => 'circulation',
            letter_code            => uc( "ACCOUNT_" . $credit->credit_type_code ),
            message_transport_type => 'email',
            lang                   => $patron->lang,
            tables                 => {
                borrowers => $patron->borrowernumber,
                branches  => C4::Context::mybranch,
            },
            substitute => {
                credit  => $credit,
                offsets => \@credit_offsets,
            },
        )
        )
    {
        my $message_id = C4::Letters::EnqueueLetter(
            {
                letter                 => $letter,
                borrowernumber         => $patron->borrowernumber,
                message_transport_type => 'email',
            }
        );
        C4::Letters::SendQueuedMessages( { message_id => $message_id } ) if $message_id;
        $receipt_sent = $message_id ? 1 : -1;
    } else {
        $receipt_sent = -1;
    }
}

if ( $op eq 'cud-edit_note' ) {

    output_and_exit_if_error( $input, $cookie, $template, { check => 'csrf_token' } );

    my $payment_id = scalar $input->param('accountlines_id');
    my $note       = scalar $input->param('edited_note');

    my $payment = Koha::Account::Lines->find($payment_id);

    $schema->txn_do(
        sub {
            # Update the note and date in the account line
            $payment->set(
                {
                    date => \'NOW()',
                    note => $note
                }
            )->store();
        }
    );
}

#get account details
my $total = $patron->account->balance;

my $accountlines = Koha::Account::Lines->search(
    { borrowernumber => $patron->borrowernumber },
    { order_by       => { -desc => 'accountlines_id' } }
);

my $totalcredit;
if ( $total <= 0 ) {
    $totalcredit = 1;
}

# Populate an arrayref with everything we need to display any
# renew errors that occurred based on what we were passed
my $renew_results_display = [];
foreach my $renew_result (@renew_results) {
    my ( $itemnumber, $success, $info ) = split( /,/, $renew_result );
    my $item = Koha::Items->find($itemnumber);
    if ($success) {
        $info = uri_unescape($info);
    }
    push @{$renew_results_display}, {
        item    => $item,
        success => $success,
        info    => $info
    };
}

$template->param(
    patron        => $patron,
    finesview     => 1,
    total         => sprintf( "%.2f", $total ),
    totalcredit   => $totalcredit,
    accounts      => $accountlines,
    payment_id    => $payment_id,
    change_given  => $change_given,
    renew_results => $renew_results_display,
    receipt_sent  => $receipt_sent,
);

output_html_with_http_headers $input, $cookie, $template->output;
