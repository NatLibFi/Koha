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
use Mojo::UserAgent;

our %STAT_CONFIG = (
    alert_long_load_time => 45,
    alert_huge_memory_delta => 1024 * 100,
    alert_maxmemsize     => undef,
    restart_maxmemsize   => 400 * 1024,
    log_startstops       => undef,
    log_slack_sent_oks   => undef,
    slack_hash           => undef,
    dump_code            => undef,
);
our %STATS = (
    child_requests    => 0,
    child_start       => Time::HiRes::time(),
    child_quit_reason => 'unknown',
);

my $hostname = `hostname`;

# $STAT_CONFIG{slack_hash} = '';

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

my @slack_messages;

sub _push_slack_message {
    my $mode    = shift;
    my $message = shift;
    push @slack_messages,
      { mode    => $mode,
        message => $message,
      };
    return;
}

sub _send_slack_messages {

    my @blocks      = ();
    my @attachments = ();
    my @fields      = ();

    return unless @slack_messages;

    my $icon_emoji  = ':gear:';
    my $status_name = 'STAT';
    foreach my $m (@slack_messages) {
        if ( $m->{mode} eq 'die' ) {
            $icon_emoji  = ':bangbang:';
            $status_name = 'ERROR';
        } elsif ( $m->{mode} eq 'warn' ) {
            $icon_emoji  = ':warning:';
            $status_name = 'WARN';
        }

        # push @blocks, { type => "divider" } if @blocks;
        $m->{message} =~ s/^\n+|\n+$//g;

        if ( length( $m->{message} ) > 1536 ) {
            $m->{message} =~ s/\A(.{0,1024}).+( +POST: \S+\s+pid:\d+ [\d.\[\]]+s .+| +pid:\d+ [\d.\[\]]+s CALLERS:.+)\Z/$1\n\n...\n\n$2/ms
              or $m->{message} = substr( $m->{message}, 0, 1536 ) . ' ...';
        }

        push @blocks,
          { type => "section",
            text => {
                type => "mrkdwn",
                text => "```\n" . $m->{message} . "\n```",
            }
          };
    }

    my $ua = Mojo::UserAgent->new;
    $ua->connect_timeout(6);
    $ua->inactivity_timeout(15);
    my $res = $ua->post(
        'https://hooks.slack.com/services/' . $STAT_CONFIG{slack_hash} => { Accept => 'application/json' },
        json                                                     => {

            # channel    => '@nugged',
            username   => $status_name . ': ' . $hostname,
            icon_emoji => $icon_emoji,
            text       => $slack_messages[$#slack_messages]->{message},
            blocks     => [
                {   type => "header",
                    text => {
                        type => "plain_text",
                        text => POSIX::strftime( "%Y-%m-%d %H:%M:%S", localtime )
                    },
                },
                @blocks,
            ],
        }
    )->result;

    @slack_messages = ();

    return unless $STATS{log_slack_sent_oks};

    if ( $res->is_success ) {
        my $body = $res->body;
        chomp $body;
        if ( $body eq 'ok' ) {
            say STDERR "... Slack message sent.";
        } else {
            say STDERR "MESSAGE NOT SENT: $body";
        }
    } elsif ( $res->is_error ) {
        say STDERR $res->message;
    } elsif ( $res->code == 301 ) {
        say STDERR $res->headers->location;
    } else {
        say STDERR 'Whatever...';
    }

    return;
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

    if( $STAT_CONFIG{dump_code} ) {
        push @_, quote_dump_code($_[$#@]);
    }

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

    _push_slack_message( $mode, $message ) if $STAT_CONFIG{slack_hash} and !$stats->{ignore_warning};

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

sub quote_dump_code {
    my $error_line = shift;
    if( $error_line =~ / at (\S+) line (\d+).$/ ) {
        my $src_file     = $1;
        my $line_no      = $2;
        my $lines_before = $STAT_CONFIG{dump_code}{lines_before};
        my $lines_after  = $STAT_CONFIG{dump_code}{lines_after};
        if ( open my $fh, '<', $src_file ) {
            my @lines_from_file;
            while (<$fh>) {
                if ( $. >= $line_no - $lines_before and $. <= $line_no + $lines_after ) {
                    chomp $_;
                    push @lines_from_file, sprintf("  %4d:  %s", $., $_);
                }
                last if $. == $line_no + $lines_after;
            }
            close $fh;
            if (@lines_from_file) {
                local $" = "\n";
               return "<perl>\n@lines_from_file\n</perl>\n\n";
            } else {
               return "EXTRA: Line $line_no in source file $src_file not found.";
            }
        } else {
           return "EXTRA: Can't open file $src_file: $!";
        }
    }
    return ();
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
            or $_[0] =~ /Use of uninitialized value \$PDF::Reuse::objekt/
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

    _send_slack_messages() if $STAT_CONFIG{slack_hash};
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
    Koha::Middleware::NugDebugLogWarnDie::_send_slack_messages() if $Koha::Middleware::NugDebugLogWarnDie::STAT_CONFIG{slack_hash};
}

1;
