#!/usr/bin/env perl

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
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use CGI::Compile;
use CGI::Emulate::PSGI;
use FindBin;
use HTTP::Request::Common qw( GET POST );
use JSON                  qw( decode_json );
use Plack::Builder;
use Plack::Test;
use Test::MockModule;
use Test::More;
use URI;

use t::lib::Mocks;
use t::lib::TestBuilder;

use C4::Auth;
use Koha::Account::Line;
use Koha::ActionLog;
use Koha::ActionLogs;
use Koha::Biblio;
use Koha::Database;
use Koha::Logger;
use Koha::Patron::Disclosure;
use Koha::Patron::Relationships;
use Koha::Patron::Restrictions;
use Koha::Subscription;
use Koha::Subscriptions;
use Koha::Token;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

{
    package Test::PatronDisclosureCGI::Logger;

    sub new {
        return bless { debug => [], error => [], info => [], warn => [] }, shift;
    }

    sub debug {
        my ( $self, $message ) = @_;
        push @{ $self->{debug} }, ref($message) eq 'CODE' ? $message->() : $message;
        return;
    }

    sub error {
        my ( $self, $message ) = @_;
        push @{ $self->{error} }, $message;
        return;
    }

    sub info {
        my ( $self, $message ) = @_;
        push @{ $self->{info} }, ref($message) eq 'CODE' ? $message->() : $message;
        return;
    }

    sub warn {
        my ( $self, $message ) = @_;
        push @{ $self->{warn} }, ref($message) eq 'CODE' ? $message->() : $message;
        return;
    }
}

my $logger      = Test::PatronDisclosureCGI::Logger->new;
my $logger_mock = Test::MockModule->new('Koha::Logger');
$logger_mock->redefine( get => sub { return $logger } );

$schema->storage->txn_begin;

# This test owns an outer DB transaction; file sessions keep CGI::Session from
# committing that same handle during session teardown.
t::lib::Mocks::mock_preference( 'SessionStorage',                         'file' );
t::lib::Mocks::mock_preference( 'SessionRestrictionByIP',                 0 );
t::lib::Mocks::mock_preference( 'TwoFactorAuthentication',                'disabled' );
t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureMaxSubjects',   1000 );
t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog',           1 );
t::lib::Mocks::mock_preference( 'SMSSendDriver',                          q{} );
t::lib::Mocks::mock_preference( 'ChildNeedsGuarantor',                    0 );
t::lib::Mocks::mock_preference( 'ExtendedPatronAttributes',               0 );
t::lib::Mocks::mock_preference( 'EnhancedMessagingPreferences',           0 );
t::lib::Mocks::mock_preference( 'IndependentBranches',                    0 );

my $fixture_suffix = $$ % 100_000;
my $library        = $builder->build_object(
    {
        class => 'Koha::Libraries',
        value => {
            branchcode => sprintf( 'P%05d', $fixture_suffix ),
            branchname => 'Patron disclosure CGI test library',
        },
    }
);
my $staff_category = $builder->build_object(
    {
        class => 'Koha::Patron::Categories',
        value => {
            categorycode         => sprintf( 'PS%05d', $fixture_suffix ),
            description          => 'Patron disclosure CGI staff',
            category_type        => 'S',
            enrolmentperiod      => 12,
            enrolmentperioddate  => undef,
            password_expiry_days => undef,
            upperagelimit        => undef,
            dateofbirthrequired  => undef,
            can_be_guarantee    => 0,
            reset_password      => 0,
            change_password     => 0,
        },
    }
);
my $patron_category = $builder->build_object(
    {
        class => 'Koha::Patron::Categories',
        value => {
            categorycode         => sprintf( 'PA%05d', $fixture_suffix ),
            description          => 'Patron disclosure CGI adult',
            category_type        => 'A',
            enrolmentperiod      => 12,
            enrolmentperioddate  => undef,
            password_expiry_days => undef,
            upperagelimit        => undef,
            dateofbirthrequired  => undef,
            can_be_guarantee    => 0,
            reset_password      => 0,
            change_password     => 0,
        },
    }
);

