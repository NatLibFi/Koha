#!/usr/bin/perl

use Modern::Perl;
use Test::More;
use Test::NoWarnings 'had_no_warnings';
use Digest::SHA qw(sha256);
use Time::Local qw(timelocal);
use FindBin;
use lib "$FindBin::Bin/..";
use Koha::Antibot;

my $now  = timelocal( 0, 0, 12, 15, 10, 126 );
my $ip   = '192.0.2.10';
my $site = 'catalogue.example';
my $key  = 'x' x 32;
my $pow  = Koha::Antibot->new( keys => [$key], difficulty => 4 );

# Independently compute the submitted work, rather than using the verifier.
sub counter_for {
    my ( $challenge, $wanted ) = @_;
    my @parts = split /\./, $challenge;
    for my $counter ( 0 .. 65535 ) {
        my $bits  = unpack( 'B*', sha256( $parts[4] . ':' . $counter ) );
        my $valid = substr( $bits, 0, $parts[3] ) eq '0' x $parts[3];
        return "$counter" if $valid == $wanted;
    }
    die 'No test proof found';
}

subtest 'issue, solve and reuse without Koha' => sub {
    my $q = $pow->challenge( $ip, $site, $now );
    ok( $q, 'Server issued a challenge' );
    isnt( $pow->challenge( $ip, $site, $now ), $q, 'Challenges contain fresh randomness' );
    my $counter = counter_for( $q, 1 );
    my $cookie  = $pow->solve( $q, $counter, $ip, $site, $now + 1 );
    ok( $cookie,                                                    'Server accepted independently calculated work' );
    ok( $pow->verify_clearance( $cookie, $ip, $site, $now + 2 ),    'First request admitted' );
    ok( $pow->verify_clearance( $cookie, $ip, $site, $now + 3 ),    'Clearance reused' );
    ok( !$pow->solve( $q, counter_for( $q, 0 ), $ip, $site, $now ), 'Wrong work refused' );
    ok( !$pow->verify_clearance( '1', $ip, $site, $now ),           'The old public cookie is not clearance' );
    ok( !$INC{'Koha/Database.pm'} && !$INC{'C4/Context.pm'},        'No Koha configuration or database loaded' );
};

subtest 'all authenticated fields and client context matter' => sub {
    my $q       = $pow->challenge( $ip, $site, $now );
    my $counter = counter_for( $q, 1 );
    my $cookie  = $pow->solve( $q, $counter, $ip, $site, $now );
    my @parts   = split /\./, $q;
    my @changes = (
        [ 0, 'c1' ],     [ 1, '20261114' ], [ 2, $now + 121 ], [ 3, '03' ],
        [ 4, '0' x 32 ], [ 5, '0' x 16 ],   [ 6, '0' x 64 ]
    );
    for my $change (@changes) {
        my @bad = @parts;
        $bad[ $change->[0] ] = $change->[1];
        ok(
            !$pow->solve( join( '.', @bad ), $counter, $ip, $site, $now + 10 ),
            "Changed challenge field $change->[0] refused"
        );
    }
    for my $other ( [ '192.0.2.11', $site ], [ $ip, 'other.example' ] ) {
        ok( !$pow->solve( $q, $counter, @$other, $now ),       'Challenge cannot move between contexts' );
        ok( !$pow->verify_clearance( $cookie, @$other, $now ), 'Clearance cannot move between contexts' );
    }
    my @clearance = split /\./, $cookie;
    for my $index ( 0 .. $#clearance ) {
        my @bad = @clearance;
        substr( $bad[$index], -1, 1 ) = substr( $bad[$index], -1 ) eq '0' ? '1' : '0';
        ok(
            !$pow->verify_clearance( join( '.', @bad ), $ip, $site, $now + 10 ),
            "Changed clearance field $index refused"
        );
    }
    ok( $pow->verify_clearance( $cookie, $ip, uc($site), $now ), 'DNS names are case insensitive' );
};

