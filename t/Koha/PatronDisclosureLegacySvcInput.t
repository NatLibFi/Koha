#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use FindBin;
use Test::MockModule;
use Test::More;

use CGI ();
use C4::Auth ();
use C4::Context;
use Koha::Holds;
use Koha::ItemTypes;
use Koha::Patron::Disclosure;
use Koha::Patrons;

{

    package Test::PatronDisclosure::Session;

    sub new {
        return bless {}, shift;
    }

    sub param {
        my ( $self, $name ) = @_;
        return 'staff-user' if $name eq 'id';
        return;
    }
}

{

    package Test::PatronDisclosure::EmptyItemTypes;

    sub new {
        return bless {}, shift;
    }

    sub unblessed {
        return [];
    }
}

{

    package Test::PatronDisclosure::PatronIds;

    sub new {
        my ( $class, $ids ) = @_;
        return bless { ids => $ids }, $class;
    }

    sub get_column {
        my ( $self, $column ) = @_;
        die "Unexpected column $column" unless $column eq 'borrowernumber';
        return @{ $self->{ids} };
    }
}

my $activity_query_calls = 0;
my $audit_event_calls    = 0;
my $patron_search_calls  = 0;
my $subject_limit        = 1;
my $patron_search_bad_parameter;
my $patron_search_result;

my $auth_mock = Test::MockModule->new('C4::Auth');
$auth_mock->redefine(
    check_cookie_auth => sub {
        return ( 'ok', Test::PatronDisclosure::Session->new );
    },
    haspermission => sub { return 1; },
);

my $context_mock = Test::MockModule->new('C4::Context');
$context_mock->redefine(
    preference => sub {
        my $name = $_[-1];
        return 1              if $name eq Koha::Patron::Disclosure::PREFERENCE;
        return $subject_limit if $name eq Koha::Patron::Disclosure::LIMIT_PREFERENCE;
        return 'asc'          if $name =~ /IssuesDefaultSortOrder\z/;
        return;
    },
    userenv => sub { return { branch => 'TEST' }; },
    dbh     => sub {
        $activity_query_calls++;
        die "activity query reached\n";
    },
);

my $patrons_mock = Test::MockModule->new('Koha::Patrons');
$patrons_mock->redefine(
    search => sub {
        $patron_search_calls++;
        Koha::Exceptions::BadParameter->throw( parameter => 'query_contract' )
            if $patron_search_bad_parameter;
        return Test::PatronDisclosure::PatronIds->new($patron_search_result)
            if defined $patron_search_result;
        die "patron existence query reached\n";
    }
);

my $disclosure_mock = Test::MockModule->new('Koha::Patron::Disclosure');
$disclosure_mock->redefine(
    new => sub {
        $audit_event_calls++;
        die "disclosure audit reached\n";
    }
);

my $holds_mock = Test::MockModule->new('Koha::Holds');
$holds_mock->redefine(
    search => sub {
        $activity_query_calls++;
        die "holds activity query reached\n";
    }
);

my $item_types_mock = Test::MockModule->new('Koha::ItemTypes');
$item_types_mock->redefine(
    search_with_localization => sub {
        return Test::PatronDisclosure::EmptyItemTypes->new;
    }
);

sub run_service {
    my ( $relative_path, $query_string ) = @_;

    local $ENV{REQUEST_METHOD} = 'GET';
    local $ENV{QUERY_STRING}   = $query_string;
    local $ENV{HTTP_COOKIE}    = 'CGISESSID=test-session';

    # CGI.pm caches its first no-argument request object for the process.
    # Each do() below represents an independent CGI request.
    CGI::initialize_globals();

    my $stdout = q{};
    open my $output, '>', \$stdout or die "Cannot open scalar output: $!";
    local *STDOUT = $output;

    my $error;
    {
        no warnings qw( once redefine );
        local *CORE::GLOBAL::exit = sub { die "TEST_SERVICE_EXIT\n" };
        do "$FindBin::Bin/../../$relative_path";
        $error = $@;
    }
    close $output;

    return ( $stdout, $error );
}

