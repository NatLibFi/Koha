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
use Koha::Patron::Disclosure::Definitions;

use constant STASH_KEY => 'koha.patron_disclosure';

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

            my $binding = $spec->{'x-koha-patron-disclosure'};
            croak 'Patron disclosure operation reference must be a string'
                if ref($binding) || !defined($binding);
            my $policy = Koha::Patron::Disclosure::Definitions->rest_operation($binding);
            croak "Unknown patron disclosure operation '$binding'" unless $policy;
            my ($method) = split / /, $binding, 2;
            croak 'Patron disclosure operation method mismatch'
                unless $method eq $c->req->method;

            my $event = Koha::Patron::Disclosure->new(
                {
                    actor_id      => $params->{actor_id},
                    surface       => $policy->{surface},
                    breadth       => Koha::Patron::Disclosure->surface_breadth( $policy->{surface} ),
                    auth_source   => $params->{auth_source},
                    api_client_id => $params->{api_client_id},
                    interface     => 'api',
                }
            );
            $c->stash( STASH_KEY() => { event => $event, policy => $policy } );

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
        'patron_disclosure.context' => sub {
            my ($c) = @_;
            my $state = $c->stash(STASH_KEY);
            return ref($state) eq 'HASH' ? $state : undef;
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

            my $maximum = $state->{policy}->{max_page_size};
            return $c unless defined $maximum;

            my $subject_limit;
            my $valid_subject_limit = eval {
                $subject_limit = Koha::Patron::Disclosure->max_subjects;
                1;
            };
            unless ($valid_subject_limit) {
                my $surface = $state->{policy}->{surface};
                $surface = 'invalid' unless defined $surface && $surface =~ /\A[a-z0-9_.]+\z/;
                $c->app->log->error(
                    "Patron disclosure audit failed for surface $surface (reason=invalid_subject_limit)"
                );
                Koha::Exceptions::UnderMaintenance->throw(
                    error => 'Patron disclosure auditing is unavailable'
                );
            }

            my $available = $subject_limit - $state->{policy}->{fixed_subjects};
            my $audit_maximum =
                $available > 0 ? int( $available / $state->{policy}->{subjects_per_page_item} ) : 0;
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
            return $c unless $state->{policy}->{success_statuses}->{$status};

            my $ok = eval {
                croak 'The explicit patron disclosure strategy was not completed by the controller'
                    if $state->{policy}->{strategies}->{explicit} && !$state->{explicit_completed};

                if ( my $path = $state->{policy}->{path_patron} ) {
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
                    'Patron disclosure audit failed for surface ' . $state->{policy}->{surface} . " ($error_type)" );
                _replace_with_service_unavailable($c);
            }

            return $c;
        }
    );
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
    my $cors_origin = C4::Context->preference('AccessControlAllowOrigin');
    $headers->header( 'Access-Control-Allow-Origin' => $cors_origin ) if $cors_origin;
    $headers->content_type('application/json; charset=utf8');
    $headers->cache_control('no-store');
    $headers->content_length( length($body) );

    $c->res->code(503);
    $c->res->message('Service Unavailable');
    $c->res->body($body);

    return;
}

1;
