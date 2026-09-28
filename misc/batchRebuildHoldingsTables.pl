#!/usr/bin/perl

# Small script that rebuilds the non-MARC Holdings DB

use Modern::Perl;

use Getopt::Long    qw( GetOptions :config no_ignore_case bundling );
use Pod::Usage      qw( pod2usage );
use POSIX           qw( strftime );
use Scalar::Util    qw( blessed );
use Term::ANSIColor ();
use Time::HiRes     qw( time );

use Koha::Script;
use Koha::Holdings;

my $help;
my $confirm;
my $verbose = 0;
my $quiet;
my $color;
my $skip_indexing;
my $progress_step;
my $progress_step_set;
my $from_id;
my $to_id;
my @ids_options;
my @ids_file_options;

my $max_inline_retry_ids =
    env_positive_integer( 'BATCH_REBUILD_HOLDINGS_MAX_INLINE_RETRY_IDS', 50 );
my $max_retry_command_length =
    env_positive_integer( 'BATCH_REBUILD_HOLDINGS_MAX_RETRY_COMMAND_LENGTH', 1000 );
my $dense_retry_overhead_factor =
    env_positive_integer( 'BATCH_REBUILD_HOLDINGS_DENSE_RETRY_OVERHEAD_FACTOR', 10 );
my $many_failed_threshold =
    env_positive_integer( 'BATCH_REBUILD_HOLDINGS_MANY_FAILED_THRESHOLD', 200 );

GetOptions(
    'c|confirm'         => \$confirm,
    'h|?|help'          => \$help,
    'q|quiet'           => \$quiet,
    'v|verbose+'        => \$verbose,
    'color!'            => \$color,
    's|skip-indexing'   => \$skip_indexing,
    'p|progress-step=i' => \$progress_step,
    'f|from-id=i'       => \$from_id,
    't|to-id=i'         => \$to_id,
    'ids=s@'            => \@ids_options,
    'ids-file=s@'       => \@ids_file_options,
) or pod2usage( -exitstatus => 1, -verbose => 1 );

pod2usage( -exitstatus => 0, -verbose => 1 ) if $help || !$confirm;

my @requested_holding_ids = parse_requested_holding_ids( \@ids_options, \@ids_file_options );
if ( ( @ids_options || @ids_file_options ) && !@requested_holding_ids ) {
    print STDERR "--ids and --ids-file must provide at least one holding_id\n";
    pod2usage( -exitstatus => 1, -verbose => 1 );
}

for my $range_option (
    [ '--from-id', $from_id ],
    [ '--to-id',   $to_id ],
) {
    my ( $name, $value ) = @{$range_option};
    next unless defined $value;
    if ( $value < 1 ) {
        print STDERR "$name must be a positive integer\n";
        pod2usage( -exitstatus => 1, -verbose => 1 );
    }
}

if ( defined $from_id && defined $to_id && $from_id > $to_id ) {
    print STDERR "--from-id cannot be greater than --to-id\n";
    pod2usage( -exitstatus => 1, -verbose => 1 );
}

if ( defined $progress_step && $progress_step < 1 ) {
    print STDERR "--progress-step must be a positive integer\n";
    pod2usage( -exitstatus => 1, -verbose => 1 );
}

$| = 1;    # flushes output

$verbose = 0 if $quiet;
$progress_step_set = defined $progress_step;
$progress_step //= 1000;

my $output = BatchRebuildHoldingsTables::Output->new( { color => $color } );

my $interrupted;
my $sigint_count = 0;
$SIG{INT} = sub {
    ++$sigint_count;
    if ( $sigint_count > 1 ) {
        $output->finish_status();
        $output->warn( 'Second interrupt received, exiting immediately.', 'yellow' );
        exit 130;
    }

    $interrupted = 1;
    $output->finish_status();
    $output->warn( 'Interrupt requested. Finishing current holding and stopping...', 'yellow' );
};

