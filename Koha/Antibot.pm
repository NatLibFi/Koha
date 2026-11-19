package Koha::Antibot;

# Copyright 2026 Nugged Team
#
# This file is part of Koha, distributed under the GNU GPL version 3 or later.

use Modern::Perl;
use Digest::SHA           qw(hmac_sha256_hex sha256 sha256_hex);
use Mojo::Util            qw(secure_compare);
use Bytes::Random::Secure qw(random_bytes);
use POSIX                 qw(strftime);
use Socket                qw(AF_INET AF_INET6 inet_pton);

=head1 NAME

Koha::Antibot - Database-independent OPAC proof-of-work and clearance tokens

=head1 DESCRIPTION

The Apache prefilter checks the public date and token shape. This module
authenticates those fields and the client context before accepting a token.
It never loads Koha configuration, sessions or a database connection.

=cut

=head2 new

Construct a verifier from one or two raw 32-byte keys and optional difficulty,
challenge_ttl and clearance_ttl policy. The first key issues tokens. Invalid
keys or policy cause an exception; no configuration or database is read.

=cut

sub new {
    my ( $class, %args ) = @_;
    my $keys = $args{keys};
    die "Invalid antibot key ring\n"
        unless ref($keys) eq 'ARRAY'
        && @$keys
        && @$keys <= 2
        && !grep { !defined($_) || length($_) != 32 } @$keys;

    my %ring;
    my $active;
    for my $key (@$keys) {
        my $id = substr( sha256_hex($key), 0, 16 );
        die "Duplicate antibot key identifier\n" if exists $ring{$id};
        $active //= $id;
        $ring{$id} = $key;
    }

    my %policy = (
        difficulty    => $args{difficulty}    // 16,
        challenge_ttl => $args{challenge_ttl} // 120,
        clearance_ttl => $args{clearance_ttl} // 3600,
    );
    for my $field ( keys %policy ) {
        die "Invalid antibot policy\n"
            unless defined $policy{$field} && $policy{$field} =~ /\A[1-9][0-9]{0,5}\z/;
    }
    die "Invalid antibot policy\n"
        if $policy{difficulty} > 24 || $policy{challenge_ttl} > 600 || $policy{clearance_ttl} > 86400;

    return bless { keys => \%ring, active => $active, %policy }, $class;
}

=head2 _context

Validate and normalize the full client address and configured instance name
into the authenticated context. Invalid input returns no value.

=cut

sub _context {
    my ( $ip, $site ) = @_;
    return unless defined $ip && defined $site && length($ip) <= 45;
    return unless $ip =~ /\A[0-9a-fA-F:.]+\z/ && $site =~ /\A[a-zA-Z0-9_.-]{1,253}\z/;
    my $packed = inet_pton( AF_INET, $ip ) // inet_pton( AF_INET6, $ip );
    return unless defined $packed;
    return unpack( 'H*', $packed ) . "\0" . lc($site);
}

=head2 _date

Return the server-local calendar date for the supplied server timestamp.

=cut

sub _date {
    my ($now) = @_;
    return strftime( '%Y%m%d', localtime($now) );
}

=head2 _sign

Authenticate the token body and client context using the selected ring key.

=cut

sub _sign {
    my ( $self, $body, $context, $id ) = @_;
    return hmac_sha256_hex( "koha-antibot\0$body\0$context", $self->{keys}{$id} );
}

=head2 _issue

Build a challenge or clearance with a fresh random nonce and signed policy,
expiry and context. The caller supplies the token kind and server timestamp.

=cut

sub _issue {
    my ( $self, $kind, $ip, $site, $now ) = @_;
    my $context = _context( $ip, $site );
    return unless defined $context;
    my $ttl    = $self->{ $kind eq 'q1' ? 'challenge_ttl' : 'clearance_ttl' };
    my @fields = ( $kind, _date($now), sprintf( '%010d', $now + $ttl ), sprintf( '%02d', $self->{difficulty} ) );
    push @fields, unpack( 'H*', random_bytes(16) ), $self->{active};
    my $body = join '.', @fields;
    return $body . '.' . $self->_sign( $body, $context, $self->{active} );
}

=head2 challenge

    my $token = $antibot->challenge( $client_ip, $site, $now );

Issue a random authenticated challenge. The timestamp is supplied by the
server; callers must not pass a timestamp taken from the request.

=cut

sub challenge {
    my ( $self, $ip, $site, $now ) = @_;
    return $self->_issue( 'q1', $ip, $site, $now // time );
}

=head2 _authenticate

Validate the exact token kind, shape, current date, expiry, policy and HMAC
for its client context. Return authenticated fields or no value on rejection.

=cut

sub _authenticate {
    my ( $self, $kind, $token, $ip, $site, $now ) = @_;
    return unless defined $token && length($token) <= 140;
    my $context = _context( $ip, $site );
    return unless defined $context;

    my @parts =
        $token =~ /\A(q1|c1)\.([0-9]{8})\.([0-9]{10})\.([0-9]{2})\.([0-9a-f]{32})\.([0-9a-f]{16})\.([0-9a-f]{64})\z/;
    return unless @parts && $parts[0] eq $kind;
    my ( undef, $date, $expires ) = @parts;
    return unless $date eq _date($now) && $expires > $now;
    my $ttl = $self->{ $kind eq 'q1' ? 'challenge_ttl' : 'clearance_ttl' };
    return if $expires > $now + $ttl;
    return if $parts[3] != $self->{difficulty};
    my $tag = pop @parts;
    my $id  = $parts[-1];
    return unless exists $self->{keys}{$id};
    my $expected = $self->_sign( join( '.', @parts ), $context, $id );
    return unless secure_compare( $tag, $expected );
    return \@parts;
}

=head2 verify_clearance

Verify signature, expiry, current server-local date, client IP and site.
A valid token can be reused by the same client until its expiry or midnight,
whichever comes first. Changing IP requires a new challenge.

=cut

sub verify_clearance {
    my ( $self, $token, $ip, $site, $now ) = @_;
    return $self->_authenticate( 'c1', $token, $ip, $site, $now // time ) ? 1 : 0;
}

=head2 solve

    my $clearance = $antibot->solve( $challenge, $counter, $ip, $site, $now );

Check one SHA-256 of the authenticated seed, a colon, and the canonical
decimal counter. The client never supplies a trusted hash or difficulty.

=cut

sub solve {
    my ( $self, $token, $counter, $ip, $site, $now ) = @_;
    $now //= time;
    return unless defined $counter && $counter =~ /\A(?:0|[1-9][0-9]{0,9})\z/ && $counter <= 4294967295;
    my $parts = $self->_authenticate( 'q1', $token, $ip, $site, $now );
    return unless $parts;

    my $hash = sha256( $parts->[4] . ':' . $counter );
    my $bits = unpack( 'B*', $hash );
    return unless substr( $bits, 0, $self->{difficulty} ) eq '0' x $self->{difficulty};
    return $self->_issue( 'c1', $ip, $site, $now );
}

1;
