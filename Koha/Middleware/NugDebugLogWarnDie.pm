package Koha::Middleware::NugDebugLogWarnDie;

BEGIN {
    $Plack::Middleware::NugDebugLogWarnDie::VERSION = '0.001';
}

use Modern::Perl;
use parent                qw( Plack::Middleware );
use Plack::Util::Accessor qw( logger );
use Plack::Request;
use Scalar::Util ();
use Time::HiRes;

our %STAT_CONFIG = (
    alert_long_load_time => 45,
    alert_huge_memory_delta => 1024 * 100,
    alert_maxmemsize     => undef,
    restart_maxmemsize   => 400 * 1024,
    log_startstops       => undef,
);
our %STATS = (
    child_requests    => 0,
    child_start       => Time::HiRes::time(),
    child_quit_reason => 'unknown',
);

my $hostname = `hostname`;

if ( $STAT_CONFIG{log_startstops} ) {
    warn "Child $$ started at " . POSIX::strftime( "%Y-%m-%d %H:%M:%S", localtime )
        . "\n";
}
END {
    if ( $STAT_CONFIG{log_startstops} ) {
        warn "Child $$ quit at " . POSIX::strftime( "%Y-%m-%d %H:%M:%S", localtime )
          . ". Lifetime: " . sprintf( "%.2f days", ( Time::HiRes::time() - $STATS{child_start} ) / 86400 )
          . ". Reqs: $STATS{child_requests}. Reason: $STATS{child_quit_reason}.\n";
    }
}

sub __isa_coderef {
    ref $_[0] eq 'CODE'
      or ( Scalar::Util::reftype( $_[0] ) || '' ) eq 'CODE'
      or overload::Method( $_[0], '&{}' );
}

sub prepare_app {
    my $self = shift;
    die "'logger' is not a coderef!"
      if $self->logger and not __isa_coderef( $self->logger );
}