my $actor = $builder->build_object(
    {
        class => 'Koha::Patrons',
        value => {
            branchcode                  => $library->id,
            categorycode                => $staff_category->id,
            cardnumber                  => "PDCGI-STAFF-$fixture_suffix",
            userid                      => "pdcgi_staff_$fixture_suffix",
            surname                     => 'CGI audit staff',
            firstname                   => 'Synthetic',
            flags                       => 1,
            protected                   => 0,
            gonenoaddress               => 0,
            lost                        => 0,
            privacy                     => 1,
            privacy_guarantor_checkouts => 0,
            privacy_guarantor_fines     => 0,
            anonymized                  => 0,
            login_attempts              => 0,
            dateexpiry                  => '2099-12-31',
            password_expiration_date    => undef,
            debarred                    => undef,
            debarredcomment             => undef,
            auth_method                 => 'password',
            checkprevcheckout           => 'inherit',
            autorenew_checkouts         => 1,
            lang                        => 'default',
        },
    }
);
my $patron = $builder->build_object(
    {
        class => 'Koha::Patrons',
        value => {
            branchcode                  => $library->id,
            categorycode                => $patron_category->id,
            cardnumber                  => "PDCGI-PATRON-$fixture_suffix",
            userid                      => "pdcgi_patron_$fixture_suffix",
            surname                     => 'PRIVATE_CGI_PATRON_SENTINEL',
            firstname                   => 'Synthetic',
            email                       => 'original@example.invalid',
            flags                       => 0,
            protected                   => 0,
            gonenoaddress               => 0,
            lost                        => 0,
            privacy                     => 1,
            privacy_guarantor_checkouts => 0,
            privacy_guarantor_fines     => 0,
            anonymized                  => 0,
            login_attempts              => 0,
            dateexpiry                  => '2099-12-31',
            password_expiration_date    => undef,
            debarred                    => undef,
            debarredcomment             => undef,
            auth_method                 => 'password',
            checkprevcheckout           => 'inherit',
            autorenew_checkouts         => 1,
            lang                        => 'default',
        },
    }
);

is( $actor->is_superlibrarian, 1, 'the synthetic staff session has permission for both CGI scripts' );
is( $patron->restrictions->count, 0, 'the target starts without restrictions' );
is( $patron->guarantor_relationships->count, 0, 'the target starts without guarantor relationships' );
is( $patron->alert_subscriptions->count, 0, 'the target starts without alert subscriptions' );

my $session = C4::Auth::create_basic_session( { patron => $actor, interface => 'intranet' } );
$session->param( 'ip',          '127.0.0.1' );
$session->param( 'sessiontype', 'staff' );
$session->flush;
my $csrf_token = Koha::Token->new->generate_csrf( { session_id => $session->id } );
ok( $csrf_token, 'the authenticated session has a CSRF token' );

my %test_clients;

sub test_client_for {
    my ($script) = @_;

    return $test_clients{$script} if $test_clients{$script};

    my $runner = CGI::Compile->new( return_exit_val => 1 )->compile("$FindBin::Bin/../../$script");
    my $cgi_app = CGI::Emulate::PSGI->handler($runner);
    my $app     = builder {
        enable '+Koha::Middleware::CSRF';
        $cgi_app;
    };

    return $test_clients{$script} = Plack::Test->create($app);
}

sub request_cgi {
    my ( $script, $method, $params ) = @_;

    $params = {%$params};
    my $uri = URI->new("http://localhost/$script");
    my $request;
    if ( $method eq 'POST' ) {
        $params->{csrf_token} = $csrf_token unless exists $params->{csrf_token};
        $request = POST $uri, Content => [ map { $_ => $params->{$_} } sort keys %{$params} ];
        $request->header( Referer => "http://localhost/$script" );
    } else {
        $uri->query_form(%{$params});
        $request = GET $uri;
    }
    $request->header( Cookie => 'CGISESSID=' . $session->id );

    return test_client_for($script)->request($request);
}