my $last_processed_holding_id;
my $first_failed_holding_id;
my $last_failed_holding_id;
my $next_after_holding_id = defined $from_id ? $from_id - 1 : undef;
my @failed_holdings;
my $start_time         = time();
my $started_at         = timestamp($start_time);
my $records_to_process = Koha::Holdings->search( holdings_search_params($next_after_holding_id) )->count();
my $total_records      =
    !$quiet && filter_is_limited()
    ? Koha::Holdings->search()->count()
    : $records_to_process;

print_startup_plan() unless $quiet;
$output->say( "Interactive terminal detected: " . $output->terminal_width . " columns.", 'cyan' )
    if $verbose > 1 && $output->is_interactive;
$output->say( 'Bibliographic reindexing will be skipped.', 'yellow' ) if $skip_indexing && $verbose && !$quiet;
$output->blank_line() if $verbose && !$quiet;

my $time_step_mark     = $start_time;
my $step_count_mark    = 0;
my $processed_count    = 0;
my $rebuilt_count      = 0;
my $skipped_count      = 0;
my $failed_count       = 0;
my $rows               = 1000;

while (1) {
    my $holdings = Koha::Holdings->search(
        holdings_search_params($next_after_holding_id),
        {
            order_by => { -asc => 'holding_id' },
            rows     => $rows,
        }
    );

    my $batch_count = 0;
    while ( my $holding = $holdings->next() ) {
        last if $interrupted;

        ++$batch_count;
        ++$processed_count;

        my $holding_id = $holding->holding_id();

        my $metadata   = $holding->metadata();

        if ( !$metadata ) {
            ++$skipped_count;
            $last_processed_holding_id = $holding_id;
            $next_after_holding_id = $holding_id;
            print_progress() if should_print_progress($processed_count);
            next;
        }

        my @rebuild_warnings;
        my $stored = eval {
            local $SIG{__WARN__} = sub {
                push @rebuild_warnings, @_;
            };

            my $record = $metadata->record();
            $holding->set_marc( { record => $record } );
            $holding->store( { skip_record_index => $skip_indexing } );
        };

        if ($@) {
            record_failure( $holding_id, $@, \@rebuild_warnings );
        } else {
            record_rebuild_warnings( $holding_id, \@rebuild_warnings ) if @rebuild_warnings;
            if ($stored) {
                ++$rebuilt_count;
            } else {
                record_failure( $holding_id, 'store returned no object' );
            }
        }

        $last_processed_holding_id = $holding_id;
        $next_after_holding_id = $holding_id;
        print_progress() if should_print_progress($processed_count);
    }

    last if $interrupted || !$batch_count;
}

print_progress(1) if $processed_count && $processed_count % $progress_step;
print_summary($interrupted);
print_resume_hint() if $interrupted;
print_failure_hint() if $failed_count;
exit 130 if $interrupted;
exit 1   if $failed_count;

sub parse_requested_holding_ids {
    my ( $ids_options, $ids_file_options ) = @_;

    my @tokens;
    push @tokens, @{$ids_options};

    for my $ids_file ( @{$ids_file_options} ) {
        push @tokens, read_ids_file($ids_file);
    }

    my %seen;
    my @ids;

    for my $token (@tokens) {
        next if !defined $token || $token eq q{};

        for my $id ( split /[\s,]+/, $token ) {
            next if $id eq q{};

            if ( $id !~ /^\d+\z/ || $id < 1 ) {
                print STDERR "--ids and --ids-file values must contain positive integer holding_id values\n";
                pod2usage( -exitstatus => 1, -verbose => 1 );
            }

            push @ids, $id if !$seen{$id}++;
        }
    }

    return sort { $a <=> $b } @ids;
}

sub read_ids_file {
    my ($ids_file) = @_;

    if ( $ids_file eq '-' ) {
        return <STDIN>;
    }

    open my $fh, '<', $ids_file or do {
        print STDERR "Cannot open --ids-file $ids_file: $!\n";
        pod2usage( -exitstatus => 1, -verbose => 1 );
    };
    my @lines = <$fh>;
    close $fh or do {
        print STDERR "Cannot close --ids-file $ids_file: $!\n";
        pod2usage( -exitstatus => 1, -verbose => 1 );
    };

    return @lines;
}

