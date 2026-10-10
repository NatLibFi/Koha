package Koha::Patron::Disclosure;

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

use Carp qw( croak );
use JSON;
use Scalar::Util qw( blessed );
use UUID;

use C4::Context;
use Koha::ActionLog;
use Koha::Database;
use Koha::Exceptions;
use Koha::Exceptions::PatronDisclosure;
use Koha::Patron::Disclosure::Definitions;
use Koha::Patron::Disclosure::Staff;
use Koha::Logger;

use constant MODULE               => 'PATRON_DISCLOSURE';
use constant ACTION               => 'DISCLOSE';
use constant CONFIG_ENABLED       => 'patron_data_disclosure_log';
use constant CONFIG_MAX_SUBJECTS  => 'patron_data_disclosure_max_subjects';

my %AUTH_SOURCES         = map { $_ => 1 } qw( session basic oauth );
my %INTERFACES           = map { $_ => 1 } qw( intranet api );

=head1 NAME

Koha::Patron::Disclosure - Request-local patron disclosure audit event

=head1 SYNOPSIS

    my $event = Koha::Patron::Disclosure->new_if_enabled(
        {
            actor_id    => $logged_in_patron->id,
            surface     => 'patrons.record.api',
            breadth     => 'record',
            auth_source => 'basic',
            interface   => 'api',
        }
    );

    $event->add_subject(
        {
            patron_id    => $patron->id,
            data_classes => [ 'identity', 'contact' ],
        }
    );
    my $event_id = $event->commit;

=head1 DESCRIPTION

This class collects one response's patron subjects and writes one action-log
row per subject. It records server-side disclosure, not human attention.

=head1 API

=head2 Class methods

=head3 enabled

Returns true when patron disclosure logging is enabled.

=cut

sub enabled {
    my $value = C4::Context->config(CONFIG_ENABLED);
    return 0 unless defined $value;
    Koha::Exceptions::PatronDisclosure->throw( reason => 'invalid_configuration' )
        unless !ref($value) && $value =~ /\A[01]\z/;
    return $value eq '1' ? 1 : 0;
}

=head3 new_if_enabled

Returns a new event when patron disclosure logging is enabled, or C<undef>
when it is disabled.

=cut

sub new_if_enabled {
    my ( $class, $params ) = @_;

    return unless $class->enabled;
    return $class->new($params);
}

=head3 new

Creates a request-local disclosure event. Callers should normally use
C<new_if_enabled>.

=cut

sub new {
    my ( $class, $params ) = @_;

    $params //= {};
    _assert_hashref( $params, 'event parameters' );
    _assert_known_keys( $params, [qw( actor_id surface breadth auth_source interface api_client_id )], 'event parameters' );

    my $actor_id     = _positive_integer( $params->{actor_id}, 'actor_id' );
    my $surface      = $params->{surface}      // q{};
    my $breadth      = $params->{breadth}      // q{};
    my $auth_source  = $params->{auth_source}  // q{};
    my $interface    = $params->{interface}    // q{};
    my $api_client_id = $params->{api_client_id};

    my $required_breadth = Koha::Patron::Disclosure::Definitions->surface_breadth($surface);
    croak "Unknown patron disclosure surface '$surface'" unless defined $required_breadth;
    croak "Unknown patron disclosure breadth '$breadth'"
        unless Koha::Patron::Disclosure::Definitions->valid_breadth($breadth);
    croak "Surface '$surface' requires breadth '$required_breadth'"
        unless $breadth eq $required_breadth;
    croak "Unknown patron disclosure authentication source '$auth_source'"
        unless $AUTH_SOURCES{$auth_source};
    croak "Unknown patron disclosure interface '$interface'" unless $INTERFACES{$interface};
    if ( defined $api_client_id ) {
        croak 'api_client_id must be a non-empty string of at most 191 characters'
            if ref($api_client_id) || !length($api_client_id) || length($api_client_id) > 191;
        croak 'api_client_id is only valid for OAuth authentication'
            unless $auth_source eq 'oauth';
    } elsif ( $auth_source eq 'oauth' ) {
        croak 'OAuth patron disclosure events require api_client_id';
    }

    return bless {
        actor_id      => $actor_id,
        surface       => $surface,
        breadth       => $breadth,
        auth_source   => $auth_source,
        interface     => $interface,
        api_client_id => $api_client_id,
        subjects      => {},
    }, $class;
}

