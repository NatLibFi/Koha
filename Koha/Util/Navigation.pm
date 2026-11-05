package Koha::Util::Navigation;

# Copyright Rijksmuseum 2018
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
use C4::Context;
use URI;

=head1 NAME

Koha::Util

=head1 SYNOPSIS

    use Koha::Util::Navigation;
    my $cgi = CGI->new;
    my $referer = Koha::Util::Navigation::local_referer($cgi);

=head1 DESCRIPTION

Utility class

=head1 FUNCTIONS

=head2 local_referer

    my $referer = Koha::Util::Navigation::local_referer( $cgi, { fallback => '/', remove_language => 1, staff => 1 });

    If the referer is a local URI, return local path.
    Otherwise return fallback.
    Optional parameters fallback, remove_language and staff. If you do not
    pass staff, opac is assumed.

=cut

sub local_referer {
    my ( $cgi, $params ) = @_;
    my $referer  = $params->{force_referer} || $cgi->referer;
    my $fallback = $params->{fallback} // '/';
    my $staff    = $params->{staff};             # no staff means OPAC
    return $fallback if !$referer;

    my $base = C4::Context->preference( $staff ? 'staffClientBaseURL' : 'OPACBaseURL' );
    my $rv;

    # Try ..BaseURL first, otherwise use CGI::url
    if ($base) {
        if (   $referer =~ m|^\Q$base\E|i
            && $referer =~ /\/cgi-bin\/koha\// )
        {
            $rv = substr( $referer, length($base) );
            $rv =~ s/^\///;
            $rv = '/' . $rv;
        }
    } else {
        my $cgibase = $cgi->url( -base => 1 );
        $cgibase =~ s/^https?://;
        if ( $referer =~ /$cgibase(\/cgi-bin\/koha\/.*)$/ ) {
            $rv = $1;
        }
    }
    if ($rv) {

        # The "Log out" link is a GET with '?logout.x=1'
        # Do not send back the logout parameter
        my $rv_uri = URI->new($rv);
        $rv_uri->query_param_delete('logout.x');
        $rv = $rv_uri->path_query;
    }

    $rv =~ s/(?<=[?&])language=[\w-]+(&|$)// if $rv and $params->{remove_language};
    return $rv // $fallback;
}

1;

=head1 AUTHOR

    Marcel de Rooy, Rijksmuseum Amsterdam, The Netherlands
    Koha development team

=cut