sub holdings_search_params {
    my ($after_holding_id) = @_;

    my %params;
    my %holding_id_filter;

    $holding_id_filter{'>'}   = $after_holding_id       if defined $after_holding_id;
    $holding_id_filter{'<='}  = $to_id                  if defined $to_id;
    $holding_id_filter{'-in'} = \@requested_holding_ids if @requested_holding_ids;

    $params{holding_id} = \%holding_id_filter if %holding_id_filter;

    return \%params;
}

sub range_is_limited {
    return defined $from_id || defined $to_id;
}

sub ids_are_limited {
    return @requested_holding_ids ? 1 : 0;
}

sub filter_is_limited {
    return range_is_limited() || ids_are_limited();
}

sub print_startup_plan {
    if ( filter_is_limited() ) {
        $output->say(
            'Processing ' . format_count($records_to_process)
                . ' selected holdings (table total: '
                . format_count($total_records) . ') ...',
            'cyan'
        );
        $output->say( 'ID filter: ' . format_filter(), 'cyan' );
        return;
    }

    $output->say( 'Processing ' . format_count($records_to_process) . ' holdings ...', 'cyan' );
}

sub record_failure {
    my ( $holding_id, $error, $warnings ) = @_;

    my $message = rebuild_error_message($error);

    ++$failed_count;
    $first_failed_holding_id //= $holding_id;
    $last_failed_holding_id = $holding_id;

    push @failed_holdings, {
        id           => $holding_id,
        processed_no => $processed_count,
    };

    $output->warn( "ERROR WITH HOLDING $holding_id: $message", 'red' );
    record_rebuild_warnings( $holding_id, $warnings, '  Suppressed warning for holding' )
        if $verbose > 1 && $warnings && @{$warnings};
    $output->warn( "  Retry this holding after fixing the problem: --ids $holding_id", 'yellow' );
}

sub rebuild_error_message {
    my ($error) = @_;

    my $message = clean_rebuild_message($error);

    if ( blessed($error) && $error->can('broken_fk') ) {
        my $broken_fk = $error->broken_fk;
        if ( defined $broken_fk && $broken_fk ne q{} && $message !~ /\Q$broken_fk\E/ ) {
            $message .= " ($broken_fk)";
        }
    }

    return $message;
}

sub record_rebuild_warnings {
    my ( $holding_id, $warnings, $label ) = @_;

    $label //= 'WARNING WITH HOLDING';

    for my $warning ( @{$warnings} ) {
        my $message = clean_rebuild_message($warning);
        next if $message eq q{};

        $output->warn( "$label $holding_id: $message", 'yellow' );
    }
}

sub clean_rebuild_message {
    my ($message) = @_;

    $message = "$message" if ref $message;
    $message //= q{};
    $message =~ s/\s+\z//;

    return $message || 'unknown error';
}

sub should_print_progress {
    my ($count) = @_;

    return $verbose && !$quiet && $count && !( $count % $progress_step );
}

sub print_progress {
    my ($force) = @_;

    return if !$verbose || $quiet;
    return if !$force && !$processed_count;

    my $now             = time();
    my $total_timedelta = $now - $start_time;
    my $step_timedelta  = $now - $time_step_mark;
    my $step_count      = $processed_count - $step_count_mark;
    my $records_left =
        $records_to_process > $processed_count
        ? $records_to_process - $processed_count
        : 0;
    my $percent     = $records_to_process ? $processed_count / $records_to_process * 100 : 100;
    my $eta_seconds = $processed_count ? $records_left * $total_timedelta / $processed_count : 0;
    my $eta_at      = substr( timestamp( $now + $eta_seconds ), 11, 5 );
    my $holding_id = defined $last_processed_holding_id ? format_count($last_processed_holding_id) : '-';
    my @parts      = progress_status_parts(
        $percent,
        format_count($processed_count),
        format_count($records_to_process),
        $holding_id,
        $failed_count,
        format_count($records_left),
        $eta_seconds,
        $eta_at
    );

    if ( $verbose > 1 ) {
        my $step_speed = $step_timedelta ? $step_count / $step_timedelta : 0;
        my $avg_speed  = $total_timedelta ? $processed_count / $total_timedelta : 0;

        splice(
            @parts,
            9,
            0,
            status_separator(),
            [ 'speed ', 'bright_black' ],
            [ sprintf( '%.1f/s', $step_speed ), 'bold cyan' ],
            [ ' last ', 'bright_black' ],
            [ format_count($step_count), 'cyan' ],
            [ '; ', 'bright_black' ],
            [ sprintf( '%.1f/s', $avg_speed ), 'cyan' ],
            [ ' avg', 'bright_black' ],
        );
    }

    $output->status_parts( \@parts );

    $time_step_mark  = $now;
    $step_count_mark = $processed_count;
}