=head3 valid_data_classes

Returns the closed patron disclosure data-class vocabulary.

=cut

sub valid_data_classes {
    return Koha::Patron::Disclosure::Definitions->valid_data_classes;
}

=head3 api_field_classes

Returns the exhaustive Patron REST-schema field classification.

=cut

sub api_field_classes {
    return Koha::Patron::Disclosure::Definitions->api_field_classes;
}

=head3 surface_breadth

Returns the required breadth for a stable surface identifier.

=cut

sub surface_breadth {
    my ( $class, $surface ) = @_;
    return Koha::Patron::Disclosure::Definitions->surface_breadth($surface);
}

=head3 max_subjects

Returns the configured maximum number of unique subjects in one disclosure
event.

=cut

sub max_subjects {
    my $value = C4::Context->config(CONFIG_MAX_SUBJECTS);
    $value = 1000 unless defined $value;
    Koha::Exceptions::PatronDisclosure->throw( reason => 'invalid_subject_limit' )
        unless defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}

=head3 resolve_patron_ids, resolve_single_patron_id

Compatibility wrappers for existing event callers. New service code uses
C<Koha::Patron::Disclosure::Staff> directly.

=cut

sub resolve_patron_ids {
    shift;
    return Koha::Patron::Disclosure::Staff->resolve_patron_ids(@_);
}

sub resolve_single_patron_id {
    shift;
    return Koha::Patron::Disclosure::Staff->resolve_single_patron_id(@_);
}

sub staff_sidebar_data_classes {
    shift;
    return Koha::Patron::Disclosure::Staff->staff_sidebar_data_classes(@_);
}

sub staff_toolbar_data_classes {
    shift;
    return Koha::Patron::Disclosure::Staff->staff_toolbar_data_classes(@_);
}

=head2 Object methods

=head3 add_subject

Adds a patron and the data classes represented for that patron. Repeated calls
for the same patron union the class set within this event.

=cut

sub add_subject {
    my ( $self, $params ) = @_;

    $self->_assert_open;
    _assert_hashref( $params, 'subject parameters' );
    _assert_known_keys( $params, [qw( patron_id data_classes )], 'subject parameters' );

    my $patron_id    = _positive_integer( $params->{patron_id}, 'patron_id' );
    my $data_classes = $params->{data_classes};

    croak 'data_classes must be a non-empty array reference'
        unless ref($data_classes) eq 'ARRAY' && @{$data_classes};

    for my $data_class ( @{$data_classes} ) {
        croak 'data_classes values must be non-empty strings'
            unless defined $data_class && !ref($data_class) && length $data_class;
        croak "Unknown patron disclosure data class '$data_class'"
            unless Koha::Patron::Disclosure::Definitions->known_data_class($data_class);
        $self->{subjects}->{$patron_id}->{$data_class} = 1;
    }

    return $self;
}

=head3 add_api_subject

Adds a patron from the positively disclosed fields in its final REST
representation. Unknown fields are rejected so schema drift cannot silently
weaken the audit classification.

=cut

sub add_api_subject {
    my ( $self, $params ) = @_;

    $self->_assert_open;
    _assert_hashref( $params, 'API subject parameters' );
    _assert_known_keys( $params, [qw( patron_id fields )], 'API subject parameters' );

    my $fields = $params->{fields};
    croak 'fields must be a non-empty array reference' unless ref($fields) eq 'ARRAY' && @{$fields};

    my %data_classes;
    for my $field ( @{$fields} ) {
        croak 'fields values must be non-empty strings' unless defined $field && !ref($field) && length $field;
        my $classes = Koha::Patron::Disclosure::Definitions->api_field_class($field);
        croak "Unclassified Patron REST field '$field'" unless $classes;
        $data_classes{$_} = 1 for @{$classes};
    }

    return $self->add_subject(
        {
            patron_id    => $params->{patron_id},
            data_classes => [ sort keys %data_classes ],
        }
    );
}