sub disclosure_logs {
    return Koha::ActionLogs->search(
        {
            module => Koha::Patron::Disclosure::MODULE,
            action => Koha::Patron::Disclosure::ACTION,
            user   => $actor->id,
        },
        { order_by => 'action_id' }
    );
}

sub clear_disclosure_logs {
    disclosure_logs()->delete;
    return;
}

sub assert_audited_patron_response {
    my ( $response, $surface, $name ) = @_;

    is( $response->code, 200, "$name returns a successful response" );
    like( $response->content, qr/PRIVATE_CGI_PATRON_SENTINEL/, "$name renders the synthetic patron PII" );

    my @rows = disclosure_logs()->as_list;
    is( scalar @rows, 1, "$name writes one disclosure row" );
    is( 0 + $rows[0]->object, $patron->id, "$name audits the represented patron" );
    is( 0 + $rows[0]->user,   $actor->id,  "$name audits the authenticated staff actor" );

    my $info = decode_json( $rows[0]->info );
    is( $info->{surface},     $surface,   "$name records the CGI surface" );
    is( $info->{auth_source}, 'session',  "$name records session authentication" );
    return;
}

sub invalid_memberentry_form {
    my (%extra) = @_;

    return {
        op                         => 'cud-save',
        borrowernumber             => $patron->id,
        categorycode               => $patron_category->id,
        branchcode                 => $library->id,
        cardnumber                 => $patron->cardnumber,
        userid                     => $patron->userid,
        surname                    => $patron->surname,
        firstname                  => $patron->firstname,
        email                      => 'not-an-email',
        password                   => q{},
        password2                  => q{},
        contactname                => q{},
        contactfirstname           => q{},
        new_guarantor_id           => q{},
        new_guarantor_relationship => q{},
        step                       => 1,
        %extra,
    };
}

sub next_missing_id {
    my ( $resultset_class, $column ) = @_;

    my ($highest) = $resultset_class->search( {}, { order_by => { -desc => $column }, rows => 1 } )
        ->get_column($column);
    my $missing = ( $highest // 0 ) + 1;
    $missing++ while $resultset_class->find($missing);
    return $missing;
}

my $inject_disclosure_store_failure = 0;
my $real_action_log_store            = Koha::ActionLog->can('store');
my $action_log_mock                  = Test::MockModule->new('Koha::ActionLog');
$action_log_mock->mock(
    store => sub {
        my ( $self, @args ) = @_;
        die "injected patron disclosure audit failure\n"
            if $inject_disclosure_store_failure
            && $self->module eq Koha::Patron::Disclosure::MODULE;
        return $real_action_log_store->( $self, @args );
    }
);

subtest 'alert subscriptions read and unknown valid POST operations are audited' => sub {
    clear_disclosure_logs();
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 1 );

    my $response = request_cgi(
        'members/alert-subscriptions.pl', 'GET',
        { borrowernumber => $patron->id }
    );
    assert_audited_patron_response( $response, 'patrons.alerts.list', 'the normal alert-subscriptions read' );

    clear_disclosure_logs();
    my @csrf_warnings;
    {
        local $SIG{__WARN__} = sub { push @csrf_warnings, @_ };
        $response = request_cgi(
            'members/alert-subscriptions.pl', 'POST',
            {
                borrowernumber => $patron->id,
                op             => 'cud-future-operation',
                csrf_token     => 'invalid-token',
            }
        );
    }
    is( $response->code, 403, 'the real CSRF middleware rejects the same POST with an invalid token' );
    like( join( q{}, @csrf_warnings ), qr/wrong_csrf_token/, 'the rejection came from CSRF token validation' );
    unlike( $response->content, qr/PRIVATE_CGI_PATRON_SENTINEL/, 'the rejected POST discloses no patron PII' );
    is( disclosure_logs()->count, 0, 'the rejected POST writes no disclosure row' );

    clear_disclosure_logs();
    $response = request_cgi(
        'members/alert-subscriptions.pl', 'POST',
        {
            borrowernumber => $patron->id,
            op             => 'cud-future-operation',
        }
    );
    assert_audited_patron_response(
        $response, 'patrons.alerts.list',
        'the authenticated and CSRF-valid unknown cud operation'
    );

    done_testing;
};

