package Koha::Patron::Disclosure::Staff;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Carp qw( croak );
use Scalar::Util qw( blessed );

use C4::Context;
use Koha::Exceptions;

use constant RAW_INPUT_MULTIPLIER => 4;
use constant MAX_PATRON_ID        => 2_147_483_647;

=head1 NAME

Koha::Patron::Disclosure::Staff - Staff and service disclosure input

=head1 DESCRIPTION

Keeps staff component classifications and bounded service input resolution
outside the persistence event. Service callers receive a safe error contract
before running any patron activity query.

=head1 API

=cut

=head3 resolve_patron_ids

Validates and canonicalizes request-supplied patron IDs, bounds both raw and
unique input before any patron activity query. It returns all normalized IDs
only when every ID belongs to an existing patron; mixed existing/nonexistent
input is rejected as one request. The raw-input ceiling permits a bounded
number of duplicates while the configured event limit remains the
unique-subject limit.

=cut

sub resolve_patron_ids {
    my ( $class, $raw_ids ) = @_;

    croak 'Patron disclosure subject input must be an array reference' unless ref($raw_ids) eq 'ARRAY';

    require Koha::Patron::Disclosure;
    my $subject_limit   = Koha::Patron::Disclosure->max_subjects;
    my $raw_input_limit = $subject_limit * RAW_INPUT_MULTIPLIER;
    _invalid_patron_ids() if @{$raw_ids} > $raw_input_limit;

    my %normalized_ids;
    for my $raw_id ( @{$raw_ids} ) {
        my $patron_id = _patron_id($raw_id);
        $normalized_ids{$patron_id} = 1;
    }

    _invalid_patron_ids() if scalar keys %normalized_ids > $subject_limit;

    my @normalized_ids = sort { $a <=> $b } keys %normalized_ids;
    return [] unless @normalized_ids;

    require Koha::Patrons;
    my @existing_ids =
        map { 0 + $_ } Koha::Patrons->search(
        { borrowernumber => { -in => \@normalized_ids } },
        { order_by       => 'borrowernumber' }
        )->get_column('borrowernumber');

    my %existing_ids = map { $_ => 1 } @existing_ids;
    _invalid_patron_ids()
        unless @existing_ids == @normalized_ids && !grep { !$existing_ids{$_} } @normalized_ids;

    return \@existing_ids;
}

=head3 resolve_single_patron_id

Requires exactly one request-supplied patron ID and applies the same bounded,
canonical, existence-resolved contract as C<resolve_patron_ids>.

=cut

sub resolve_single_patron_id {
    my ( $class, $raw_ids ) = @_;

    croak 'Patron disclosure subject input must be an array reference' unless ref($raw_ids) eq 'ARRAY';
    _invalid_patron_ids() unless @{$raw_ids} == 1;

    my $resolved_ids = $class->resolve_patron_ids($raw_ids);
    return $resolved_ids->[0];
}

=head3 staff_sidebar_data_classes

Returns the data classes represented by C<circ-menu.inc>. Conditional classes
follow the system preferences used by that include.

=cut

sub staff_sidebar_data_classes {
    my ( $class, $params ) = @_;

    $params //= {};
    _assert_hashref( $params, 'staff sidebar parameters' );
    _assert_known_keys( $params, ['logged_in_user'], 'staff sidebar parameters' );

    my $logged_in_user = $params->{logged_in_user};
    croak 'logged_in_user must be a patron object'
        if defined $logged_in_user && ( !blessed($logged_in_user) || !$logged_in_user->can('has_permission') );

    my @classes = qw( identity profile notes_restrictions security_administration );

    push @classes, 'contact' unless C4::Context->preference('HidePersonalPatronDetailOnCirculation');
    push @classes, 'documents_media'     if C4::Context->preference('patronimages');
    push @classes, 'extended_attributes' if C4::Context->preference('ExtendedPatronAttributes');
    push @classes, 'service_activity'    if C4::Context->preference('TrackLastPatronActivityTriggers');
    push @classes, 'communications'
        if $logged_in_user && $logged_in_user->has_permission( { serials => '*' } );

    return [ sort @classes ];
}

=head3 staff_toolbar_data_classes

Returns the data classes represented by C<members-toolbar.inc>. Conditional
classes follow the staff permissions and system preferences used by that
include. Negative conditional state is still disclosure when the control is
rendered, so subject values do not suppress their class.

=cut

sub staff_toolbar_data_classes {
    my ( $class, $params ) = @_;

    $params //= {};
    _assert_hashref( $params, 'staff toolbar parameters' );
    _assert_known_keys( $params, ['logged_in_user'], 'staff toolbar parameters' );

    my $logged_in_user = $params->{logged_in_user};
    croak 'logged_in_user must be a patron object'
        if defined $logged_in_user && ( !blessed($logged_in_user) || !$logged_in_user->can('has_permission') );

    my %classes = ( identity => 1 );
    if ($logged_in_user) {
        my $can_edit = $logged_in_user->has_permission( { borrowers => 'edit_borrowers' } );
        if ($can_edit) {
            $classes{communications}          = 1;
            $classes{profile}                 = 1;
            $classes{security_administration} = 1;
            $classes{notes_restrictions}      = 1
                if $logged_in_user->has_permission( { borrowers => 'delete_borrowers' } );
        }
        if ( $logged_in_user->has_permission( { circulate => 'circulate_remaining_permissions' } ) ) {
            $classes{circulation_current} = 1;
            $classes{financial}           = 1;
            $classes{profile}             = 1;
        }
    }
    return [ sort keys %classes ];
}


=head3 resolve_service_patron_ids

Returns a resolved ID array or a safe HTTP error descriptor. Single-patron
services require exactly one raw parameter, including duplicate parameters.

=cut

sub resolve_service_patron_ids {
    my ( $class, $raw_ids, $single ) = @_;

    my $resolved;
    my $ok = eval {
        $resolved = $single
            ? [ $class->resolve_single_patron_id($raw_ids) ]
            : $class->resolve_patron_ids($raw_ids);
        1;
    };
    return ( $resolved, undef ) if $ok;

    my $error = $@;
    my $invalid_input = ref($error) eq 'Koha::Exceptions::BadParameter'
        && ( $error->parameter // q{} ) eq 'patron_disclosure_subjects';
    return (
        undef,
        $invalid_input
        ? {
            status     => '400 Bad Request',
            error      => 'Invalid request',
            error_code => 'patron_disclosure_invalid_subjects',
        }
        : {
            status     => '503 Service Unavailable',
            error      => 'Service unavailable',
            error_code => 'patron_disclosure_subject_resolution_unavailable',
        }
    );
}

sub _assert_hashref {
    my ( $value, $name ) = @_;
    croak "$name must be a hash reference" unless ref($value) eq 'HASH';
    return;
}

sub _assert_known_keys {
    my ( $params, $known, $name ) = @_;
    my %known   = map       { $_ => 1 } @{$known};
    my @unknown = sort grep { !$known{$_} } keys %{$params};
    croak "$name contains unknown key(s): " . join( ', ', @unknown ) if @unknown;
    return;
}

sub _patron_id {
    my ($value) = @_;

    _invalid_patron_ids()
        unless defined $value
        && !ref($value)
        && $value =~ /\A[1-9][0-9]*\z/
        && ( length($value) < 10 || ( length($value) == 10 && $value le MAX_PATRON_ID ) );

    return 0 + $value;
}

sub _invalid_patron_ids {
    Koha::Exceptions::BadParameter->throw( parameter => 'patron_disclosure_subjects' );
}

1;
