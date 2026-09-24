package Koha::REST::Plugin::PatronDisclosure;

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

use Carp         qw( croak );
use JSON         qw( encode_json );
use Scalar::Util qw( blessed );

use Mojo::Base 'Mojolicious::Plugin';

use C4::Context;
use Koha::Exceptions;
use Koha::Patron::Disclosure;

use constant STASH_KEY => 'koha.patron_disclosure';

my %STRATEGIES = map { $_ => 1 } qw( serialized_patrons patron_references path_patron explicit );

=head1 NAME

Koha::REST::Plugin::PatronDisclosure - Response-bound patron disclosure audit

=head1 API

=head2 Class methods

=head3 register

Registers request-local patron disclosure helpers. The application must call
C<patron_disclosure.finalize> from its last response post-processing hook.

=cut

sub register {
    my ( $self, $app ) = @_;

    $app->helper(
        'patron_disclosure.initialize' => sub {
            my ( $c, $params ) = @_;

            return $c unless ref($params) eq 'HASH';
            return $c if $params->{is_public} || $params->{is_plugin};

            my $spec = $params->{spec};
            return $c unless ref($spec) eq 'HASH' && exists $spec->{'x-koha-patron-disclosure'};
            return $c unless Koha::Patron::Disclosure->enabled;

            my $metadata = _normalize_metadata( $spec->{'x-koha-patron-disclosure'}, $spec );

            my $event = Koha::Patron::Disclosure->new(
                {
                    actor_id      => $params->{actor_id},
                    surface       => $metadata->{surface},
                    breadth       => Koha::Patron::Disclosure->surface_breadth( $metadata->{surface} ),
                    auth_source   => $params->{auth_source},
                    api_client_id => $params->{api_client_id},
                    interface     => 'api',
                }
            );
            $c->stash(
                STASH_KEY() => {
                    event    => $event,
                    metadata => $metadata,
                }
            );

            return $c;
        }
    );

    $app->helper(
        'patron_disclosure.event' => sub {
            my ($c) = @_;
            my $state = $c->stash(STASH_KEY);
            return ref($state) eq 'HASH' ? $state->{event} : undef;
        }
    );

    $app->helper(
        'patron_disclosure.is_active' => sub {
            my ($c) = @_;
            my $state = $c->stash(STASH_KEY);
            return ref($state) eq 'HASH' && $state->{event} ? 1 : 0;
        }
    );

    $app->helper(
        'patron_disclosure.serialized_patron_collector' => sub {
            my ($c) = @_;
            my $state = $c->stash(STASH_KEY);
            return unless ref($state) eq 'HASH' && $state->{metadata}->{strategies}->{serialized_patrons};
            return $state->{event};
        }
    );

    $app->helper(
        'patron_disclosure.reference_collector' => sub {
            my ($c) = @_;
            my $state = $c->stash(STASH_KEY);
            return unless ref($state) eq 'HASH' && $state->{metadata}->{strategies}->{patron_references};
            return $state->{event};
        }
    );

    $app->helper(
        'patron_disclosure.add_subject' => sub {
            my ( $c, $params ) = @_;
            my $state = $c->stash(STASH_KEY);
            if ( ref($state) eq 'HASH' && $state->{event} ) {
                $state->{event}->add_subject($params);
                $state->{explicit_completed} = 1;
            }
            return $c;
        }
    );

    $app->helper(
        'patron_disclosure.validate_page_size' => sub {
            my ($c) = @_;

            my $state = $c->stash(STASH_KEY);
            return $c unless ref($state) eq 'HASH';

            my $maximum = $state->{metadata}->{max_page_size};
            return $c unless defined $maximum;

            my $subject_limit;
            my $valid_subject_limit = eval {
                $subject_limit = Koha::Patron::Disclosure->max_subjects;
                1;
            };
            unless ($valid_subject_limit) {
                my $surface = $state->{metadata}->{surface};
                $surface = 'invalid' unless defined $surface && $surface =~ /\A[a-z0-9_.]+\z/;
                $c->app->log->error(
                    "Patron disclosure audit failed for surface $surface (reason=invalid_subject_limit)"
                );
                Koha::Exceptions::UnderMaintenance->throw(
                    error => 'Patron disclosure auditing is unavailable'
                );
            }

            my $available = $subject_limit - $state->{metadata}->{fixed_subjects};
            my $audit_maximum =
                $available > 0 ? int( $available / $state->{metadata}->{subjects_per_page_item} ) : 0;
            $maximum = $audit_maximum if $audit_maximum < $maximum;

            my $query_params = $c->req->query_params;
            my $requested    = $query_params->to_hash->{_per_page};
            my $is_explicit  = defined $requested;
            $requested //= C4::Context->preference('RESTdefaultPageSize') // 20;

            if (   !$is_explicit
                && defined $requested
                && !ref($requested)
                && $requested =~ /\A-?[0-9]+\z/
                && ( $requested == -1 || $requested > $maximum )
                && $maximum > 0 )
            {
                $requested = $maximum;
                $query_params->param( _per_page => $maximum );
            }

            if (  !defined $requested
                || ref($requested)
                || $requested !~ /\A-?[0-9]+\z/
                || $requested < 1
                || $requested > $maximum )
            {
                Koha::Exceptions::BadParameter->throw(
                    error => {
                        error => $maximum
                        ? "Page size must be between 1 and $maximum while patron disclosure auditing is enabled"
                        : 'The configured patron disclosure subject limit cannot accommodate this response',
                        error_code => 'patron_disclosure_page_size_exceeded',
                    }
                );
            }

            return $c;
        }
    );

    $app->helper(
        'patron_disclosure.finalize' => sub {
            my ($c) = @_;

            my $state = $c->stash(STASH_KEY);
            return $c unless ref($state) eq 'HASH' && !$state->{finalized};
            $state->{finalized} = 1;

            my $status = $c->res->code // 200;
            return $c unless $state->{metadata}->{success_statuses}->{$status};

            my $ok = eval {
                croak 'The explicit patron disclosure strategy was not completed by the controller'
                    if $state->{metadata}->{strategies}->{explicit} && !$state->{explicit_completed};

                if ( my $path = $state->{metadata}->{path_patron} ) {
                    $state->{event}->add_subject(
                        {
                            patron_id    => $c->param( $path->{parameter} ),
                            data_classes => $path->{data_classes},
                        }
                    );
                }

                $state->{event}->commit;
                1;
            };

            unless ($ok) {
                my $error_type = blessed($@) ? ref($@) : 'unclassified error';
                $c->app->log->error(
                    'Patron disclosure audit failed for surface ' . $state->{metadata}->{surface} . " ($error_type)" );
                _replace_with_service_unavailable($c);
            }

            return $c;
        }
    );
}