sub progress_status_parts {
    my ( $percent, $processed, $total, $holding_id, $errors, $left, $eta_seconds, $eta_at ) = @_;

    return (
        [ sprintf( "%5.1f%%", $percent ), 'bold green' ],
        [ ' done',                       'bright_black' ],
        status_separator(),
        [ $processed,  'bold white' ],
        [ '/',         'bright_black' ],
        [ $total,      'white' ],
        status_separator(),
        [ 'id ',       'bright_black' ],
        [ $holding_id, 'bold yellow' ],
        status_separator(),
        [ 'err ', 'bright_black' ],
        [ $errors, $errors ? 'bold red' : 'green' ],
        status_separator(),
        [ 'left ', 'bright_black' ],
        [ $left,    'bold yellow' ],
        status_separator(),
        [ 'ETA ',  'bright_black' ],
        progress_duration_parts($eta_seconds),
        [ ' (~',   'bright_black' ],
        [ $eta_at, 'cyan' ],
        [ ')',     'bright_black' ],
    );
}

sub progress_duration_parts {
    my ($seconds) = @_;

    $seconds = int( $seconds + 0.5 );

    my $hours   = int( $seconds / 3600 );
    my $minutes = int( ( $seconds % 3600 ) / 60 );
    my $secs    = $seconds % 60;

    return (
        [ $hours, 'bold cyan' ],
        [ 'h',   'cyan' ],
        [ sprintf( '%02d', $minutes ), 'bold cyan' ],
        [ 'm', 'cyan' ],
    ) if $hours;

    return (
        [ $minutes, 'bold cyan' ],
        [ 'm',     'cyan' ],
        [ sprintf( '%02d', $secs ), 'bold cyan' ],
        [ 's', 'cyan' ],
    ) if $minutes;

    return (
        [ $secs, 'bold cyan' ],
        [ 's',  'cyan' ],
    );
}

sub status_separator {
    return [ ' | ', 'bright_black' ];
}

sub print_summary {
    my ($force) = @_;
    my $finished_at = timestamp();
    my $time_needed = time() - $start_time;

    return if $quiet && !$force && !$failed_count && !$skipped_count;

    my $average_speed = $time_needed ? $processed_count / $time_needed : 0;

    $output->finish_status();
    $output->blank_line() if !$quiet;
    $output->say(
        sprintf(
            'Run:       %s -> %s, %s (%.1f recs/sec avg)',
            $started_at,
            format_finished_at_for_summary($finished_at),
            format_duration($time_needed),
            $average_speed
        ),
        'cyan'
    );
    $output->say( 'Selected:  ' . format_selected_scope(), 'cyan' );
    $output->say(
        sprintf(
            'Result:    %s rebuilt, %s skipped, %s failed, %s remaining',
            format_count($rebuilt_count),
            format_count($skipped_count),
            format_count($failed_count),
            format_count(remaining_records_count())
        ),
        $failed_count ? 'red' : $skipped_count ? 'yellow' : 'green'
    );
    $output->say( 'Status:    ' . completion_status(), $failed_count || $interrupted ? 'yellow' : 'green' );
}

sub remaining_records_count {
    return 0 if $processed_count >= $records_to_process;

    return $records_to_process - $processed_count;
}

sub completion_status {
    return 'interrupted before selected range was fully processed' if $interrupted;

    return 'selected range fully processed with failures' if $failed_count;
    return 'selected range fully processed';
}

sub format_finished_at_for_summary {
    my ($finished_at) = @_;

    return substr( $finished_at, 11 ) if substr( $started_at, 0, 10 ) eq substr( $finished_at, 0, 10 );
    return $finished_at;
}