subtest 'disabled disclosure logging leaves the alert response unchanged' => sub {
    clear_disclosure_logs();
    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 0 );

    my $response = request_cgi(
        'members/alert-subscriptions.pl', 'POST',
        {
            borrowernumber => $patron->id,
            op             => 'cud-future-operation',
        }
    );
    is( $response->code, 200, 'the disabled valid POST remains successful' );
    like( $response->content, qr/PRIVATE_CGI_PATRON_SENTINEL/, 'the disabled response body is unchanged' );
    is( disclosure_logs()->count, 0, 'the disabled response writes no disclosure row' );

    t::lib::Mocks::mock_preference( 'StaffPatronDataDisclosureLog', 1 );
    done_testing;
};

subtest 'an actual unsubscribe mutation redirects and terminates its body without audit' => sub {
    clear_disclosure_logs();
    my $biblio       = Koha::Biblio->new( { title => 'Synthetic alert subscription' } )->store;
    my $subscription = Koha::Subscription->new( { biblionumber => $biblio->id } )->store;
    $subscription->add_subscriber($patron);
    is( $subscription->subscribers->search( { borrowernumber => $patron->id } )->count, 1, 'the fixture is subscribed' );

    my $response = request_cgi(
        'members/alert-subscriptions.pl', 'POST',
        {
            borrowernumber  => $patron->id,
            op              => 'cud-unsubscribe',
            subscription_id => $subscription->id,
        }
    );
    is( $response->code, 302, 'the actual unsubscribe returns a redirect' );
    is(
        $response->header('Location'),
        '/cgi-bin/koha/members/alert-subscriptions.pl?borrowernumber=' . $patron->id,
        'the mutation redirects to the patron alert list'
    );
    is( $response->content, q{}, 'exit prevents a patron-bearing template body after the redirect' );
    is( $subscription->subscribers->search( { borrowernumber => $patron->id } )->count, 0, 'the unsubscribe took effect' );
    is( disclosure_logs()->count, 0, 'the actual-effect mutation response remains deliberately unaudited' );

    done_testing;
};

subtest 'account-note no-op is audited while a real note change remains deferred' => sub {
    my $account_line = Koha::Account::Line->new(
        {
            borrowernumber    => $patron->id,
            amount            => 7,
            amountoutstanding => 7,
            description       => 'Synthetic CGI account line',
            credit_type_code  => undef,
            debit_type_code   => 'OVERDUE',
            status            => undef,
            payment_type      => undef,
            note              => 'UNCHANGED_ACCOUNT_NOTE',
            manager_id        => $actor->id,
            register_id       => undef,
            issue_id          => undef,
            old_issue_id      => undef,
            itemnumber        => undef,
            interface         => 'intranet',
            branchcode        => $library->id,
        }
    )->store;

    clear_disclosure_logs();
    my $row_before = $account_line->get_from_storage->unblessed;
    my $response   = request_cgi(
        'members/boraccount.pl', 'POST',
        {
            borrowernumber  => $patron->id,
            op              => 'cud-edit_note',
            accountlines_id => $account_line->id,
            edited_note     => 'UNCHANGED_ACCOUNT_NOTE',
        }
    );
    my $row_after = $account_line->get_from_storage->unblessed;
    is_deeply( $row_after, $row_before, 'the same-note POST leaves the entire account line unchanged' );
    assert_audited_patron_response(
        $response, 'patrons.account.transactions',
        'the authenticated and CSRF-valid same-note edit'
    );

    clear_disclosure_logs();
    $response = request_cgi(
        'members/boraccount.pl', 'POST',
        {
            borrowernumber  => $patron->id,
            op              => 'cud-edit_note',
            accountlines_id => $account_line->id,
            edited_note     => 'CHANGED_ACCOUNT_NOTE',
        }
    );
    is( $response->code, 200, 'the real note change renders its normal response' );
    like( $response->content, qr/PRIVATE_CGI_PATRON_SENTINEL/, 'the real note-change response renders the patron' );
    is( $account_line->get_from_storage->note, 'CHANGED_ACCOUNT_NOTE', 'the real note change took effect' );
    is( disclosure_logs()->count, 0, 'the actual-effect note mutation remains deliberately unaudited' );

    done_testing;
};