sub _normalize_metadata {
    my ( $metadata, $spec ) = @_;

    croak 'x-koha-patron-disclosure must be an object' unless ref($metadata) eq 'HASH';
    _assert_known_keys(
        $metadata,
        [qw( surface success_statuses strategies max_page_size subjects_per_page_item fixed_subjects path_patron )],
        'x-koha-patron-disclosure'
    );

    my $surface = $metadata->{surface} // q{};
    croak "Unknown patron disclosure surface '$surface'"
        unless Koha::Patron::Disclosure->surface_breadth($surface);

    my $statuses = $metadata->{success_statuses};
    croak 'success_statuses must be a non-empty array' unless ref($statuses) eq 'ARRAY' && @{$statuses};
    my %statuses;
    for my $status ( @{$statuses} ) {
        croak 'success_statuses values must be successful HTTP status integers'
            unless defined $status && !ref($status) && $status =~ /\A2[0-9]{2}\z/;
        croak "Response status $status is not declared by the operation" unless exists $spec->{responses}->{$status};
        croak "Duplicate patron disclosure success status '$status'" if $statuses{$status}++;
    }

    my $strategies = $metadata->{strategies};
    croak 'strategies must be a non-empty array' unless ref($strategies) eq 'ARRAY' && @{$strategies};
    my %strategies;
    for my $strategy ( @{$strategies} ) {
        croak "Unknown patron disclosure subject strategy '$strategy'" unless $STRATEGIES{$strategy};
        croak "Duplicate patron disclosure subject strategy '$strategy'" if $strategies{$strategy}++;
    }

    my $path_patron;
    if ( $strategies{path_patron} ) {
        $path_patron = $metadata->{path_patron};
        croak 'path_patron metadata is required for the path_patron strategy'
            unless ref($path_patron) eq 'HASH';
        _assert_known_keys( $path_patron, [qw( parameter data_classes )], 'path_patron' );

        croak 'path_patron.parameter must be a non-empty string'
            unless defined $path_patron->{parameter}
            && !ref( $path_patron->{parameter} )
            && length $path_patron->{parameter};

        my $classes = $path_patron->{data_classes};
        croak 'path_patron.data_classes must be a non-empty array'
            unless ref($classes) eq 'ARRAY' && @{$classes};
        my %valid_classes = map { $_ => 1 } @{ Koha::Patron::Disclosure->valid_data_classes };
        for my $class ( @{$classes} ) {
            croak "Unknown path_patron data class '$class'" unless $valid_classes{$class};
        }
        $path_patron = {
            parameter    => $path_patron->{parameter},
            data_classes => [ sort @{$classes} ],
        };
    } elsif ( exists $metadata->{path_patron} ) {
        croak 'path_patron metadata requires the path_patron strategy';
    }

    my $max_page_size = $metadata->{max_page_size};
    if ( defined $max_page_size ) {
        croak 'max_page_size must be a positive integer'
            unless !ref($max_page_size) && $max_page_size =~ /\A[1-9][0-9]*\z/;
        $max_page_size = 0 + $max_page_size;
    }

    my $subjects_per_page_item = $metadata->{subjects_per_page_item};
    if ( defined $subjects_per_page_item ) {
        croak 'subjects_per_page_item must be a positive integer'
            unless !ref($subjects_per_page_item) && $subjects_per_page_item =~ /\A[1-9][0-9]*\z/;
        $subjects_per_page_item = 0 + $subjects_per_page_item;
    }

    my $fixed_subjects = $metadata->{fixed_subjects} // 0;
    croak 'fixed_subjects must be a non-negative integer'
        unless !ref($fixed_subjects) && $fixed_subjects =~ /\A(?:0|[1-9][0-9]*)\z/;
    $fixed_subjects = 0 + $fixed_subjects;

    my $is_paginated = grep {
               ( exists $_->{name} && $_->{name} eq '_per_page' )
            || ( exists $_->{'$ref'} && $_->{'$ref'} =~ m{(?:/|_)per_page\z} )
    } @{ $spec->{parameters} // [] };
    my $needs_page_ceiling = $is_paginated && ( $strategies{serialized_patrons} || $strategies{patron_references} );
    croak 'Paginated patron-attributing operations must declare max_page_size and subjects_per_page_item'
        if $needs_page_ceiling && ( !defined $max_page_size || !defined $subjects_per_page_item );
    croak 'Page-ceiling metadata requires a paginated patron-attributing operation'
        if !$needs_page_ceiling
        && ( defined $max_page_size || defined $subjects_per_page_item || exists $metadata->{fixed_subjects} );

    return {
        surface                => $surface,
        success_statuses       => \%statuses,
        strategies             => \%strategies,
        max_page_size          => $max_page_size,
        subjects_per_page_item => $subjects_per_page_item,
        fixed_subjects         => $fixed_subjects,
        path_patron            => $path_patron,
    };
}

sub _assert_known_keys {
    my ( $params, $known, $name ) = @_;
    my %known   = map       { $_ => 1 } @{$known};
    my @unknown = sort grep { !$known{$_} } keys %{$params};
    croak "$name contains unknown key(s): " . join( ', ', @unknown ) if @unknown;
    return;
}

sub _replace_with_service_unavailable {
    my ($c) = @_;

    my $body = encode_json(
        {
            error      => 'Service unavailable',
            error_code => 'patron_disclosure_audit_unavailable',
        }
    );

    my $headers = $c->res->headers;
    $headers->remove($_) for @{ $headers->names };
    $headers->content_type('application/json; charset=utf8');
    $headers->cache_control('no-store');
    $headers->content_length( length($body) );

    $c->res->code(503);
    $c->res->message('Service Unavailable');
    $c->res->body($body);

    return;
}

1;
