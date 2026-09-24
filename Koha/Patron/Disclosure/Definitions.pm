package Koha::Patron::Disclosure::Definitions;

# Copyright 2026 Koha Development Team
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
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

my %BREADTHS     = map { $_ => 1 } qw( record list_page workflow_batch document );
my %DATA_CLASSES = map { $_ => 1 } qw(
    identity
    contact
    profile
    notes_restrictions
    circulation_current
    circulation_history
    financial
    communications
    service_activity
    security_administration
    documents_media
    extended_attributes
);
my %API_REFERENCE_FIELDS = (
    'Koha::Checkout' => {
        patron_id => [qw( identity circulation_current )],
    },
    'Koha::Hold' => {
        patron_id => [qw( identity circulation_current )],
    },
    'Koha::Recall' => {
        patron_id => [qw( identity circulation_current )],
    },
    'Koha::Checkouts::ReturnClaim' => {
        patron_id => [qw( identity service_activity )],
    },
    'Koha::Booking' => {
        patron_id => [qw( identity service_activity )],
    },
    'Koha::Old::Checkout' => {
        patron_id => [qw( identity circulation_history )],
    },
);
my %API_FIELD_CLASSES = (
    (
        map { $_ => ['identity'] }
            qw(
            patron_id
            cardnumber
            surname
            firstname
            preferred_name
            middle_name
            title
            other_name
            initials
            pronouns
            relationship_type
            )
    ),
    (
        map { $_ => ['contact'] }
            qw(
            street_number
            street_type
            address
            address2
            city
            state
            postal_code
            country
            email
            phone
            mobile
            fax
            secondary_email
            secondary_phone
            altaddress_street_number
            altaddress_street_type
            altaddress_address
            altaddress_address2
            altaddress_city
            altaddress_state
            altaddress_postal_code
            altaddress_country
            altaddress_email
            altaddress_phone
            altcontact_firstname
            altcontact_surname
            altcontact_address
            altcontact_address2
            altcontact_city
            altcontact_state
            altcontact_postal_code
            altcontact_country
            altcontact_phone
            sms_number
            primary_contact_method
            )
    ),
    (
        map { $_ => ['profile'] }
            qw(
            date_of_birth
            library_id
            category_id
            date_enrolled
            expiry_date
            date_renewed
            expired
            gender
            statistics_1
            statistics_2
            privacy
            privacy_guarantor_checkouts
            privacy_guarantor_fines
            updated_on
            anonymized
            library
            _strings
            )
    ),
    (
        map { $_ => ['notes_restrictions'] }
            qw(
            incorrect_address
            patron_card_lost
            restricted
            staff_notes
            opac_notes
            altaddress_notes
            protected
            )
    ),
    (
        map { $_ => ['circulation_current'] }
            qw(
            autorenew_checkouts
            checkouts_count
            overdues_count
            self_renewal_available
            )
    ),
    check_previous_checkout => ['circulation_history'],
    account_balance         => ['financial'],
    ( map { $_ => ['communications'] } qw( sms_provider_id lang ) ),
    ( map { $_ => ['security_administration'] } qw( userid login_attempts overdrive_auth_token ) ),
    last_seen           => ['service_activity'],
    extended_attributes => ['extended_attributes'],
);
my %SURFACES = (
    'patrons.search.results'                       => 'list_page',
    'patrons.record.api'                           => 'record',
    'patrons.record.brief'                         => 'record',
    'patrons.record.details'                       => 'record',
    'patrons.record.duplicate'                     => 'record',
    'patrons.record.duplicate_match'               => 'record',
    'patrons.record.create_form'                   => 'record',
    'patrons.record.edit'                          => 'record',
    'patrons.notices.list'                         => 'record',
    'patrons.account.outstanding'                  => 'record',
    'patrons.account.transactions'                 => 'record',
    'patrons.account.line_details'                 => 'record',
    'patrons.circulation.history'                  => 'record',
    'patrons.holds.history'                        => 'record',
    'patrons.recalls.history'                      => 'record',
    'patrons.alerts.list'                          => 'record',
    'patrons.suggestions.list'                     => 'record',
    'patrons.routing_lists.list'                   => 'record',
    'patrons.statistics.summary'                   => 'record',
    'patrons.checkouts.current'                    => 'record',
    'patrons.checkouts.current_batch'              => 'workflow_batch',
    'patrons.holds.list'                           => 'record',
    'patrons.return_claims.list'                   => 'record',
    'patrons.recalls.current'                      => 'record',
    'bookings.search.results'                      => 'list_page',
    'catalogue.bookings.by_record'                 => 'list_page',
    'catalogue.checkouts.by_record'                => 'list_page',
    'catalogue.items.patron_status'                => 'list_page',
    'catalogue.biblio_pickup_locations.for_patron' => 'record',
    'catalogue.item_pickup_locations.for_patron'   => 'record',
    'circulation.checkout'                         => 'record',
);

=head1 NAME

Koha::Patron::Disclosure::Definitions - Stable disclosure vocabulary and representation classes

=cut

sub valid_data_classes {
    return [ sort keys %DATA_CLASSES ];
}

sub known_data_class {
    my ( $class, $name ) = @_;
    return $DATA_CLASSES{$name};
}

sub api_field_classes {
    return { map { $_ => [ @{ $API_FIELD_CLASSES{$_} } ] } keys %API_FIELD_CLASSES };
}

sub api_field_class {
    my ( $class, $field ) = @_;
    return $API_FIELD_CLASSES{$field};
}

sub api_reference_fields {
    my ( $class, $object_class ) = @_;
    return $API_REFERENCE_FIELDS{$object_class};
}

sub surface_breadth {
    my ( $class, $surface ) = @_;
    return $SURFACES{$surface};
}

sub valid_breadth {
    my ( $class, $breadth ) = @_;
    return $BREADTHS{$breadth};
}

my %REST_OPERATIONS = (
    'GET /patrons' => {
        surface                => 'patrons.search.results',
        success_statuses       => { 200 => 1 },
        strategies             => { serialized_patrons => 1 },
        max_page_size          => 1000,
        subjects_per_page_item => 1,
        fixed_subjects         => 0,
    },
    'GET /patrons/{patron_id}' => {
        surface          => 'patrons.record.api',
        success_statuses => { 200 => 1 },
        strategies       => { serialized_patrons => 1 },
    },
);

sub rest_operation {
    my ( $class, $key ) = @_;
    return $REST_OPERATIONS{$key};
}

sub surface_ids {
    return [ sort keys %SURFACES ];
}

sub rest_operation_keys {
    return [ sort keys %REST_OPERATIONS ];
}

1;
