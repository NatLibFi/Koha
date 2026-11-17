#!/usr/bin/perl

use Modern::Perl;
use Test::More;
use Test::NoWarnings 'had_no_warnings';
use FindBin;
use Cwd         qw(abs_path);
use File::Temp  qw(tempdir);
use Digest::SHA qw(sha256);
use JSON::PP    qw(decode_json);
use POSIX       qw(WNOHANG mkfifo);
use Time::HiRes qw(time sleep);

my $root   = abs_path("$FindBin::Bin/..");
my $script = "$root/debian/scripts/koha-opac-pow";
my $tmp    = tempdir( CLEANUP => 1 );
my $key    = 'x' x 32;                               # Public fixture, never a deployed signing key.
my $hex    = unpack 'H*', $key;
my $serial = 0;
my $ip     = '192.0.2.10';
my $site   = 'catalogue.example';

sub write_file {
    my ( $path, $value, $mode ) = @_;
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $value;
    close $fh or die $!;
    chmod $mode // oct('0600'), $path or die $!;
}

sub contents {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die $!;
    local $/;
    return scalar <$fh> // '';
}

sub counter_for {
    my ($challenge) = @_;
    my @parts       = split /\./, $challenge;
    for ( 0 .. 65535 ) {
        return $_ if substr( unpack( 'B*', sha256("$parts[4]:$_") ), 0, $parts[3] ) eq '0' x $parts[3];
    }
    die 'No independent test work found';
}

# Real executable and file descriptors, with a bounded independent deadline.
# No external service, installed configuration or Koha database is used.
sub run_helper {
    my ( $input, @args ) = @_;
    my $prefix = "$tmp/run-" . ++$serial;
    write_file( "$prefix.in", $input );
    my $pid = fork();
    die 'Cannot fork helper fixture' unless defined $pid;
    if ( !$pid ) {
        open STDIN,  '<:raw', "$prefix.in"  or die $!;
        open STDOUT, '>:raw', "$prefix.out" or die $!;
        open STDERR, '>:raw', "$prefix.err" or die $!;
        exec( $^X, '-I', $root, $script, @args ) or POSIX::_exit(127);
    }
    my $deadline = time + 5;
    while ( waitpid( $pid, WNOHANG ) == 0 ) {
        if ( time >= $deadline ) {
            kill 'KILL', $pid;
            waitpid( $pid, 0 );
            die 'Helper fixture exceeded deadline';
        }
        sleep 0.01;
    }
    my $status = $?;
    return ( contents("$prefix.out"), contents("$prefix.err"), $status );
}

write_file( "$tmp/keys", "$hex\n" );

subtest 'real line protocol recovers after invalid and oversized input' => sub {
    my $input = "unknown!$ip!$site\n" . ( 'x' x 12000 ) . "\nissue!$ip!$site\n";
    my ( $out, $err, $status ) = run_helper( $input, '--key-file', "$tmp/keys", '--difficulty', 4 );
    is( $status, 0, 'Protocol process exits normally at EOF' );
    my @lines = split /\n/, $out;
    is( scalar @lines, 3,      'One response per complete frame' );
    is( $lines[0],     'NULL', 'Unknown operation refused' );
    is( $lines[1],     'NULL', 'Oversized frame refused' );
    like( $lines[2], qr/\Aq1\./, 'Next valid frame still works' );
    my @parts = split /\./, $lines[2];
    is( $parts[3], '04', 'Configured difficulty reaches the protocol' );
    my $counter = counter_for( $lines[2] );
    ok( defined $counter, 'Independent work found' );
    my ($solved) = run_helper( "solve!$ip!$site!$lines[2]!$counter\n", '--key-file', "$tmp/keys", '--difficulty', 4 );
    chomp $solved;
    like( $solved, qr/\Ac1\./, 'Server issues signed clearance for real work' );
    my ($verified) = run_helper(
        "verify!$ip!$site!$solved\nverify!192.0.2.11!$site!$solved\n",
        '--key-file', "$tmp/keys", '--difficulty', 4
    );
    is( $verified, "ok\nNULL\n", 'Clearance accepted only for its client' );
    unlike( $err, qr/\Q$ip\E|\Q$site\E|\Q$hex\E|[qc]1\./, 'Diagnostics contain no request or key material' );
    my @events = map { decode_json($_) } split /\n/, $err;
    is( scalar @events, 1, 'One bounded summary at EOF' );
    is_deeply( $events[0]{counts}, { input_invalid => 2, issue_pass => 1 }, 'Summary contains finite event counters' );
};