sub format_selected_scope {
    return format_count($records_to_process) . ' holdings, all ids'
        if !filter_is_limited();

    return format_count($records_to_process) . ' of '
        . format_count($total_records) . ' holdings, '
        . format_filter();
}

sub format_filter {
    my @parts;

    push @parts, format_exact_ids_filter() if ids_are_limited();
    push @parts, format_id_bounds()        if range_is_limited();

    return join '; ', @parts;
}

sub format_exact_ids_filter {
    my $requested_count = format_count( scalar @requested_holding_ids );

    return "exact ID list ($requested_count requested)";
}

sub format_id_bounds {
    my $from = defined $from_id ? format_count($from_id) : 'first';
    my $to   = defined $to_id   ? format_count($to_id)   : 'last';

    return "ids from $from to $to";
}

sub print_resume_hint {
    $output->blank_line('stderr');

    if ( defined $last_processed_holding_id ) {
        my $next_holding_id = $last_processed_holding_id + 1;

        $output->warn( "Interrupted after holding_id " . format_count($last_processed_holding_id) . ".", 'yellow' );
        if ( defined $to_id && $next_holding_id > $to_id ) {
            $output->warn( 'The requested holding_id range has no remaining records.', 'yellow' );
            return;
        }
        if ( ids_are_limited() && !remaining_requested_ids($next_holding_id) ) {
            $output->warn( 'The requested exact holding_id list has no remaining records.', 'yellow' );
            return;
        }

        $output->warn( 'Continue with:', 'yellow' );
        $output->warn( '  ' . continuation_command($next_holding_id), 'yellow' );
    } else {
        $output->warn( 'Interrupted before processing any holding.', 'yellow' );
        $output->warn( 'Continue with:', 'yellow' );
        $output->warn( '  ' . continuation_command($from_id), 'yellow' );
    }
}

sub print_failure_hint {
    $output->blank_line('stderr');

    my @failed_ids = failed_holding_ids();
    my $failed_label =
          @failed_ids == 1
        ? 'Failed holding_id: ' . format_count( $failed_ids[0] ) . '.'
        : 'Failed holdings: ' . format_count( scalar @failed_ids )
        . ' (first '
        . format_count($first_failed_holding_id)
        . '; last '
        . format_count($last_failed_holding_id) . ').';

    $output->warn( $failed_label, 'red' );

    for my $action ( failure_retry_actions() ) {
        if ( $action->{type} eq 'range' ) {
            $output->warn(
                'Retry dense failed group ('
                    . format_count( $action->{failed_count} )
                    . ' failed across '
                    . format_count( $action->{selected_span} )
                    . ' selected holdings):',
                'yellow'
            );
            $output->warn(
                '  ' . continuation_command(
                    undef,
                    {
                        from_id => $action->{from_id},
                        to_id   => $action->{to_id},
                    }
                ),
                'yellow'
            );
        } elsif ( $action->{type} eq 'ids' ) {
            my $ids_count = scalar @{ $action->{ids} };
            my $label =
                  $ids_count == 1
                ? 'Retry failed holding:'
                : 'Retry failed holdings (' . format_count($ids_count) . ' exact IDs):';

            $output->warn( $label, 'yellow' );
            $output->warn( '  ' . continuation_command( undef, { ids => $action->{ids} } ), 'yellow' );
        } elsif ( $action->{type} eq 'too_many' ) {
            $output->warn(
                'Too many sparse failed holdings ('
                    . format_count( $action->{failed_count} )
                    . ' failed across '
                    . format_count( $action->{selected_span} )
                    . ' selected holdings) to print a useful exact retry list.',
                'yellow'
            );
            $output->warn(
                'This looks like a data integrity problem; fix the data first.',
                'yellow'
            );
            $output->warn( 'Start investigation with broad failed ID range:', 'yellow' );
            $output->warn(
                '  ' . continuation_command(
                    undef,
                    {
                        from_id => $action->{from_id},
                        to_id   => $action->{to_id},
                    }
                ),
                'yellow'
            );
        }
    }
}

