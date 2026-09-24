#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use CGI qw( -utf8 );
use CGI::Cookie;
use Test::MockModule;
use Test::More;
use Test::NoWarnings qw( had_no_warnings );

use C4::Output qw( output_html_with_http_headers output_with_http_headers );
use Koha::Patron::Disclosure;

{

    package Test::Output::PatronDisclosureEvent;

    sub new {
        my ( $class, $params ) = @_;
        return bless {
            fail     => $params->{fail},
            subjects => [],
            commits  => 0,
        }, $class;
    }

    sub add_subject {
        my ( $self, $params ) = @_;
        push @{ $self->{subjects} }, $params;
        return $self;
    }

    sub commit {
        my ($self) = @_;
        $self->{commits}++;
        die "StaffPatronDataDisclosureMaxSubjects must be a positive integer\n" if $self->{fail};
        return 'server-event-id';
    }
}

{

    package Test::Output::Logger;

    sub new {
        return bless { errors => [] }, shift;
    }

    sub error {
        my ( $self, $message ) = @_;
        push @{ $self->{errors} }, $message;
        return;
    }
}

{

    package Test::Output::LoggedInUser;

    sub new {
        my ( $class, @permissions ) = @_;
        return bless { permissions => { map { $_ => 1 } @permissions } }, $class;
    }

    sub has_permission {
        my ( $self, $required ) = @_;
        my ($permission) = keys %{$required};
        return $self->{permissions}->{ $permission . ':' . $required->{$permission} } ? 1 : 0;
    }
}

my $enabled   = 1;
my $fail_next = 0;
my @events;
my $logger = Test::Output::Logger->new;
my %preferences;

my $context_mock = Test::MockModule->new('C4::Context');
$context_mock->redefine(
    preference => sub {
        my ( $class, $name ) = @_;
        return $enabled            if $name eq Koha::Patron::Disclosure::PREFERENCE;
        return $preferences{$name} if exists $preferences{$name};
        return q{}                 if $name eq 'AccessControlAllowOrigin';
        return;
    }
);
$context_mock->redefine( userenv => sub { return { number => 42 } } );

my $disclosure_mock = Test::MockModule->new('Koha::Patron::Disclosure');
$disclosure_mock->redefine(
    new => sub {
        my $event = Test::Output::PatronDisclosureEvent->new( { fail => $fail_next } );
        push @events, $event;
        return $event;
    }
);

my $logger_mock = Test::MockModule->new('Koha::Logger');
$logger_mock->redefine( get => sub { return $logger } );

sub render_output {
    my (%params) = @_;

    my $stdout = q{};
    open my $output, '>', \$stdout or die "Cannot open scalar output: $!";
    local *STDOUT = $output;

    output_html_with_http_headers(
        CGI->new,
        $params{cookie},
        $params{body},
        undef,
        { patron_disclosure => $params{descriptor} },
    );

    close $output;
    return $stdout;
}

sub render_json_output {
    my (%params) = @_;

    my $stdout = q{};
    open my $output, '>', \$stdout or die "Cannot open scalar output: $!";
    local *STDOUT = $output;

    output_with_http_headers(
        CGI->new,
        undef,
        $params{body},
        'json',
        undef,
        { patron_disclosure => $params{descriptor} },
    );

    close $output;
    return $stdout;
}

my $descriptor = {
    surface  => 'patrons.record.details',
    subjects => [
        { patron_id => 100, data_classes => [ 'identity', 'contact' ] },
        { patron_id => 101, data_classes => ['identity'] },
    ],
};

subtest 'staff sidebar classes follow its disclosure preferences' => sub {
    plan tests => 3;

    %preferences = ();
    is_deeply(
        Koha::Patron::Disclosure->staff_sidebar_data_classes,
        [qw( contact identity notes_restrictions profile security_administration )],
        'the default sidebar classifies its identity, contact, profile, restriction, and account state'
    );

    $preferences{HidePersonalPatronDetailOnCirculation} = 1;
    is_deeply(
        Koha::Patron::Disclosure->staff_sidebar_data_classes,
        [qw( identity notes_restrictions profile security_administration )],
        'hidden personal details remove the contact class'
    );

    %preferences = (
        HidePersonalPatronDetailOnCirculation => 1,
        patronimages                          => 1,
        ExtendedPatronAttributes              => 1,
        TrackLastPatronActivityTriggers       => 'check_out',
    );
    is_deeply(
        Koha::Patron::Disclosure->staff_sidebar_data_classes,
        [
            qw( documents_media extended_attributes identity notes_restrictions profile security_administration service_activity )
        ],
        'enabled sidebar features add their represented classes'
    );

    %preferences = ();
};

