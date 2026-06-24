package Koha::Patron::PersonalDataAccessLog;

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

use Scalar::Util qw( refaddr );

use C4::Context;
use C4::Log qw( logaction );

use base qw(Exporter);

our @EXPORT_OK = qw( log_patron_personal_data_access );

my %logged_patron_personal_data_access;
my $current_request_key;

=head1 NAME

Koha::Patron::PersonalDataAccessLog - helper for patron personal data access logging

=head1 API

=head2 Functions

=head3 log_patron_personal_data_access

    log_patron_personal_data_access( $borrowernumber, $source, $details );

Logs staff access to patron personal data when PatronPersonalDataAccessLog is enabled.

=cut

sub log_patron_personal_data_access {
    my ( $borrowernumber, $source, $details ) = @_;

    return unless C4::Context->preference('PatronPersonalDataAccessLog');
    return unless $borrowernumber;

    my $info = $source;
    $info .= " $details" if $details;

    my $request_key = _request_key();
    if ( defined $request_key ) {
        if ( !defined $current_request_key || $current_request_key ne $request_key ) {
            %logged_patron_personal_data_access = ();
            $current_request_key                = $request_key;
        }

        return if $logged_patron_personal_data_access{"$borrowernumber:$info"}++;
    }

    logaction(
        'MEMBERS',
        'VIEW_PERSONAL_DATA',
        $borrowernumber,
        $info
    );
}

sub _request_key {
    return unless ref $ENV{'psgi.input'};
    return refaddr( $ENV{'psgi.input'} );
}

1;