subtest 'checkout input failures precede patron existence and activity queries' => sub {
    $activity_query_calls        = 0;
    $audit_event_calls           = 0;
    $patron_search_calls         = 0;
    $subject_limit               = 1;
    $patron_search_bad_parameter = 0;
    $patron_search_result        = undef;

    my ( $stdout, $error ) = run_service( 'svc/checkouts', q{} );
    is( $error, q{}, 'missing checkout targets retain the successful empty-response path' );
    like( $stdout, qr/Status: 200 OK/, 'missing checkout targets return HTTP 200' );
    like( $stdout, qr/"aaData":\[\]/, 'missing checkout targets return no patron activity' );
    is( $patron_search_calls,  0, 'missing checkout targets reach no existence query' );
    is( $activity_query_calls, 0, 'missing checkout targets reach no activity query' );
    is( $audit_event_calls,    0, 'missing checkout targets create no disclosure event' );

    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=abc' );
    like( $error,  qr/TEST_SERVICE_EXIT/,                                 'invalid syntax terminates the service' );
    like( $stdout, qr/Status: 400 Bad Request/,                           'invalid syntax returns HTTP 400' );
    like( $stdout, qr/"error_code":"patron_disclosure_invalid_subjects"/, 'invalid syntax has a stable code' );
    unlike( $stdout, qr/abc|positive integer/, 'invalid syntax does not echo input or internal errors' );
    is( $patron_search_calls,  0, 'invalid syntax reaches no existence query' );
    is( $activity_query_calls, 0, 'invalid syntax reaches no activity query' );
    is( $audit_event_calls,    0, 'invalid syntax creates no disclosure event' );

    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=2147483648' );
    like( $stdout, qr/Status: 400 Bad Request/, 'an out-of-domain patron ID returns HTTP 400' );
    is( $patron_search_calls,  0, 'an out-of-domain ID reaches no existence query' );
    is( $activity_query_calls, 0, 'an out-of-domain ID reaches no activity query' );

    ( $stdout, $error ) = run_service( 'svc/checkouts', join( '&', ('borrowernumber=1') x 5 ) );
    like( $stdout, qr/Status: 400 Bad Request/, 'excessive repeated input returns HTTP 400' );
    is( $patron_search_calls,  0, 'raw-input rejection reaches no existence query' );
    is( $activity_query_calls, 0, 'raw-input rejection reaches no activity query' );

    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=1&borrowernumber=2' );
    like( $stdout, qr/Status: 400 Bad Request/, 'excessive unique input returns HTTP 400' );
    is( $patron_search_calls,  0, 'unique-subject rejection reaches no existence query' );
    is( $activity_query_calls, 0, 'unique-subject rejection reaches no activity query' );

    $subject_limit        = 2;
    $patron_search_result = [1];
    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=1&borrowernumber=2' );
    like( $stdout, qr/Status: 400 Bad Request/, 'mixed real and nonexistent targets return HTTP 400 together' );
    like( $stdout, qr/"error_code":"patron_disclosure_invalid_subjects"/, 'mixed targets have the input-error code' );
    is( $patron_search_calls,  1, 'mixed targets perform only the bounded existence query' );
    is( $activity_query_calls, 0, 'mixed-target rejection reaches no checkout activity query' );
    is( $audit_event_calls,    0, 'mixed-target rejection creates no partial disclosure event' );
    unlike(
        $stdout, qr/nonexistent|borrowernumber|["':]2\b/,
        'mixed-target rejection exposes no target or lookup detail'
    );

    $patron_search_result = undef;
    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=1' );
    like( $stdout, qr/Status: 503 Service Unavailable/, 'patron lookup failure returns HTTP 503' );
    like(
        $stdout,
        qr/"error_code":"patron_disclosure_subject_resolution_unavailable"/,
        'patron lookup failure has a stable operational-error code'
    );
    unlike( $stdout, qr/patron existence query reached/, 'patron lookup failure does not expose its exception' );
    is( $patron_search_calls,  2, 'patron lookup failure performs only the existence query' );
    is( $activity_query_calls, 0, 'patron lookup failure reaches no checkout activity query' );
    is( $audit_event_calls,    0, 'patron lookup failure creates no disclosure event' );

    $patron_search_bad_parameter = 1;
    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=1' );
    like(
        $stdout,
        qr/Status: 503 Service Unavailable/,
        'an unrelated BadParameter from patron lookup remains an operational HTTP 503'
    );
    unlike( $stdout, qr/query_contract/, 'an operational BadParameter exposes no internal parameter' );
    is( $patron_search_calls,  3, 'the operational BadParameter performs only the existence query' );
    is( $activity_query_calls, 0, 'the operational BadParameter reaches no checkout activity query' );
    $patron_search_bad_parameter = 0;

    $subject_limit = 'invalid';
    ( $stdout, $error ) = run_service( 'svc/checkouts', 'borrowernumber=1' );
    like( $stdout, qr/Status: 503 Service Unavailable/, 'invalid subject-limit configuration returns HTTP 503' );
    unlike( $stdout, qr/positive integer|invalid/, 'configuration failure does not expose its exception or value' );
    is( $patron_search_calls,  3, 'configuration failure precedes the patron existence query' );
    is( $activity_query_calls, 0, 'configuration failure reaches no checkout activity query' );
    is( $audit_event_calls,    0, 'configuration failure creates no disclosure event' );

    done_testing;
};

subtest 'single-patron service input failures precede activity queries' => sub {
    $activity_query_calls        = 0;
    $audit_event_calls           = 0;
    $patron_search_calls         = 0;
    $subject_limit               = 1;
    $patron_search_bad_parameter = 0;
    $patron_search_result        = undef;

    my ( $stdout, $error ) = run_service( 'svc/holds', 'borrowernumber=abc' );
    like( $stdout, qr/Status: 400 Bad Request/,            'holds rejects invalid syntax with HTTP 400' );
    like( $stdout, qr/patron_disclosure_invalid_subjects/, 'holds uses the stable input-error code' );
    is( $patron_search_calls,  0, 'holds rejection reaches no existence query' );
    is( $activity_query_calls, 0, 'holds rejection reaches no activity query' );

    ( $stdout, $error ) = run_service( 'svc/holds', q{} );
    like( $stdout, qr/Status: 400 Bad Request/, 'holds rejects a missing target with HTTP 400' );
    is( $patron_search_calls, 0, 'missing holds target reaches no existence query' );

    ( $stdout, $error ) = run_service( 'svc/holds', 'borrowernumber=1&borrowernumber=1' );
    like( $stdout, qr/Status: 400 Bad Request/, 'holds rejects duplicate identical targets with HTTP 400' );
    is( $patron_search_calls, 0, 'duplicate holds targets reach no existence query' );

    ( $stdout, $error ) = run_service( 'svc/holds', 'borrowernumber=1&borrowernumber=abc' );
    like( $stdout, qr/Status: 400 Bad Request/, 'holds rejects mixed raw targets with HTTP 400' );
    is( $patron_search_calls, 0, 'mixed holds targets reach no existence query' );
    is( $activity_query_calls, 0, 'all holds cardinality rejections precede activity SQL' );

    ( $stdout, $error ) = run_service( 'svc/return_claims', 'borrowernumber=abc' );
    like( $stdout, qr/Status: 400 Bad Request/,            'return claims rejects invalid syntax with HTTP 400' );
    like( $stdout, qr/patron_disclosure_invalid_subjects/, 'return claims uses the stable input-error code' );
    is( $patron_search_calls,  0, 'return-claims rejection reaches no existence query' );
    is( $activity_query_calls, 0, 'return-claims rejection reaches no activity query' );

    ( $stdout, $error ) = run_service( 'svc/return_claims', q{} );
    like( $stdout, qr/Status: 400 Bad Request/, 'return claims rejects a missing target with HTTP 400' );
    is( $patron_search_calls, 0, 'missing return-claims target reaches no existence query' );

    ( $stdout, $error ) = run_service( 'svc/return_claims', 'borrowernumber=1&borrowernumber=1' );
    like(
        $stdout,
        qr/Status: 400 Bad Request/,
        'return claims rejects duplicate identical targets with HTTP 400'
    );
    is( $patron_search_calls, 0, 'duplicate return-claims targets reach no existence query' );

    ( $stdout, $error ) = run_service( 'svc/return_claims', 'borrowernumber=1&borrowernumber=abc' );
    like( $stdout, qr/Status: 400 Bad Request/, 'return claims rejects mixed raw targets with HTTP 400' );
    is( $patron_search_calls, 0, 'mixed return-claims targets reach no existence query' );
    is( $activity_query_calls, 0, 'all return-claims cardinality rejections precede activity SQL' );

    $patron_search_result = [];
    ( $stdout, $error ) = run_service( 'svc/holds', 'borrowernumber=1' );
    like( $stdout, qr/Status: 400 Bad Request/, 'holds rejects a nonexistent target with HTTP 400' );
    is( $patron_search_calls,  1, 'the nonexistent target adds only one bounded existence query' );
    is( $activity_query_calls, 0, 'nonexistent-target rejection reaches no holds activity query' );

    ( $stdout, $error ) = run_service( 'svc/return_claims', 'borrowernumber=1' );
    like( $stdout, qr/Status: 400 Bad Request/, 'return claims rejects a nonexistent target with HTTP 400' );
    is( $patron_search_calls,  2, 'return-claims nonexistent target performs one bounded existence query' );
    is( $activity_query_calls, 0, 'return-claims nonexistent target reaches no activity query' );

    $patron_search_result = [1];
    ( $stdout, $error ) = run_service( 'svc/holds', 'borrowernumber=1' );
    like( $error, qr/holds activity query reached/, 'one valid holds target proceeds to its activity query' );
    is( $patron_search_calls,  3, 'one valid holds target performs its existence query' );
    is( $activity_query_calls, 1, 'one valid holds target reaches one activity query' );

    ( $stdout, $error ) = run_service( 'svc/return_claims', 'borrowernumber=1' );
    like( $error, qr/activity query reached/, 'one valid return-claims target proceeds to its activity query' );
    is( $patron_search_calls,  4, 'one valid return-claims target performs its existence query' );
    is( $activity_query_calls, 2, 'one valid return-claims target reaches one activity query' );
    is( $audit_event_calls,    0, 'rejected and pre-response valid controls create no disclosure event' );

    done_testing;
};

done_testing;
