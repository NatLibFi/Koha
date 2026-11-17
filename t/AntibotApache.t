#!/usr/bin/perl

use Modern::Perl;
use open qw(:std :encoding(UTF-8));
use Test::More;
use Test::NoWarnings 'had_no_warnings';
use FindBin;
use File::Temp qw(tempdir);
use Cwd        qw(abs_path);
use IPC::Cmd   qw(can_run);
use IO::Socket::INET;
use LWP::UserAgent;
use HTTP::Request;
use URI;
use Digest::SHA qw(sha256 sha256_hex);
use POSIX       qw(strftime WNOHANG setsid);
use B           qw(perlstring);
use Time::HiRes qw(sleep);

my $root  = abs_path("$FindBin::Bin/..");
my $httpd = $ENV{KOHA_ANTIBOT_HTTPD} || can_run('apache2') || can_run('httpd');
plan skip_all => 'Apache httpd is required for this integration test' unless $httpd;
my ($modules) = grep { -f "$_/mod_rewrite.so" }
    ( $ENV{KOHA_ANTIBOT_MODULE_DIR} // (), '/usr/lib/apache2/modules', '/usr/libexec/apache2' );
plan skip_all => 'Apache module directory unavailable' unless $modules;

my $tmp = tempdir( 'koha-antibot-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
my $pid;

sub write_file {
    my ( $path, $text, $mode ) = @_;
    open my $fh, '>:raw', $path or die "Cannot create fixture: $!";
    print {$fh} $text;
    close $fh;
    chmod $mode // oct('0600'), $path or die "Cannot protect fixture: $!";
}

sub contents {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<:raw', $path or die $!;
    local $/;
    return scalar <$fh>;
}

sub port {
    my $socket = IO::Socket::INET->new( LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1 )
        or die 'Cannot reserve a loopback test port';
    return $socket->sockport;
}

sub loopback_url {
    my ($port) = @_;

    # These isolated fixtures never use a public endpoint or deployed TLS keys.
    my $url = URI->new;
    $url->scheme('http');
    $url->host('127.0.0.1');
    $url->port($port);
    return $url->as_string;
}

sub count_lines {
    my ($path) = @_;
    my $text = contents($path);
    return $text =~ tr/\n//;
}

sub stop_server {
    return unless $pid;
    if ( waitpid( $pid, WNOHANG ) == 0 ) {
        kill 'TERM', $pid;
        waitpid( $pid, 0 );
    }
    $pid = undef;
}

END {
    my $saved = $?;
    stop_server();
    $? = $saved;
}

my ( $front, $back ) = ( port(), port() );
while ( $back == $front ) { $back = port(); }
my $key_file = "$tmp/keys";
my $key      = 'x' x 32;      # Deliberately public test fixture, never a deployed key.
write_file( $key_file, unpack( 'H*', $key ) . "\n" );

# Instrument the protocol boundary without modifying the real verifier.
# Only operation names are recorded; no token or client metadata is logged.
my $wrapper = '#!' . $^X . "\n" . <<'WRAPPER';
use strict; use warnings;
use IPC::Open2;
use IO::Handle;
use POSIX qw(WNOHANG);
my ($log, $perl, $root, $script, $keys, @policy) = @ARGV;
my $child = open2(my $output, my $input, $perl, '-I', $root, $script,
    '--key-file', $keys, @policy);
$input->autoflush(1); STDOUT->autoflush(1);
sub cleanup {
    return unless $child;
    close $input;
    if (waitpid($child, WNOHANG) == 0) { kill 'TERM', $child; waitpid($child, 0); }
    $child = undef;
}
$SIG{TERM} = sub { cleanup(); exit 0; };
while (my $line = <STDIN>) {
    my ($op) = $line =~ /\A(issue|solve|verify)!/;
    open my $fh, '>>', $log or die 'Cannot record test operation';
    print {$fh} ($op // 'invalid'), "\n"; close $fh;
    print {$input} $line;
    my $response = <$output>;
    last unless defined $response;
    print STDOUT $response;
}
cleanup();
WRAPPER
write_file( "$tmp/map", $wrapper, oct('0700') );
my $backend = '#!'
    . $^X . "\n"
    . 'open my $f, ">>", '
    . perlstring("$tmp/backend-calls")
    . '; print {$f} "called\n"; close $f;'
    . 'print "Content-Type: text/html\r\n\r\n<html><body id=backend-fixture>Backend fixture</body></html>";';
write_file( "$tmp/backend.cgi", $backend, oct('0700') );

my $template = $ENV{KOHA_ANTIBOT_APACHE_CONFIG} // "$root/debian/templates/apache-shared-opac-antibot.conf";
my $rules    = contents($template);
die 'Apache template is empty' unless length $rules;

# Keep the template's actual argument list; only reduce work for this fixture.
$rules =~ s/--difficulty 16/--difficulty 4/;
my $map_command = "$tmp/map $tmp/map-calls $^X $root $root/debian/scripts/koha-opac-pow $key_file";
for my $path ( $tmp, $^X, $root ) {
    die 'Fixture paths must not contain Apache quoting characters' if $path =~ /[\s"']/;
}
$rules =~
    s{^RewriteMap koha_antibot "prg:/usr/sbin/koha-opac-pow([^"\n]*)".*\n}{RewriteMap koha_antibot "prg:$map_command$1"\n}m;
write_file( "$tmp/antibot.conf", $rules );
my $unavailable_rules = $rules;
$unavailable_rules =~ s/\Q$key_file\E/$tmp\/missing-keys/;
write_file( "$tmp/unavailable.conf", $unavailable_rules );
write_file( "$tmp/dead-map", '#!' . $^X . "\nexit 0;\n", oct('0700') );
my $dead_rules = $rules;
$dead_rules =~ s{^RewriteMap koha_antibot .*\n}{RewriteMap koha_antibot "prg:$tmp/dead-map"\n}m;
write_file( "$tmp/dead.conf", $dead_rules );

open my $compiled, '-|', $httpd, '-l' or die 'Cannot inspect Apache modules';
my $static = do { local $/; scalar <$compiled> };
close $compiled;
my $load = '';
for my $name (
    qw(mpm_prefork unixd authz_core authz_host mime dir alias rewrite headers env setenvif proxy proxy_http cgi))
{
    next if $static =~ /\b(?:mod_)?\Q$name\E\.c\b/;
    plan skip_all => "Apache mod_$name is unavailable" unless -f "$modules/mod_$name.so";
    $load .= "LoadModule ${name}_module $modules/mod_$name.so\n";
}
my $group       = ( split / /, $( )[0];
my $assets      = "$root/koha-tmpl/opac-tmpl/lib/koha_fast_challenge";
my $backend_url = loopback_url($back);
my $config      = <<"CONFIG";
ServerRoot "$tmp"
DefaultRuntimeDir "$tmp"
PidFile "$tmp/httpd.pid"
ServerName localhost
Listen 127.0.0.1:$front
Listen 127.0.0.1:$back
$load
User "#$>"
Group "#$group"
StartServers 1
MinSpareServers 1
MaxSpareServers 2
ServerLimit 4
MaxRequestWorkers 4
MaxConnectionsPerChild 0
KeepAlive Off
LogLevel warn
ErrorLog "$tmp/error.log"
TypesConfig /dev/null
AddType text/html .html
AddType text/javascript .js
AddType text/css .css
<Directory />
    AllowOverride None
    Require all denied
</Directory>
<Directory "$tmp">
    Require all granted
    Options +ExecCGI
</Directory>
<Directory "$assets">
    Require all granted
</Directory>
<VirtualHost 127.0.0.1:$front>
    ServerName catalogue.example
    Define instance test_catalogue
    SetEnvIf Request_URI ^ ANTIBOT_ENABLED=1
    ErrorDocument 429 "previous-error-handler"
    RewriteEngine on
    RewriteRule ^/fixture-error\$ - [R=429,END]
    Alias /opac-tmpl/lib/koha_fast_challenge/ "$assets/"
    Include "$tmp/antibot.conf"
    ProxyPass /cgi-bin/koha $backend_url/backend
    ProxyPass /search $backend_url/backend/opac-search.pl
    ProxyPass /opac-search.pl $backend_url/backend/opac-search.pl
    ProxyPass /index.html $backend_url/backend/opac-main.pl
    ProxyPass /api/ $backend_url/backend/api/
    ProxyPassMatch ^/\$ $backend_url/backend/opac-main.pl
</VirtualHost>
<VirtualHost 127.0.0.1:$back>
    ScriptAliasMatch ^/backend/.* "$tmp/backend.cgi"
</VirtualHost>
CONFIG

# Identical rules and routes, with only the existing enable/scope flags changed.
my ($vhost) = $config =~ /(<VirtualHost 127\.0\.0\.1:\Q$front\E>.*?<\/VirtualHost>)/s;
for my $variant (qw(disabled wide unavailable custom dead)) {
    my $extra = $vhost;
    $extra =~ s/ServerName catalogue\.example/ServerName $variant.example/;
    $extra =~ s/Define instance test_catalogue/Define instance ${variant}_catalogue/;
    if ( $variant eq 'disabled' ) {
        $extra =~ s/^.*SetEnvIf Request_URI \^ ANTIBOT_ENABLED=1\n//m;
    } elsif ( $variant eq 'wide' ) {
        $extra =~ s/(SetEnvIf Request_URI \^ ANTIBOT_ENABLED=1)/$1\n    SetEnvIf Request_URI ^ ANTIBOT_ALL=1/;
    } elsif ( $variant eq 'unavailable' ) {
        $extra =~ s/antibot\.conf/unavailable.conf/;
    } elsif ( $variant eq 'dead' ) {
        $extra =~ s/antibot\.conf/dead.conf/;
    } else {
        $extra =~ s{(Include "\Q$tmp\E/antibot.conf")}
            {$1\n    RewriteMap koha_antibot "prg:$map_command --difficulty 7 --challenge-ttl 17 --clearance-ttl 73"};
    }
    $config .= "\n$extra\n";
}
write_file( "$tmp/httpd.conf", $config );

$pid = fork();
die 'Cannot fork test Apache' unless defined $pid;
if ( !$pid ) {
    setsid() >= 0 or die 'Cannot isolate test Apache process group';
    open STDOUT, '>>', "$tmp/startup.log" or die $!;
    open STDERR, '>&', \*STDOUT           or die $!;
    exec $httpd, '-f', "$tmp/httpd.conf", '-DFOREGROUND';
    die 'Cannot execute test Apache';
}
my $ua   = LWP::UserAgent->new( timeout => 5, max_redirect => 0 );
my $base = loopback_url($front);
my ( $ready, $asset_probe, $exit_status );
for ( 1 .. 50 ) {
    $asset_probe = $ua->get("$base/opac-tmpl/lib/koha_fast_challenge/index.js");
    if ( $asset_probe->code == 200 ) { $ready = 1; last; }
    if ( waitpid( $pid, WNOHANG ) == $pid ) {
        $exit_status = $?;
        $pid         = undef;
        last;
    }
    sleep 0.1;
}
unless ($ready) {
    my $errors = contents("$tmp/startup.log") . contents("$tmp/error.log");
    $errors =~ s/\b[qc]1\.[0-9a-f.]+/[test-token-redacted]/g;
    my $diagnostic =
          'Apache fixture cannot serve an asset; executable='
        . $httpd
        . '; child_status='
        . ( $exit_status // 'running' ) . ': '
        . $asset_probe->status_line . ' '
        . substr( $asset_probe->decoded_content, 0, 1200 )
        . substr( $errors, -2400 );
    $diagnostic =~ s/\s+/ /g;
    BAIL_OUT($diagnostic);
}

subtest 'cheap rejects do not invoke verifier or backend' => sub {
    my $old_date = strftime( '%Y%m%d', localtime( time - 86400 ) );
    my $fake     = join '.', 'c1', $old_date, time + 60, '04', '0' x 32, substr( sha256_hex($key), 0, 16 ), '0' x 64;
    for my $cookie (
        undef,             'CGISESSID=anything', 'KOHA_INIT=1', 'KOHA_INIT=' . 'x' x 2000,
        "KOHA_INIT=$fake", 'KOHA_INIT=1; KOHA_INIT=2'
        )
    {
        my ( $maps, $calls ) = ( count_lines("$tmp/map-calls"), count_lines("$tmp/backend-calls") );
        my $response = $ua->get( "$base/cgi-bin/koha/opac-search.pl", defined $cookie ? ( Cookie => $cookie ) : () );
        ok( $response->decoded_content                   =~ /id="challenge-status"/, 'Static challenge returned' );
        ok( ( $response->header('Cache-Control') // '' ) =~ /no-store/,              'Challenge is not cacheable' );
        is( count_lines("$tmp/map-calls"),     $maps,  'Verifier was not invoked' );
        is( count_lines("$tmp/backend-calls"), $calls, 'Backend was not invoked' );
    }
};

subtest 'valid public shape reaches only the verifier' => sub {
    my $date = strftime( '%Y%m%d', localtime(time) );
    my $fake = join '.', 'c1', $date, time + 60, '04', '0' x 32, substr( sha256_hex($key), 0, 16 ), '0' x 64;
    my ( $maps, $calls ) = ( count_lines("$tmp/map-calls"), count_lines("$tmp/backend-calls") );
    my $response = $ua->get( "$base/cgi-bin/koha/opac-search.pl", Cookie => "KOHA_INIT=$fake" );
    ok( $response->decoded_content =~ /id="challenge-status"/, 'Forged signature does not admit request' );
    is( count_lines("$tmp/map-calls"),     $maps + 1, 'One verifier lookup' );
    is( count_lines("$tmp/backend-calls"), $calls,    'No backend lookup' );
};

subtest 'POST and aliases do not bypass the gate' => sub {
    my $calls    = count_lines("$tmp/backend-calls");
    my $response = $ua->post( "$base/cgi-bin/koha/opac-search.pl", Content => 'query=example' );
    is( $response->code, 429, 'POST is refused instead of replaced or redirected' );
    for my $path ( '/search', '/opac-search.pl', '/search/example', '/' ) {
        my $r = $ua->get("$base$path");
        ok( $r->decoded_content =~ /id="challenge-status"/, 'Alias receives challenge' );
    }
    is( count_lines("$tmp/backend-calls"), $calls, 'Unverified methods and aliases never reached backend' );
};

subtest 'machine interfaces and assets retain their own policy' => sub {
    for my $path (
        '/api/v1/public', '/cgi-bin/koha/ilsdi.pl', '/cgi-bin/koha/unapi.pl',
        '/cgi-bin/koha/opac-search.pl?format=rss2'
        )
    {
        my $calls    = count_lines("$tmp/backend-calls");
        my $response = $ua->get("$base$path");
        ok( $response->decoded_content =~ /id=backend-fixture/, 'Public interface reaches backend' );
        is( count_lines("$tmp/backend-calls"), $calls + 1, 'Exactly one backend request' );
    }
    my $maps = count_lines("$tmp/map-calls");
    is( $ua->get("$base/opac-tmpl/lib/koha_fast_challenge/index.js")->code, 200,   'Challenge asset available' );
    is( count_lines("$tmp/map-calls"),                                      $maps, 'Asset did not invoke verifier' );
};

subtest 'RSS exception cannot open ordinary HTML routes' => sub {
    my $calls = count_lines("$tmp/backend-calls");
    for my $path (
        '/cgi-bin/koha/opac-detail.pl?format=rss2',
        '/cgi-bin/koha/opac-search.pl?format=html&format=rss2',
        '/cgi-bin/koha/opac-search.pl?format=rss2&format=html',
        '/cgi-bin/koha/opac-search.pl?%66ormat=html&format=rss2',
        '/cgi-bin/koha/opac-search.pl?format=rss2;format=html',
        '/cgi-bin/koha/opac-search.pl?FORMAT=rss2'
        )
    {
        my $r = $ua->get("$base$path");
        like(
            $r->decoded_content, qr/id="challenge-status"/,
            'Ambiguous or inapplicable RSS flag still requires clearance'
        );
    }
    is( count_lines("$tmp/backend-calls"), $calls, 'HTML bypass attempts never reach backend' );
    my $r = $ua->post( "$base/cgi-bin/koha/opac-search.pl?format=rss2", Content => 'format=html' );
    is( $r->code, 429, 'A POST body cannot override an excluded feed format' );
    $r = $ua->get("$base/cgi-bin/koha/opac-search.pl?format=rss&query=fixture%20query");
    like( $r->decoded_content, qr/id=backend-fixture/, 'Unambiguous feed with encoded search value remains available' );
};

subtest 'existing enable flag and optional broad scope' => sub {
    my $maps = count_lines("$tmp/map-calls");
    for my $method (qw(GET HEAD POST)) {
        my $calls = count_lines("$tmp/backend-calls");
        my $r     = $ua->request(
            HTTP::Request->new(
                $method => "$base/cgi-bin/koha/opac-search.pl",
                [ Host => 'disabled.example' ]
            )
        );
        is( $r->code,                          200,        'Disabled challenge leaves method available' );
        is( count_lines("$tmp/backend-calls"), $calls + 1, 'Disabled challenge reaches backend' );
    }
    is( count_lines("$tmp/map-calls"), $maps, 'Disabled challenge performs no verifier lookups' );
    my $error = $ua->get( "$base/fixture-error", Host => 'disabled.example' );
    like( $error->decoded_content, qr/previous-error-handler/, 'Disabled challenge preserves existing error handling' );
    my $calls = count_lines("$tmp/backend-calls");
    my $r     = $ua->get( "$base/cgi-bin/koha/opac-user.pl", Host => 'wide.example' );
    like( $r->decoded_content, qr/id="challenge-status"/, 'Broad scope challenges additional browser route' );
    is( count_lines("$tmp/backend-calls"), $calls, 'Broad browser route does not reach backend' );

    for my $path (
        '/api/v1/public', '/cgi-bin/koha/ilsdi.pl', '/cgi-bin/koha/unapi.pl',
        '/cgi-bin/koha/opac-search.pl?format=rss2'
        )
    {
        my $r = $ua->get( "$base$path", Host => 'wide.example' );
        like( $r->decoded_content, qr/id=backend-fixture/, 'Broad scope preserves machine exclusion' );
    }
    is(
        $ua->get( "$base/opac-tmpl/lib/koha_fast_challenge/index.js", Host => 'wide.example' )->code,
        200, 'Broad scope preserves challenge assets'
    );
    is( count_lines("$tmp/map-calls"), $maps, 'Broad unauthenticated paths need no verifier' );
};

subtest 'unavailable verifier fails closed before backend' => sub {
    my $calls = count_lines("$tmp/backend-calls");
    my $r     = $ua->get( "$base/opac-tmpl/lib/koha_fast_challenge/issue", Host => 'unavailable.example' );
    is( $r->code, 503, 'Missing key refuses issue with an inline error' );
    $r = $ua->get( "$base/cgi-bin/koha/opac-search.pl", Host => 'unavailable.example' );
    like( $r->decoded_content, qr/id="challenge-status"/, 'Missing key cannot admit browser' );
    is( count_lines("$tmp/backend-calls"), $calls, 'Unavailable verifier never invoked backend' );
    $r = $ua->get( "$base/opac-tmpl/lib/koha_fast_challenge/issue", Host => 'dead.example' );
    is( $r->code,                          503,    'A terminated verifier refuses issue without waiting for Koha' );
    is( count_lines("$tmp/backend-calls"), $calls, 'Dead verifier does not route error to backend' );
};

subtest 'per-instance parameters override shared defaults' => sub {
    my $before = time;
    my $r      = $ua->get( "$base/opac-tmpl/lib/koha_fast_challenge/issue", Host => 'custom.example' );
    is( $r->code, 204, 'Overridden map issues a challenge' );
    my @parts = split /\./, $r->header('X-Koha-Challenge') // '';
    is( $parts[3], '07', 'Per-instance difficulty reaches helper' );
    ok(
        @parts && $parts[2] >= $before + 17 && $parts[2] <= time + 17,
        'Per-instance challenge lifetime reaches helper'
    );
    $r = $ua->get("$base/opac-tmpl/lib/koha_fast_challenge/issue");
    @parts = split /\./, $r->header('X-Koha-Challenge') // '';
    is( $parts[3], '04', 'Other instance retains its shared policy' );
};

subtest 'real issued work, server cookie and repeat admission' => sub {
    my $response = $ua->get("$base/opac-tmpl/lib/koha_fast_challenge/issue");
    is( $response->code, 204, 'Issued a challenge without backend' );
    my $challenge = $response->header('X-Koha-Challenge');
    unless ( defined $challenge && $challenge =~ /\Aq1\./ ) {
        fail('Challenge header present');
        return;
    }
    my @parts = split /\./, $challenge;
    is( $parts[3], '04', 'Apache command supplies configured difficulty to the real helper' );
    my $counter;
    for ( 0 .. 65535 ) {
        my $bits = unpack 'B*', sha256( $parts[4] . ':' . $_ );
        if ( substr( $bits, 0, $parts[3] ) eq '0' x $parts[3] ) { $counter = $_; last; }
    }
    ok( defined $counter, 'Independently found proof' );
    my $solved = $ua->post(
        "$base/opac-tmpl/lib/koha_fast_challenge/solve",
        'X-Koha-Challenge' => $challenge, 'X-Koha-Proof' => "$counter", Content => ''
    );
    is( $solved->code, 204, 'Apache accepted real proof' );
    my $cookie = $solved->header('Set-Cookie') // '';
    ok( $cookie =~ /; Secure; HttpOnly; SameSite=Lax/,            'Browser receives hardened server cookie' );
    ok( ( $solved->header('Cache-Control') // '' ) =~ /no-store/, 'Cookie response is not cacheable' );
    my ($value) = $cookie =~ /\AKOHA_INIT=(c1\.[^;]+)/;
    unless ($value) { fail('Clearance cookie present'); return; }
    for ( 1 .. 2 ) {
        my $calls = count_lines("$tmp/backend-calls");
        my $r     = $ua->get( "$base/cgi-bin/koha/opac-search.pl", Cookie => "KOHA_INIT=$value" );
        ok( $r->decoded_content =~ /id=backend-fixture/, 'Clearance admits original request' );
        is( count_lines("$tmp/backend-calls"), $calls + 1, 'One backend request per admission' );
    }
    for my $method (qw(HEAD POST)) {
        my $before = count_lines("$tmp/backend-calls");
        my $r      = $ua->request(
            HTTP::Request->new(
                $method => "$base/cgi-bin/koha/opac-search.pl",
                [ Cookie => "KOHA_INIT=$value" ]
            )
        );
        is( $r->code,                          200,         'Valid clearance admits method without replacing request' );
        is( count_lines("$tmp/backend-calls"), $before + 1, 'Admitted method reaches backend once' );
    }
    my $parallel_before = count_lines("$tmp/backend-calls");
    my @clients;
    for ( 1 .. 2 ) {
        my $child = fork();
        die 'Cannot fork concurrent test client' unless defined $child;
        if ( !$child ) {
            my $client = LWP::UserAgent->new( timeout => 5, max_redirect => 0 );
            for ( 1 .. 3 ) {
                my $r = $client->get( "$base/cgi-bin/koha/opac-search.pl", Cookie => "KOHA_INIT=$value" );
                POSIX::_exit(1) unless $r->code == 200 && $r->decoded_content =~ /id=backend-fixture/;
            }
            POSIX::_exit(0);
        }
        push @clients, $child;
    }
    for my $child (@clients) {
        waitpid( $child, 0 );
        is( $?, 0, 'Concurrent clearance requests all completed' );
    }
    is(
        count_lines("$tmp/backend-calls"), $parallel_before + 6,
        'Concurrent admissions each reach backend exactly once'
    );
    my $calls = count_lines("$tmp/backend-calls");
    my $maps  = count_lines("$tmp/map-calls");
    $ua->get( "$base/search", Cookie => "KOHA_INIT=$value; KOHA_INIT=$value" );
    is( count_lines("$tmp/map-calls"),     $maps,  'Duplicate valid tokens rejected before verifier' );
    is( count_lines("$tmp/backend-calls"), $calls, 'Duplicate valid tokens do not admit backend' );
};

if ( my $ready_file = $ENV{KOHA_ANTIBOT_BROWSER_READY} ) {
    write_file( $ready_file, "$base\n$tmp\n" );
    diag('Waiting for the bounded browser check');
    my $deadline = time + 600;
    while ( time < $deadline && !-e "$ready_file.stop" ) {
        sleep 0.2;
    }
}
stop_server();
had_no_warnings();
done_testing();