subtest 'policy defaults and optional overrides' => sub {
    my ($out) = run_helper( "issue!$ip!$site\n", '--key-file', "$tmp/keys" );
    my @parts = split /\./, $out;
    is( $parts[3], '16', 'No policy arguments uses the default difficulty' );
    my $before = int time;
    ($out) = run_helper(
        "issue!$ip!$site\n", '--key-file', "$tmp/keys",
        '--difficulty', 7, '--challenge-ttl', 17, '--clearance-ttl', 73
    );
    @parts = split /\./, $out;
    is( $parts[3], '07', 'Explicit difficulty is used' );
    ok( $parts[2] >= $before + 17 && $parts[2] <= int(time) + 17, 'Explicit challenge lifetime is used' );
    chomp $out;
    my $proof = counter_for($out);
    $before = int time;
    my ($clearance) = run_helper(
        "solve!$ip!$site!$out!$proof\n", '--key-file', "$tmp/keys",
        '--difficulty', 7, '--challenge-ttl', 17, '--clearance-ttl', 73
    );
    @parts = split /\./, $clearance;
    ok( $parts[2] >= $before + 73 && $parts[2] <= int(time) + 73, 'Explicit clearance lifetime is used' );
    for my $policy (
        [ '--difficulty',    0 ], [ '--difficulty', 25 ], [ '--challenge-ttl', 601 ],
        [ '--clearance-ttl', 86401 ]
        )
    {
        my ($value) = run_helper( "issue!$ip!$site\n", '--key-file', "$tmp/keys", @$policy );
        is( $value, "NULL\n", 'Invalid policy never issues a challenge' );
    }
};

subtest 'unsafe or missing key files fail closed without blocking' => sub {
    write_file( "$tmp/public-keys", "$hex\n", oct('0666') );
    write_file( "$tmp/invalid-keys", "sensitive-key-marker\n" );
    symlink "$tmp/keys", "$tmp/symlink-keys" or die $!;
    mkfifo( "$tmp/fifo-keys", 0600 ) or die $!;
    for my $path ( 'missing', 'public-keys', 'invalid-keys', 'symlink-keys', 'fifo-keys', '.' ) {
        my ( $out, $err, $status ) = run_helper( "issue!$ip!$site\n", '--key-file', "$tmp/$path" );
        is( $out,    "NULL\n", 'Unsafe ring refuses request' );
        is( $status, 0,        'Unavailable verifier keeps its line protocol' );
        unlike(
            $err, qr/\Q$hex\E|sensitive-key-marker|\Q$tmp\E/,
            'Failure diagnostic does not expose file contents or path'
        );
    }
};

subtest 'installation provisions once and preserves existing rings' => sub {
    my $group = getgrgid( ( stat "$tmp/keys" )[5] );
    my $path  = "$tmp/provisioned";
    my ( $out, $err, $status ) = run_helper( '', '--init-key', '--key-file', $path, '--key-group', $group );
    is( $status,     0,  'Installation mode succeeds' );
    is( $out . $err, '', 'Installation prints no key material' );
    ok( -f $path, 'Key ring published' );
    my $value = contents($path);
    ok( $value =~ /\A[0-9a-f]{64}\n\z/, 'Key file has the required format' );
    is( ( stat $path )[2] & oct('0777'), oct('0640'),             'Key has restricted group-readable mode' );
    is( ( stat $path )[5],               ( stat "$tmp/keys" )[5], 'Key has the configured Apache group' );
    my $inode = ( stat $path )[1];
    ( $out, $err, $status ) = run_helper( '', '--init-key', '--key-file', $path, '--key-group', $group );
    is( $status, 0, 'Repeated installation succeeds' );
    ok( contents($path) eq $value, 'Repeated installation preserves the key' );
    is( ( stat $path )[1], $inode, 'Existing ring is not replaced' );
    my $rotated = ( '79' x 32 ) . "\n$hex\n";
    write_file( $path, $rotated, oct('0640') );
    ( $out, $err, $status ) = run_helper( '', '--init-key', '--key-file', $path, '--key-group', $group );
    is( $status, 0, 'Existing active/previous ring accepted' );
    ok( contents($path) eq $rotated, 'Rotation order and bytes preserved' );
    ( $out, $err, $status ) = run_helper( '', '--init-key', '--key-file', "$tmp/symlink-keys", '--key-group', $group );
    isnt( $status, 0, 'Installation refuses an unsafe existing ring' );
    ok( -l "$tmp/symlink-keys" && contents("$tmp/keys") eq "$hex\n", 'Unsafe ring and its target were not changed' );
    my @temporary = glob "$tmp/.antibot-*";
    is( scalar @temporary, 0, 'Installation cleans its unpublished temporary files' );
};

had_no_warnings();
done_testing();