sub _make_message {
    my $mode  = shift;
    my $stats = shift;

    my $nowtime         = Time::HiRes::time();
    my $total_timedelta = $nowtime - $stats->{startime_mark};
    my $step_timedelta  = defined $stats->{timestep_mark} ? $nowtime - $stats->{timestep_mark} : undef;

    my $message = '';

    foreach my $m (@_) {
        if ( ref $m ) {
            $message .= Data::Dumper->new( [$m], [ __PACKAGE__ . ":" . __LINE__ ] )->Sortkeys(
                sub {
                    return [ sort { lc $a cmp lc $b } keys %{ $_[0] } ];
                }
            )->Maxdepth(4)->Indent(1)->Purity(0)->Deepcopy(1)->Dump;
        } else {
            $message .= $m;
        }
    }

    my $timings = sprintf( "%.3f", $total_timedelta ) . ( defined $step_timedelta && $total_timedelta != $step_timedelta ? sprintf( '[%.3f]', $step_timedelta ) : '' ) . 's ';

    if ( $mode ne 'warn' ) {

        my $request     = Plack::Request->new( $stats->{env} );
        my $post_params = (
            ($stats->{env}{REQUEST_METHOD} eq 'POST' or $stats->{env}{REQUEST_METHOD} eq 'PUT')
            ? " Form parameters: " . (
                $hostname =~ /-kktest\.lib\.helsinki\.fi/
                ? Data::Dumper->new( [ $request->body_parameters ], ['body_parameters'] )->Sortkeys(
                    sub {
                        return [ sort { lc $a cmp lc $b } keys %{ $_[0] } ];
                    }
                  )->Maxdepth(4)->Indent(1)->Purity(0)->Deepcopy(1)->Dump
                : join( ", ", sort keys %{ $request->body_parameters } )
              )
              . "\n"
            : ''
        );
        $post_params =~ s/^(\s+'password'\s+=>\s+').+('[^']*)$/$1\[censored\]$2/mg if $post_params;

        $message .=
            ( $stats->{res} && $stats->{res}[0] ? "PAGE GENERATED " . $stats->{res}[0] . ":\n" : '' )
          . "  $stats->{env}{REQUEST_METHOD}: $stats->{env}{REQUEST_URI}" . "\n"
          . $post_params
          . "  pid:$$ $timings"
          . ( $stats->{warns}                   ? "+$stats->{warns}w "                                                                                    : '' )
          . ( $stats->{res} && $stats->{res}[2] ? ( ref $stats->{res}[2] eq 'ARRAY' ? length( $stats->{res}[2][0] ) : length( $stats->{res}[2] ) ) . 'b ' : '' )
          . sprintf( "Mem %.1f", $stats->{memory} / 1024 )
          . ( $stats->{memory_delta} ? sprintf( "[%+.1f]", $stats->{memory_delta} / 1024 ) : '' )
          . "Mb $STATS{child_requests} rqs.\n"
          . ( $stats->{memory} > $STAT_CONFIG{restart_maxmemsize} ? "Restarting child: $STAT_CONFIG{restart_maxmemsize}Kb limit.\n" : '' ) . "\n";
    } elsif ( !$stats->{ignore_warning} ) {
        $message .= "  pid:$$ $timings" . _get_callers( 4, 6 );
    }
    return $message;
}

sub _get_vm_stats {
    state %stats_prev;
    my %stats;

    open( my $f, '<', '/proc/self/status' ) or die "Unable to get self stats";
    while (<$f>) {
        if (/^Vm(\w+):\s+(\d+)/) {
            $stats{ lc $1 } = $2;
        }
    }
    close $f;

    delete $stats{'_diff'};
    for my $k ( keys %stats ) {
        if ( defined $stats_prev{$k} ) {
            $stats{_diff}{$k} = $stats{$k} - $stats_prev{$k};
        } else {
            $stats{_diff}{$k} = 0;
        }

        $stats_prev{$k} = $stats{$k};
    }
    return \%stats;
}

sub _memory_selfsize {
    return _get_vm_stats()->{rss};
}

sub _get_callers {
    my $start = shift // 1;
    my $depth = shift || 10;

    my @stack;
    for ( my $i = $start ; $i < $depth ; $i++ ) {
        my @c = caller($i);

        if ( !@c ) {
            last;
        } else {
            my ( $package, $filename, $line, $subroutine, $hasargs, $wantarray, $evaltext, $is_require, $hints, $bitmask, $hinthash ) = @c;

            push @stack, [ $subroutine, $package, $filename, $line ];
        }
    }

    my $l = "CALLERS:\n";
    my $i = $start;
    foreach my $c (@stack) {
        $l .= sprintf( qq~    $i: %s in %s, from %s:%d\n~, $c->[0] // '-undef-', $c->[1] // '-undef-', $c->[2] // '-undef-', $c->[3] // '-undef-', );
        $i++;
    }
    return $l;
}

sub call {
    my ( $self, $env ) = @_;
    my $logger = $self->logger || $env->{'psgix.logger'};
    die 'no psgix.logger in $env; cannot map psgi.errors to it!'
      if not $logger;

    $STATS{child_requests}++;

    my $startime_mark = Time::HiRes::time();
    my $timestep_mark = $startime_mark;
    my $warns         = 0;

    my $memory = _memory_selfsize();

    # convert to something that matches the psgi.errors specs
    $env->{'psgi.errors'} = Plack::Middleware::NugDebugLogWarnDie::LogHandle->new(
        $logger,
        {   startime_mark => $startime_mark,
            timestep_mark => undef,
            memory        => $memory,
            memory_delta  => undef,
            warns         => undef,
            env           => $env,
            res           => undef,
        }
    );

    local $SIG{__WARN__} = sub {
        my $memory_new   = _memory_selfsize();
        my $memory_delta = $memory_new - $memory;
        $memory = $memory_new;

        my $ignore_warning = $_[0]
          && ( $_[0] =~ /C4::Reports::Guided::execute_query/
            or $_[0] =~ /\[NTWIP\]/ );

        ++$warns unless $ignore_warning;

        $env->{'psgix.logger'}->(
            {   level   => 'warn',
                message => _make_message(
                    'warn',
                    {   startime_mark  => $startime_mark,
                        timestep_mark  => $timestep_mark,
                        memory         => $memory,
                        memory_delta   => $memory_delta,
                        warns          => $warns,
                        env            => $env,
                        res            => undef,
                        ignore_warning => $ignore_warning,
                    },
                    @_
                ),
            }
        );
        $timestep_mark = Time::HiRes::time();
    };

    my $res = $self->app->($env);

    my $endtime_mark    = Time::HiRes::time();
    my $total_timedelta = $endtime_mark - $startime_mark;

    my $memory_new   = _memory_selfsize();
    my $memory_delta = $memory_new - $memory;
    $memory = $memory_new;

    my $is_memory_overgrown = $memory > $STAT_CONFIG{restart_maxmemsize};
    my $is_long_gentime = $total_timedelta > $STAT_CONFIG{alert_long_load_time};
    my $is_big_memdelda = $memory_delta > $STAT_CONFIG{alert_huge_memory_delta};

    # disable big memory delta or long time reports for particular URLs:
    if ( $env->{REQUEST_URI} =~ m{^/intranet/reports/guided_reports\.pl} ) {
        $is_long_gentime = 0;
    }
    elsif ( $env->{REQUEST_URI} =~ m{^/intranet/(about|circ/pendingreserves)\.pl} ) {
        $is_big_memdelda = 0;
    }

    if (   $warns > 0
        or $is_long_gentime or $is_big_memdelda
        or $STAT_CONFIG{alert_maxmemsize} and $is_memory_overgrown
    ) {

        $env->{'psgix.logger'}->(
            {   level   => 'warn',
                message => _make_message(
                    'stat',
                    {   startime_mark => $startime_mark,
                        timestep_mark => $timestep_mark,
                        memory        => $memory,
                        memory_delta  => $memory_delta,
                        warns         => $warns,
                        env           => $env,
                        res           => $res,
                    },
                    ''
                ),
            }
        );
    }

    if ( $is_memory_overgrown ) {
        $STATS{child_quit_reason} = 'oversized, ' . sprintf( "%.1fMb", $memory / 1024 ) . "\n";
        kill 1, $$;
    }

    return $res;
}

package    # hide from PAUSE
  Plack::Middleware::NugDebugLogWarnDie::LogHandle;

# ABSTRACT: convert psgix.logger-like logger into an IO::Handle-like object

sub new {
    my ( $class, $logger, $stats ) = @_;
    return bless { logger => $logger, _stats => $stats }, $class;
}

sub print {
    my ( $self, $message ) = @_;
    $self->{logger}->(
        {   level   => 'error',
            message => Koha::Middleware::NugDebugLogWarnDie::_make_message( 'die', $self->{_stats}, $message ),
        }
    );
}

1;