subtest 'member entry edit and no-op mutation attempts redisplay through the audit boundary' => sub {
    clear_disclosure_logs();
    my $response = request_cgi(
        'members/memberentry.pl', 'GET',
        {
            borrowernumber => $patron->id,
            op             => 'edit_form',
            step           => 1,
        }
    );
    assert_audited_patron_response( $response, 'patrons.record.edit', 'the normal member-entry edit form' );

    my $missing_restriction_id = next_missing_id( 'Koha::Patron::Restrictions', 'borrower_debarment_id' );
    ok( !Koha::Patron::Restrictions->find($missing_restriction_id), 'the requested restriction does not exist' );
    clear_disclosure_logs();
    $response = request_cgi(
        'members/memberentry.pl', 'POST',
        invalid_memberentry_form( remove_debarment => $missing_restriction_id )
    );
    assert_audited_patron_response(
        $response, 'patrons.record.edit',
        'the failed edit with a missing debarment deletion'
    );
    is( $patron->restrictions->count, 0, 'the missing debarment request changed no restriction' );
    is( $patron->get_from_storage->email, 'original@example.invalid', 'the invalid edit changed no patron data' );

    my $missing_relationship_id = next_missing_id( 'Koha::Patron::Relationships', 'id' );
    ok( !Koha::Patron::Relationships->find($missing_relationship_id), 'the requested guarantor relationship does not exist' );
    clear_disclosure_logs();
    $response = request_cgi(
        'members/memberentry.pl', 'POST',
        invalid_memberentry_form( delete_guarantor => $missing_relationship_id )
    );
    assert_audited_patron_response(
        $response, 'patrons.record.edit',
        'the failed edit with a missing guarantor relationship deletion'
    );
    is( $patron->guarantor_relationships->count, 0, 'the missing relationship request deleted nothing' );
    is( $patron->get_from_storage->email, 'original@example.invalid', 'the second invalid edit changed no patron data' );

    done_testing;
};

subtest 'a covered CGI read fails closed when the real audit write fails' => sub {
    clear_disclosure_logs();
    @{ $logger->{error} } = ();
    $inject_disclosure_store_failure = 1;

    my $response = request_cgi(
        'members/alert-subscriptions.pl', 'GET',
        { borrowernumber => $patron->id }
    );

    $inject_disclosure_store_failure = 0;
    is( $response->code, 503, 'the covered CGI response fails closed' );
    like( $response->content, qr/Service unavailable/, 'the replacement body is generic' );
    unlike( $response->as_string, qr/PRIVATE_CGI_PATRON_SENTINEL/, 'the replacement response contains no patron sentinel' );
    is( disclosure_logs()->count, 0, 'the failed audit transaction leaves no partial disclosure row' );
    is_deeply(
        $logger->{error},
        ['Patron disclosure audit failed for surface patrons.alerts.list (reason=DBIx::Class::Exception)'],
        'the failure log contains the surface but no actor or patron data'
    );

    done_testing;
};

$session->delete;
$session->flush;
$schema->storage->txn_rollback;

done_testing;