sub failed_holding_ids {
    return map { $_->{id} } @failed_holdings;
}

sub failure_retry_actions {
    my @groups = dense_failure_groups();
    my @actions;
    my @sparse_failures;

    for my $group (@groups) {
        if ( dense_failure_group($group) ) {
            push @actions, {
                type          => 'range',
                from_id       => $group->[0]->{id},
                to_id         => $group->[-1]->{id},
                failed_count  => scalar @{$group},
                selected_span => failure_group_selected_span($group),
            };
            next;
        }

        push @sparse_failures, @{$group};
    }

    if (@sparse_failures) {
        if ( @sparse_failures > $many_failed_threshold ) {
            push @actions, {
                type          => 'too_many',
                from_id       => $sparse_failures[0]->{id},
                to_id         => $sparse_failures[-1]->{id},
                failed_count  => scalar @sparse_failures,
                selected_span => failure_group_selected_span( \@sparse_failures ),
            };
        } else {
            my @sparse_ids = map { $_->{id} } @sparse_failures;
            push @actions, map { { type => 'ids', ids => $_ } } retry_id_chunks(@sparse_ids);
        }
    }

    return @actions;
}

sub dense_failure_groups {
    my @groups;
    my @current_group;

    for my $failure (@failed_holdings) {
        if ( !@current_group ) {
            @current_group = ($failure);
            next;
        }

        my @candidate_group = ( @current_group, $failure );
        if ( dense_failure_group( \@candidate_group ) ) {
            @current_group = @candidate_group;
            next;
        }

        push @groups, [@current_group];
        @current_group = ($failure);
    }

    push @groups, [@current_group] if @current_group;

    return @groups;
}

sub dense_failure_group {
    my ($group) = @_;

    return 0 if @{$group} < 2;

    return failure_group_selected_span($group) <= @{$group} * $dense_retry_overhead_factor;
}

sub failure_group_selected_span {
    my ($group) = @_;

    return $group->[-1]->{processed_no} - $group->[0]->{processed_no} + 1;
}

sub retry_id_chunks {
    my @ids = @_;

    my @chunks;
    my @chunk;

    for my $id (@ids) {
        my @candidate = ( @chunk, $id );

        if (
            @chunk
            && ( @candidate > $max_inline_retry_ids
                || length( continuation_command( undef, { ids => \@candidate } ) ) > $max_retry_command_length )
            )
        {
            push @chunks, [@chunk];
            @chunk = ($id);
            next;
        }

        @chunk = @candidate;
    }

    push @chunks, [@chunk] if @chunk;

    return @chunks;
}

sub continuation_command {
    my ( $resume_from_holding_id, $params ) = @_;

    $params //= {};

    if ( !%{$params} && ids_are_limited() ) {
        my @ids_files = reusable_requested_ids_files();
        if (@ids_files) {
            return continuation_command( $resume_from_holding_id, { ids_files => \@ids_files } );
        }

        my @remaining_ids = remaining_requested_ids($resume_from_holding_id);
        return continuation_command( undef, { ids => \@remaining_ids } );
    }

    my @command = ( $0, '-c' );

    push @command, '-q' if $quiet;
    push @command, '-' . ( 'v' x $verbose ) if !$quiet && $verbose;
    push @command, '--skip-indexing'         if $skip_indexing;
    push @command, '--progress-step', $progress_step if $progress_step_set;

    if ( $params->{ids} ) {
        push @command, '--ids', ids_argument( @{ $params->{ids} } );
    }

    if ( $params->{ids_file} ) {
        push @command, '--ids-file', $params->{ids_file};
    }

    if ( $params->{ids_files} ) {
        push @command, map { ( '--ids-file', $_ ) } @{ $params->{ids_files} };
    }

    my $from = exists $params->{from_id} ? $params->{from_id} : $resume_from_holding_id;
    my $to   = exists $params->{to_id}   ? $params->{to_id}   : $to_id;

    push @command, '--from-id', $from if defined $from;
    push @command, '--to-id',   $to   if defined $to;

    return join ' ', @command;
}

