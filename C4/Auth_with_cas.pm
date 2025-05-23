package C4::Auth_with_cas;

# Copyright 2009 BibLibre SARL
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
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use strict;
use warnings;

use C4::Context;
use Koha::AuthUtils qw( get_script_name );
use Authen::CAS::Client;
use CGI qw ( -utf8 );
use YAML::XS;
use URI::Escape;

use Koha::Logger;

our ( @ISA, @EXPORT_OK );

BEGIN {
    require Exporter;
    @ISA = qw(Exporter);
    @EXPORT_OK =
        qw(check_api_auth_cas checkpw_cas login_cas logout_cas login_cas_url logout_if_required multipleAuth getMultipleAuth);
}
my $defaultcasserver;
my $casservers;
my $yamlauthfile = C4::Context->config('intranetdir') . "/C4/Auth_cas_servers.yaml";

# If there's a configuration for multiple cas servers, then we get it
if ( multipleAuth() ) {
    ( $defaultcasserver, $casservers ) = YAML::XS::LoadFile($yamlauthfile);
    $defaultcasserver = $defaultcasserver->{'default'};
} else {

    # Else, we fall back to casServerUrl syspref
    $defaultcasserver = 'default';
    $casservers       = { 'default' => C4::Context->preference('casServerUrl') };
}

=head1 Subroutines

=cut

# Is there a configuration file for multiple cas servers?

=head2 multipleAuth

Missing POD for multipleAuth.

=cut

sub multipleAuth {
    return ( -e qq($yamlauthfile) );
}

# Returns configured CAS servers' list if multiple authentication is enabled

=head2 getMultipleAuth

Missing POD for getMultipleAuth.

=cut

sub getMultipleAuth {
    return $casservers;
}

# Logout from CAS

=head2 logout_cas

Missing POD for logout_cas.

=cut

sub logout_cas {
    my ( $query, $type ) = @_;
    my ( $cas,   $uri )  = _get_cas_and_service( $query, undef, $type );

    # We don't want to keep triggering a logout, if we got here,
    # the borrower is already logged out of Koha
    $uri =~ s/\?logout\.x=1//;

    my $logout_url = $cas->logout_url( url => $uri );
    $logout_url =~ s/url=/service=/
        if C4::Context->preference('casServerVersion') eq '3';

    print $query->redirect($logout_url);
}

# Login to CAS

=head2 login_cas

Missing POD for login_cas.

=cut

sub login_cas {
    my ( $query, $type ) = @_;
    my ( $cas,   $uri )  = _get_cas_and_service( $query, undef, $type );
    print $query->redirect( $cas->login_url($uri) );
}

# Returns CAS login URL with callback to the requesting URL

=head2 login_cas_url

Missing POD for login_cas_url.

=cut

sub login_cas_url {
    my ( $query, $key, $type ) = @_;
    my ( $cas, $uri ) = _get_cas_and_service( $query, $key, $type );
    return $cas->login_url($uri);
}

# Checks for password correctness
# In our case : is there a ticket, is it valid and does it match one of our users ?

=head2 checkpw_cas

Missing POD for checkpw_cas.

=cut

sub checkpw_cas {
    my ( $ticket, $query, $type ) = @_;
    my $retnumber;
    my ( $cas, $uri ) = _get_cas_and_service( $query, undef, $type );

    # If we got a ticket
    if ($ticket) {

        # We try to validate it
        my $val = $cas->service_validate( $uri, $ticket );

        # If it's valid
        if ( $val->is_success() ) {

            my $userid = $val->user();

            # we should store the CAS ticekt too, we need this for single logout https://apereo.github.io/cas/4.2.x/protocol/CAS-Protocol-Specification.html#233-single-logout

            # Does it match one of our users ?
            my $dbh    = C4::Context->dbh;
            my $patron = Koha::Patrons->find( { userid => $userid } );
            if ($patron) {
                return ( 1, $patron->cardnumber, $patron->userid, $ticket, $patron );
            }
            $patron = Koha::Patrons->find( { cardnumber => $userid } );
            if ($patron) {
                return ( 1, $patron->cardnumber, $patron->userid, $ticket, $patron );
            }

            # If we reach this point, then the user is a valid CAS user, but not a Koha user
            Koha::Logger->get->info("User $userid is not a valid Koha user");

        } else {
            my $logger = Koha::Logger->get;
            $logger->debug("Problem when validating ticket : $ticket");
            $logger->debug( "Authen::CAS::Client::Response::Error: " . $val->error() )     if $val->is_error();
            $logger->debug( "Authen::CAS::Client::Response::Failure: " . $val->message() ) if $val->is_failure();
            $logger->debug( Data::Dumper::Dumper($@) ) if $val->is_error() or $val->is_failure();
            return 0;
        }
    }
    return 0;
}