subtest 'staff component contributors follow rendered permission and preference branches' => sub {
    plan tests => 6;

    %preferences = ();
    my $serials_user = Test::Output::LoggedInUser->new('serials:*');
    is_deeply(
        Koha::Patron::Disclosure->staff_sidebar_data_classes( { logged_in_user => $serials_user } ),
        [qw( communications contact identity notes_restrictions profile security_administration )],
        'serials permission adds the alert-subscription state represented by the sidebar'
    );

    my $no_permissions = Test::Output::LoggedInUser->new;
    is_deeply(
        Koha::Patron::Disclosure->staff_toolbar_data_classes( { logged_in_user => $no_permissions } ),
        ['identity'],
        'a toolbar without conditional permissions represents only its patron identity'
    );

    my $editor = Test::Output::LoggedInUser->new(
        'borrowers:edit_borrowers',
        'borrowers:delete_borrowers',
    );
    is_deeply(
        Koha::Patron::Disclosure->staff_toolbar_data_classes( { logged_in_user => $editor } ),
        [qw( communications identity notes_restrictions profile security_administration )],
        'edit and delete controls represent messaging, patron state, and protection state'
    );

    my $circulator = Test::Output::LoggedInUser->new('circulate:circulate_remaining_permissions');
    is_deeply(
        Koha::Patron::Disclosure->staff_toolbar_data_classes( { logged_in_user => $circulator } ),
        [qw( circulation_current financial identity profile )],
        'circulation controls represent overdues, balance, privacy, and identity state'
    );

    $preferences{CurbsidePickup} = 1;
    is_deeply(
        Koha::Patron::Disclosure->staff_toolbar_data_classes( { logged_in_user => $no_permissions } ),
        ['identity'],
        'the static curbside scheduling link does not disclose service-activity state'
    );

    %preferences = ();
    my %sidebar_and_toolbar = map { $_ => 1 } (
        @{ Koha::Patron::Disclosure->staff_sidebar_data_classes( { logged_in_user => $serials_user } ) },
        @{ Koha::Patron::Disclosure->staff_toolbar_data_classes( { logged_in_user => $circulator } ) },
    );
    is_deeply(
        [ sort keys %sidebar_and_toolbar ],
        [
            qw( circulation_current communications contact financial identity notes_restrictions profile security_administration )
        ],
        'a page unions sidebar and toolbar contributors without assigning toolbar-only classes to the sidebar'
    );
};

subtest 'the buffered response is printed only after audit commit' => sub {
    plan tests => 4;

    @events    = ();
    $enabled   = 1;
    $fail_next = 0;

    my $stdout = render_output( body => 'PRIVATE_SENTINEL', descriptor => $descriptor );
    like( $stdout, qr/PRIVATE_SENTINEL/, 'the original body is emitted after success' );
    is( $events[0]->{commits}, 1, 'the disclosure event is committed once' );
    is_deeply( $events[0]->{subjects}, $descriptor->{subjects}, 'exact descriptor subjects reach the event' );
    unlike( $stdout, qr/503 Service Unavailable/, 'the successful response status is unchanged' );
};

subtest 'an absent descriptor is a transparent no-op' => sub {
    plan tests => 2;

    @events  = ();
    $enabled = 0;

    my $stdout = render_output( body => 'PRIVATE_SENTINEL' );
    like( $stdout, qr/PRIVATE_SENTINEL/, 'the original body is emitted' );
    is( scalar @events, 0, 'no disclosure event is created' );
};

subtest 'an enabled in-flight descriptor commits after the preference changes' => sub {
    plan tests => 3;

    @events  = ();
    $enabled = 0;

    my $stdout = render_output( body => 'PRIVATE_SENTINEL', descriptor => $descriptor );
    like( $stdout, qr/PRIVATE_SENTINEL/, 'the original body is emitted' );
    is( scalar @events,        1, 'the request-local event remains active' );
    is( $events[0]->{commits}, 1, 'the in-flight disclosure event is committed' );
};

subtest 'audit failure emits a fresh PII-free response' => sub {
    plan tests => 7;

    @events = ();
    @{ $logger->{errors} } = ();
    $enabled   = 1;
    $fail_next = 1;

    my $cookie = CGI::Cookie->new( -name => 'CGISESSID', -value => 'opaque-session' );
    my $stdout = render_output(
        body       => 'PRIVATE_SENTINEL',
        descriptor => $descriptor,
        cookie     => $cookie,
    );

    like( $stdout, qr/Status: 503 Service Unavailable/, 'the response fails closed' );
    like( $stdout, qr/Service unavailable/,             'the replacement body is generic' );
    unlike( $stdout, qr/PRIVATE_SENTINEL/, 'the original body is not emitted' );
    unlike( $stdout, qr/Set-Cookie/i,      'the original response cookie is not emitted' );
    like( $stdout, qr/Cache-control: no-cache, no-store, max-age=0/i, 'the replacement cannot be cached' );
    is( $events[0]->{commits}, 1, 'the failed event was attempted once' );
    is_deeply(
        $logger->{errors},
        ['Patron disclosure audit failed for surface patrons.record.details (reason=invalid_subject_limit)'],
        'the error log contains no actor or subject data'
    );
};

subtest 'JSON audit failure remains a generic JSON response' => sub {
    plan tests => 4;

    @events    = ();
    $enabled   = 1;
    $fail_next = 1;

    my $stdout = render_json_output( body => '{"private":"PRIVATE_SENTINEL"}', descriptor => $descriptor );
    like( $stdout, qr/Status: 503 Service Unavailable/,     'the JSON response fails closed' );
    like( $stdout, qr{Content-Type: application/json}i,     'the replacement keeps the JSON content type' );
    like( $stdout, qr/patron_disclosure_audit_unavailable/, 'the replacement has a stable error code' );
    unlike( $stdout, qr/PRIVATE_SENTINEL/, 'the original JSON body is not emitted' );
};

subtest 'descriptor drift fails closed' => sub {
    plan tests => 2;

    @events    = ();
    $enabled   = 1;
    $fail_next = 0;

    my $stdout = render_output(
        body       => 'PRIVATE_SENTINEL',
        descriptor => { %{$descriptor}, search_term => 'PRIVATE_QUERY' },
    );
    like( $stdout, qr/Status: 503 Service Unavailable/, 'unknown descriptor fields fail closed' );
    unlike( $stdout, qr/PRIVATE_SENTINEL|PRIVATE_QUERY/, 'neither body nor descriptor data is emitted' );
};

had_no_warnings;
done_testing;