sub remaining_requested_ids {
    my ($resume_from_holding_id) = @_;

    return @requested_holding_ids if !defined $resume_from_holding_id;

    return grep { $_ >= $resume_from_holding_id && ( !defined $to_id || $_ <= $to_id ) } @requested_holding_ids;
}

sub reusable_requested_ids_files {
    return if @ids_options;
    return if !@ids_file_options;
    return if grep { $_ eq '-' } @ids_file_options;

    return @ids_file_options;
}

sub ids_argument {
    return join ',', @_;
}

sub format_count {
    my ($count) = @_;

    $count //= 0;
    $count = int($count);
    1 while $count =~ s/^(-?\d+)(\d{3})/$1,$2/;

    return $count;
}

sub format_duration {
    my ($seconds) = @_;

    $seconds = int( $seconds + 0.5 );

    my $hours   = int( $seconds / 3600 );
    my $minutes = int( ( $seconds % 3600 ) / 60 );
    my $secs    = $seconds % 60;

    return sprintf "%dh%02dm", $hours, $minutes if $hours;
    return sprintf "%dm%02ds", $minutes, $secs if $minutes;
    return "${secs}s";
}

sub timestamp {
    my ($epoch) = @_;

    $epoch //= time;

    return strftime( '%Y-%m-%d %H:%M:%S', localtime($epoch) );
}

sub env_positive_integer {
    my ( $name, $default ) = @_;

    my $value = $ENV{$name};
    return $default if !defined $value || $value eq q{};

    if ( $value !~ /^\d+\z/ || $value < 1 ) {
        die "$name must be a positive integer\n";
    }

    return $value;
}

package BatchRebuildHoldingsTables::Output;