# Proxy CAS auth

=head2 check_api_auth_cas

Missing POD for check_api_auth_cas.

=cut

sub check_api_auth_cas {
    my ( $PT, $query, $type ) = @_;
    my $retnumber;
    my ( $cas, $uri ) = _get_cas_and_service( $query, undef, $type );

    # If we have a Proxy Ticket
    if ($PT) {
        my $r = $cas->proxy_validate( $uri, $PT );

        # If the PT is valid
        if ( $r->is_success ) {

            # We've got a username !
            my $userid = $r->user;

            # we should store the CAS ticket too, we need this for single logout https://apereo.github.io/cas/4.2.x/protocol/CAS-Protocol-Specification.html#233-single-logout

            # Does it match one of our users ?
            my $dbh = C4::Context->dbh;
            my $sth = $dbh->prepare("select cardnumber from borrowers where userid=?");
            $sth->execute($userid);
            if ( $sth->rows ) {
                $retnumber = $sth->fetchrow;
                return ( 1, $retnumber, $userid, $PT );
            }
            $sth = $dbh->prepare("select userid from borrowers where cardnumber=?");
            return $r->user;
            $sth->execute($userid);
            if ( $sth->rows ) {
                $retnumber = $sth->fetchrow;
                return ( 1, $retnumber, $userid, $PT );
            }

            # If we reach this point, then the user is a valid CAS user, but not a Koha user
            Koha::Logger->get->info("User $userid is not a valid Koha user");

        } else {
            Koha::Logger->get->debug("Proxy Ticket authentication failed");
            return 0;
        }
    }
    return 0;
}

# Get CAS handler and service URI
sub _get_cas_and_service {
    my $query = shift;
    my $key   = shift;    # optional
    my $type  = shift;

    my $uri = _url_with_get_params( $query, $type );

    my $casparam = $defaultcasserver;
    $casparam = $query->param('cas') if defined $query->param('cas');
    $casparam = $key                 if defined $key;
    my $cas = Authen::CAS::Client->new( $casservers->{$casparam} );

    return ( $cas, $uri );
}

# Get the current URL with parameters contained directly into URL (GET params)
# This method replaces $query->url() which will give both GET and POST params
sub _url_with_get_params {
    my $query = shift;
    my $type  = shift;

    my $uri_base_part =
        ( $type eq 'opac' )
        ? C4::Context->preference('OPACBaseURL')
        : C4::Context->preference('staffClientBaseURL');
    $uri_base_part .= get_script_name();

    my $uri_params_part = '';
    foreach my $param ( $query->url_param() ) {

        # url_param() always returns parameters that were deleted by delete()
        # This additional check ensure that parameter was not deleted.
        my $uriPiece = $query->param($param);
        if ($uriPiece) {
            $uri_params_part .= '&' if $uri_params_part;
            $uri_params_part .= $param . '=';
            $uri_params_part .= URI::Escape::uri_escape($uriPiece);
        }
    }
    $uri_base_part .= '?' if $uri_params_part;

    return $uri_base_part . $uri_params_part;
}

=head2 logout_if_required

    If using CAS, this subroutine will trigger single-signout of the CAS server.

=cut

sub logout_if_required {
    my ($query) = @_;

    # Check we haven't been hit by a logout call
    my $xml = $query->param('logoutRequest');
    return 0 unless $xml;

    my $dom = XML::LibXML->load_xml( string => $xml );
    my $ticket;
    foreach my $node ( $dom->findnodes('/samlp:LogoutRequest') ) {

        # We got a cas single logout request from a cas server;
        $ticket = $node->findvalue('./samlp:SessionIndex');
    }

    return 0 unless $ticket;

    # We've been called as part of the single logout destroy the session associated with the cas ticket
    my $params  = C4::Auth::_get_session_params();
    my $success = CGI::Session->find( $params->{dsn}, sub { delete_cas_session( @_, $ticket ) }, $params->{dsn_args} );

    print $query->header;
    exit;
}

=head2 delete_cas_session

Missing POD for delete_cas_session.

=cut

sub delete_cas_session {
    my $session = shift;
    my $ticket  = shift;
    if ( $session->param('cas_ticket') && $session->param('cas_ticket') eq $ticket ) {
        $session->delete;
        $session->flush;
    }
}

1;
__END__

=head1 NAME

C4::Auth - Authenticates Koha users

=head1 SYNOPSIS

  use C4::Auth_with_cas;

=cut

=head1 SEE ALSO

CGI(3)

Authen::CAS::Client

=cut
