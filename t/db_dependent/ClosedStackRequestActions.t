#!/usr/bin/perl

# Copyright 2026 Koha Development team
# This file is part of Koha.
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/>.

use Modern::Perl;
use Test::More;
use Test::NoWarnings 'had_no_warnings';
use Test::MockModule;
use Test::MockObject;
use FindBin qw( $Bin );
use CGI;

use C4::Auth;
use C4::Output;
use Koha::Database;
use Koha::Holds;
use t::lib::Mocks;
use t::lib::TestBuilder;

# All fixtures and state changes use the same disposable transaction.
my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;
$schema->storage->txn_begin;

my $indexer = Test::MockModule->new('Koha::SearchEngine::Indexer');
$indexer->mock( index_records => sub { return; } );
t::lib::Mocks::mock_preference( 'EnableClosedStackRequests', 1 );
t::lib::Mocks::mock_preference( 'IndependentBranches',       1 );
t::lib::Mocks::mock_preference( 'AllowHoldsOnDamagedItems',  0 );
t::lib::Mocks::mock_preference( 'RealTimeHoldsQueue',        0 );
t::lib::Mocks::mock_preference( 'HoldsLog',                  0 );

my $home  = $builder->build_object( { class => 'Koha::Libraries' } );
my $other = $builder->build_object( { class => 'Koha::Libraries' } );
my $actor = $builder->build_object( { class => 'Koha::Patrons',   value => { branchcode => $home->id, flags => 0 } } );
my $itype = $builder->build_object( { class => 'Koha::ItemTypes', value => { notforloan => 0 } } );
t::lib::Mocks::mock_userenv( { patron => $actor, branchcode => $home->id } );
ok( C4::Context->only_my_library, 'The non-superlibrarian has an active library restriction' );

my $auth     = Test::MockModule->new('C4::Auth');
my $output   = Test::MockModule->new('C4::Output');
my $letters  = Test::MockModule->new('C4::Letters');
my $cgi_mock = Test::MockModule->new('CGI');
my $i18n     = Test::MockModule->new('Koha::I18N');
$i18n->mock( '__' => sub { return $_[0]; } );
my ( $response, $letter_calls );
my $template = Test::MockObject->new;
$template->mock( param  => sub { return; } );
$template->mock( output => sub { return 'Rendered CSR response'; } );
$auth->mock( get_template_and_user => sub { return ( $template, $actor->id, undef ); } );
$output->mock( output_error                  => sub { $response = $_[1]; die "CSR response boundary\n"; } );
$output->mock( output_html_with_http_headers => sub { $response = 200;   die "CSR response boundary\n"; } );
$letters->mock(
    GetPreparedLetter => sub {
        $letter_calls++;
        return { content => 'Closed stack retrieval slip', is_html => 0 };
    }
);

sub make_hold {
    my ( $library, $flag ) = @_;
    my $bib  = $builder->build_object( { class => 'Koha::Biblioitems', value => { itemtype => $itype->id } } );
    my $item = $builder->build_object(
        {
            class => 'Koha::Items',
            value => {
                biblionumber    => $bib->biblionumber, biblioitemnumber => $bib->biblioitemnumber,
                homebranch      => $library->id,       holdingbranch    => $library->id, itype     => $itype->id,
                is_closed_stack => $flag,              itemlost         => 0,            withdrawn => 0, damaged => 0,
                notforloan      => 0,                  onloan           => undef,        more_subfields_xml => undef,
            },
        }
    );
    return $builder->build_object(
        {
            class => 'Koha::Holds',
            value => {
                biblionumber     => $item->biblionumber, itemnumber => $item->id,
                borrowernumber   => $actor->id,          branchcode => $library->id,
                priority         => 1,            found          => undef, suspend       => 0, suspend_until => undef,
                reservedate      => '2026-01-01', expirationdate => undef, waitingdate   => undef,
                cancellationdate => undef,        itemtype       => undef, item_group_id => undef,
                item_level_hold  => 1,            closed_stack_request_slip_printed => 0,
            },
        }
    );
}

for my $op ( 'cud-print_slip', 'cud-cancel_reserve' ) {
    subtest "$op stays inside the authorized closed stack queue" => sub {
        for my $case ( 'ordinary', 'other_library', 'missing', 'eligible' ) {
            my $hold =
                $case eq 'missing'
                ? undef
                : make_hold( $case eq 'other_library' ? $other : $home, $case eq 'ordinary' ? 0 : 1 );
            my $id  = $hold ? $hold->id : 0;
            my $cgi = CGI->new( { op => $op, reserve_id => $id } );
            $cgi_mock->mock( new => sub { return $cgi; } );
            ( $response, $letter_calls ) = ( undef, 0 );
            do "$Bin/../../circ/closed-stack-requests.pl";
            is( $@,        "CSR response boundary\n",       "$case reaches the expected response boundary" );
            is( $response, $case eq 'eligible' ? 200 : 404, "$case receives the correct status" );

            if ( $case ne 'eligible' ) {
                is( $letter_calls, 0, "$case never prepares another hold's slip" );
                if ($hold) {
                    my $stored = Koha::Holds->find($id);
                    ok( $stored, "$case hold remains present" );
                    is( $stored->closed_stack_request_slip_printed, 0, "$case printed state remains unchanged" )
                        if $stored;
                }
            } elsif ( $op eq 'cud-print_slip' ) {
                is( $letter_calls, 1, 'An authorized request prepares one slip' );
                is(
                    Koha::Holds->find($id)->closed_stack_request_slip_printed, 1,
                    'The authorized slip is marked printed'
                );
            } else {
                ok( !Koha::Holds->find($id), 'The authorized request can still be cancelled' );
            }
            $cgi_mock->unmock('new');
        }
    };
}

$schema->storage->txn_rollback;
had_no_warnings;
done_testing;