=head3 add_api_reference_subjects

Adds patron-owner references disclosed by a supported non-Patron REST
representation. Staff provenance fields such as C<issuer_id> and C<created_by>
are not patron subjects for this audit.

=cut

sub add_api_reference_subjects {
    my ( $self, $params ) = @_;

    $self->_assert_open;
    _assert_hashref( $params, 'API reference parameters' );
    _assert_known_keys( $params, [qw( object representation )], 'API reference parameters' );

    my $object         = $params->{object};
    my $representation = $params->{representation};
    croak 'API reference object must be blessed' unless blessed($object);
    _assert_hashref( $representation, 'API reference representation' );

    my $fields = Koha::Patron::Disclosure::Definitions->api_reference_fields( ref($object) );
    return $self unless $fields;

    for my $field ( sort keys %{$fields} ) {
        next unless exists $representation->{$field} && defined $representation->{$field};
        $self->add_subject(
            {
                patron_id    => $representation->{$field},
                data_classes => $fields->{$field},
            }
        );
    }

    return $self;
}

=head3 subject_count

Returns the number of unique patron subjects collected by this event.

=cut

sub subject_count {
    my ($self) = @_;
    return scalar keys %{ $self->{subjects} };
}

=head3 commit

Writes the complete event transactionally and returns its server-generated
event identifier. Returns C<undef> when no subjects were collected. Repeated
calls on a committed object do not write duplicate rows.

=cut

sub commit {
    my ($self) = @_;

    return $self->{event_id} if $self->{committed};
    return unless $self->subject_count;

    my $limit = $self->max_subjects;
    croak sprintf( 'Patron disclosure event has %d subjects; configured maximum is %d', $self->subject_count, $limit )
        if $self->subject_count > $limit;

    my $event_id = _generate_event_id();
    my $schema   = Koha::Database->new->schema;

    $schema->txn_do(
        sub {
            for my $patron_id ( sort { $a <=> $b } keys %{ $self->{subjects} } ) {
                my $payload = {
                    v            => 1,
                    event_id     => $event_id,
                    surface      => $self->{surface},
                    breadth      => $self->{breadth},
                    data_classes => [ sort keys %{ $self->{subjects}->{$patron_id} } ],
                    auth_source  => $self->{auth_source},
                };
                $payload->{api_client_id} = $self->{api_client_id}
                    if defined $self->{api_client_id};

                my $info = _encode_json($payload);

                my $stored = Koha::ActionLog->new(
                    {
                        timestamp => \'NOW()',
                        user      => $self->{actor_id},
                        module    => MODULE,
                        action    => ACTION,
                        object    => $patron_id,
                        info      => $info,
                        interface => $self->{interface},
                    }
                )->store;
                Koha::Exceptions::PatronDisclosure->throw( reason => 'storage' )
                    unless $stored;
            }
        }
    );

    $self->{event_id}  = $event_id;
    $self->{committed} = 1;

    eval {
        my $logger = Koha::Logger->get(
            {
                interface => $self->{interface},
                category  => 'ActionLogs.' . MODULE . '.' . ACTION,
            }
        );
        $logger->debug(
            sub {
                return 'PATRON DISCLOSURE EVENT: ' . _encode_json(
                    {
                        event_id      => $event_id,
                        surface       => $self->{surface},
                        breadth       => $self->{breadth},
                        auth_source   => $self->{auth_source},
                        subject_count => $self->subject_count,
                    }
                );
            }
        );
    };

    return $event_id;
}

sub _assert_open {
    my ($self) = @_;
    croak 'Committed patron disclosure event cannot be changed' if $self->{committed};
    return;
}

sub _generate_event_id {
    my ( $uuid, $event_id );
    UUID::generate($uuid);
    UUID::unparse( $uuid, $event_id );
    return $event_id;
}

sub _encode_json {
    my ($value) = @_;
    return JSON->new->canonical->encode($value);
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

sub _positive_integer {
    my ( $value, $name ) = @_;
    croak "$name must be a positive integer"
        unless defined $value && !ref($value) && $value =~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}


1;