sub new {
    my ( $class, $params ) = @_;

    $params //= {};

    my $interactive = -t STDOUT && ( $ENV{TERM} // '' ) ne 'dumb';
    my $color       =
          defined $params->{color} ? $params->{color}
        : !exists $ENV{NO_COLOR}   ? $interactive
        :                            0;

    my $self = {
        color          => $color,
        interactive    => $interactive,
        status_active  => 0,
        terminal_width => terminal_width(),
    };

    return bless $self, $class;
}

sub is_interactive {
    my ($self) = @_;

    return $self->{interactive};
}

sub terminal_width {
    my ($self) = @_;

    return $self->{terminal_width} if ref $self && exists $self->{terminal_width};

    my $columns = $ENV{COLUMNS};
    return $columns if defined $columns && $columns =~ /^\d+$/ && $columns > 0;

    my @size = eval {
        require Term::ReadKey;
        Term::ReadKey::GetTerminalSize(*STDOUT);
    };
    return $size[0] if @size && $size[0];

    return 80;
}

sub colorize {
    my ( $self, $style, $text ) = @_;

    return $text if !$self->{color} || !$style;
    return Term::ANSIColor::color($style) . $text . Term::ANSIColor::color('reset');
}

sub say {
    my ( $self, $text, $style ) = @_;

    $self->finish_status();
    print $self->colorize( $style, $text ) . "\n";
}

sub warn {
    my ( $self, $text, $style ) = @_;

    $self->finish_status();
    print STDERR $self->colorize( $style // 'yellow', $text ) . "\n";
}

sub blank_line {
    my ( $self, $stream ) = @_;

    $self->finish_status();
    print STDERR "\n" if ( $stream // q{} ) eq 'stderr';
    print "\n"        if ( $stream // q{} ) ne 'stderr';
}

sub status {
    my ( $self, $text, $style ) = @_;

    $self->status_parts( [ [ $text, $style ] ] );
}

sub status_parts {
    my ( $self, $parts ) = @_;

    my @parts = map { ref $_ eq 'ARRAY' ? $_ : [ $_, undef ] } @{$parts};

    if ( $self->{interactive} ) {
        @parts = $self->_fit_parts_to_terminal_width(@parts);
        print "\r\033[K" . $self->_colorize_parts(@parts);
        $self->{status_active} = 1;
        return;
    }

    print $self->_colorize_parts(@parts) . "\n";
}

sub _colorize_parts {
    my ( $self, @parts ) = @_;

    return join q{}, map { $self->colorize( $_->[1], $_->[0] ) } @parts;
}

sub finish_status {
    my ($self) = @_;

    return if !$self->{status_active};

    print "\r\033[K\n";
    $self->{status_active} = 0;
}

sub _fit_parts_to_terminal_width {
    my ( $self, @parts ) = @_;

    my $width = $self->{terminal_width};
    return @parts if !$width;

    my $limit = $width > 1 ? $width - 1 : $width;
    my $text_length = 0;
    $text_length += length( $_->[0] ) for @parts;
    return @parts if $text_length <= $limit;

    my $ellipsis = $limit > 3 ? '...' : q{};
    my $target   = $limit - length($ellipsis);
    my @fitted;
    my $used = 0;

    for my $part (@parts) {
        last if $used >= $target;

        my $available = $target - $used;
        my $text      = $part->[0];

        if ( length($text) <= $available ) {
            push @fitted, $part;
            $used += length($text);
            next;
        }

        push @fitted, [ substr( $text, 0, $available ), $part->[1] ];
        $used = $target;
    }

    push @fitted, [ $ellipsis, 'bright_black' ] if $ellipsis ne q{};

    return @fitted;
}

package main;

=head1 NAME

batchRebuildHoldingsTables.pl - rebuilds the non-MARC Holdings DB from MARC values

=head1 SYNOPSIS

  batchRebuildHoldingsTables.pl -h
  batchRebuildHoldingsTables.pl -c
  batchRebuildHoldingsTables.pl -c -v
  batchRebuildHoldingsTables.pl -c -vv
  batchRebuildHoldingsTables.pl -c -q
  batchRebuildHoldingsTables.pl -c --skip-indexing
  batchRebuildHoldingsTables.pl -c --progress-step=500
  batchRebuildHoldingsTables.pl -c --from-id=100000 --to-id=200000
  batchRebuildHoldingsTables.pl -c --ids=100000,100010,100020
  batchRebuildHoldingsTables.pl -c --ids-file=failed-holdings.txt

=head1 DESCRIPTION

This script rebuilds the non-MARC Holdings DB from the MARC values.
You can/must use it when you change the mappings.

Example: you decide to map holdings.callnumber to 852$k$l$m
when it was previously mapped to 852$k.

If interrupted with Ctrl+C, the script stops after the current holding and
prints a command that can continue from the next unprocessed holding_id.
If a holding fails, the error output includes its holding_id and the final
summary prints a command that can retry exact failed IDs or dense failed
ranges.
When output goes to an interactive terminal, progress is rendered as one
rewritten status line fitted to the detected terminal width. Color output is
enabled automatically for interactive terminals unless the C<NO_COLOR>
environment variable is set. Use C<--color> to force color or C<--no-color> to
disable it.

=head1 OPTIONS

=over 8

=item B<-h, --help>

Print this help.

=item B<-c, --confirm>

Confirm that the script should rebuild the non-MARC Holdings DB.

=item B<-v, --verbose>

Print progress. Repeat once as C<-vv> to include speed information.
Use C<--progress-step> to change the reporting cadence.
In an interactive terminal, progress rewrites a single status line instead of
printing a new line for every update.

=item B<-q, --quiet>

Suppress progress and nonessential output.
Useful for cron jobs where successful runs should stay silent.

=item B<--color, --no-color>

Force ANSI color output or disable it.
By default, color is enabled only for interactive terminals and when C<NO_COLOR>
is not set.

=item B<-s, --skip-indexing>

Do not enqueue bibliographic records for reindexing.

=item B<-p, --progress-step=N>

Print progress after this many processed records.
By default, progress is printed every 1000 records.

=item B<-f, --from-id=ID>

Start from this holdings.holding_id value.
This is an ID value, not a processed-record count.

=item B<-t, --to-id=ID>

Stop at this holdings.holding_id value.
This is an ID value, not a processed-record count.

=item B<--ids=ID,ID,...>

Only process this comma-separated list of holdings.holding_id values.
Can be repeated.

=item B<--ids-file=FILE>

Read holdings.holding_id values from FILE.
Values may be separated by commas or whitespace.
Use C<--ids-file=-> to read IDs from standard input.
Can be repeated.

=back

=cut