subtest 'expiry, midnight, policy changes and key rotation' => sub {
    my $q       = $pow->challenge( $ip, $site, $now );
    my $counter = counter_for( $q, 1 );
    ok( !$pow->solve( $q, $counter, $ip, $site, $now + 120 ), 'Challenge expires inclusively' );
    my $cookie = $pow->solve( $q, $counter, $ip, $site, $now );
    ok( !$pow->verify_clearance( $cookie, $ip, $site, $now + 3600 ), 'Clearance expires inclusively' );
    my $different = Koha::Antibot->new( keys => [$key], difficulty => 5 );
    ok( !$different->solve( $q, $counter, $ip, $site, $now ), 'Server policy controls difficulty' );

    my $rotated = Koha::Antibot->new( keys => [ 'y' x 32, $key ], difficulty => 4 );
    ok( $rotated->verify_clearance( $cookie, $ip, $site, $now ), 'Previous key accepted during rotation' );
    my $new = $rotated->solve( $q, $counter, $ip, $site, $now );
    ok( $new && !$pow->verify_clearance( $new, $ip, $site, $now ), 'New clearances use the active key' );
    my $retired = Koha::Antibot->new( keys => [ 'y' x 32 ], difficulty => 4 );
    ok( !$retired->verify_clearance( $cookie, $ip, $site, $now ), 'Retired key refused' );

    my $midnight      = timelocal( 59, 59, 23, 15, 10, 126 );
    my $night_q       = $pow->challenge( $ip, $site, $midnight );
    my $night_counter = counter_for( $night_q, 1 );
    my $night_cookie  = $pow->solve( $night_q, $night_counter, $ip, $site, $midnight );
    ok( !$pow->solve( $night_q, $night_counter, $ip, $site, $midnight + 2 ), 'Midnight requires a new challenge' );
    ok(
        !$pow->verify_clearance( $night_cookie, $ip, $site, $midnight + 2 ),
        'The Apache date prefix agrees with expiry policy'
    );
};

subtest 'malformed input, counter bounds and IPv6' => sub {
    my $q       = $pow->challenge( $ip, $site, $now );
    my $counter = counter_for( $q, 1 );
    for my $bad ( undef, '', '0' x 10000, "$q\n", "$q.extra", 'CGISESSID=anything' ) {
        ok( !$pow->solve( $bad, $counter, $ip, $site, $now ),  'Malformed challenge refused' );
        ok( !$pow->verify_clearance( $bad, $ip, $site, $now ), 'Malformed clearance refused' );
    }
    for my $bad ( undef, '-1', '01', '1.0', '1e2', '4294967296', '9' x 10000, "1\n" ) {
        ok( !$pow->solve( $q, $bad, $ip, $site, $now ), 'Counter must be canonical and bounded' );
    }
    for my $other ( [ '', $site ], [ '999.2.3.4', $site ], [ $ip, "bad\nsite" ], [ '192.0.2.10!x', $site ] ) {
        ok( !$pow->challenge( @$other, $now ), 'Invalid context refused' );
    }
    my $v6_q      = $pow->challenge( '2001:db8::1', $site, $now );
    my $v6_cookie = $pow->solve( $v6_q, counter_for( $v6_q, 1 ), '2001:db8::1', $site, $now );
    ok(
        $pow->verify_clearance( $v6_cookie, '2001:db8:0:0:0:0:0:1', $site, $now ),
        'Equivalent IPv6 addresses share context'
    );
    ok( !$pow->verify_clearance( $v6_cookie, '2001:db8::2', $site, $now ), 'Another IPv6 address refused' );
};

subtest 'whole and partial leading-byte difficulties' => sub {
    for my $difficulty ( 1, 7, 8, 9 ) {
        my $p = Koha::Antibot->new( keys => [$key], difficulty => $difficulty );
        my $q = $p->challenge( $ip, $site, $now );
        ok( $p->solve( $q,  counter_for( $q, 1 ), $ip, $site, $now ), "Valid $difficulty-bit work accepted" );
        ok( !$p->solve( $q, counter_for( $q, 0 ), $ip, $site, $now ), "Invalid $difficulty-bit work refused" );
    }
};

had_no_warnings();
done_testing();
