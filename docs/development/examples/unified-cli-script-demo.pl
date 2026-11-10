#!/usr/bin/env perl

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

=head1 NAME

unified-cli-script-demo.pl - demonstrate a Koha batch script interface

=head1 SYNOPSIS

perl docs/development/examples/unified-cli-script-demo.pl [options]

=head1 OPTIONS

=over

=item B<-n, --dry-run>

Show what would be processed without changing anything.

=item B<-q, --quiet>

Suppress nonessential output. Warnings and failures are still printed.

=item B<-v, --verbose>

Print more detail. Repeat, for example C<-vv>, for per-record detail.

=item B<--from-id ID>

Only process demo records with an ID greater than or equal to ID.

=item B<--to-id ID>

Only process demo records with an ID less than or equal to ID.

=item B<--limit COUNT>

Process at most COUNT selected records.

=item B<--batch-size COUNT>

Group selected records into batches of COUNT records.

=item B<--progress-step COUNT>

Print progress after every COUNT processed records.

=item B<--color>

Force colored output.

=item B<--no-color>

Disable colored output.

=item B<--non-interactive>

Render status output as newline-delimited log output.

=item B<--width WIDTH>

Override the detected terminal width.

=item B<--sleep-ms MILLISECONDS>

Sleep between records so interactive progress is visible.

=item B<-h, --help>

Show this help.

=back

=cut

use Modern::Perl;

use FindBin;
use Getopt::Long qw( GetOptions :config no_ignore_case bundling );
use Pod::Usage   qw( pod2usage );
use Time::HiRes  qw( usleep );

use lib "$FindBin::Bin/../../..";

use Koha::CLI::Output;

my $batch_size    = 5;
my $color;
my $dry_run;
my $from_id;
my $help;
my $limit         = 12;
my $non_interactive;
my $progress_step = 1;
my $quiet;
my $sleep_ms      = 50;
my $to_id;
my $verbose       = 0;
my $width;

GetOptions(
    'batch-size=i'     => \$batch_size,
    'color!'           => \$color,
    'dry-run|n'        => \$dry_run,
    'from-id=i'        => \$from_id,
    'help|h'           => \$help,
    'limit=i'          => \$limit,
    'non-interactive'  => \$non_interactive,
    'progress-step=i'  => \$progress_step,
    'quiet|q'          => \$quiet,
    'sleep-ms=i'       => \$sleep_ms,
    'to-id=i'          => \$to_id,
    'verbose|v+'       => \$verbose,
    'width=i'          => \$width,
) or pod2usage( -exitval => 2, -verbose => 1 );

pod2usage( -exitval => 0, -verbose => 1 ) if $help;

validate_positive_integer( 'batch-size', $batch_size );
validate_positive_integer( 'from-id', $from_id ) if defined $from_id;
validate_positive_integer( 'limit', $limit );
validate_positive_integer( 'progress-step', $progress_step );
validate_positive_integer( 'sleep-ms', $sleep_ms, { allow_zero => 1 } );
validate_positive_integer( 'to-id', $to_id ) if defined $to_id;
validate_positive_integer( 'width', $width ) if defined $width;

if ( defined $from_id && defined $to_id && $from_id > $to_id ) {
    pod2usage( -message => '--from-id cannot be greater than --to-id', -exitval => 2, -verbose => 1 );
}

my %output_params = ( color => $color );
$output_params{interactive}    = 0      if $non_interactive;
$output_params{terminal_width} = $width if defined $width;

my $output = Koha::CLI::Output->new( \%output_params );
my @records = selected_demo_records(
    {
        from_id => $from_id,
        limit   => $limit,
        to_id   => $to_id,
    }
);

my $selected = scalar @records;
my $started  = time;
my $changed  = 0;
my $read     = 0;
my $skipped  = 0;

if ( !$quiet ) {
    $output->say( 'Unified Koha CLI script demo', 'bold cyan' );
    $output->say(
        sprintf(
            'Mode: %s, color: %s, dry-run: %s',
            $output->is_interactive ? 'interactive' : 'noninteractive',
            $output->has_color      ? 'enabled'     : 'disabled',
            $dry_run                ? 'yes'         : 'no',
        ),
        'bright_black'
    );
    $output->say(
        sprintf(
            'Selected %d demo records%s%s%s',
            $selected,
            defined $from_id ? sprintf( ', from id %d', $from_id ) : q{},
            defined $to_id   ? sprintf( ', to id %d',   $to_id )   : q{},
            $limit           ? sprintf( ', limit %d',   $limit )   : q{},
        )
    );
    $output->blank_line;
}

if ( !$selected ) {
    $output->say( 'No records selected', 'yellow' ) unless $quiet;
    exit 0;
}

my $processed = 0;
while (@records) {
    my @batch = splice @records, 0, $batch_size;

    if ( $verbose && !$quiet ) {
        $output->say( sprintf( 'Reading batch starting at record %d', $batch[0]->{record_id} ), 'bright_black' );
    }

    for my $record (@batch) {
        $read++;
        process_record( $record, { dry_run => $dry_run } );
        $processed++;
        $changed++ if !$dry_run;
        $skipped++ if $dry_run;

        if ( $verbose > 1 && !$quiet ) {
            $output->say(
                sprintf(
                    '%s record %d: %s',
                    $dry_run ? 'Would process' : 'Processed',
                    $record->{record_id},
                    $record->{title},
                ),
                $dry_run ? 'yellow' : 'green'
            );
        }

        show_progress(
            $output,
            {
                dry_run       => $dry_run,
                processed     => $processed,
                progress_step => $progress_step,
                quiet         => $quiet,
                record_id     => $record->{record_id},
                selected      => $selected,
            }
        );
    }
}

if ( !$quiet ) {
    $output->blank_line;
    $output->say( 'Summary', 'bold cyan' );
    $output->say( sprintf( 'Run:      %s', elapsed_summary($started) ) );
    $output->say( sprintf( 'Selected: %d demo records', $selected ) );
    $output->say(
        sprintf(
            'Result:   %d read, %d %s, %d skipped',
            $read,
            $dry_run ? $skipped : $changed,
            $dry_run ? 'would be changed' : 'changed',
            $dry_run ? 0 : $skipped,
        )
    );
    $output->say( 'Status:   completed successfully', 'green' );
}

exit 0;

sub selected_demo_records {
    my ($params) = @_;

    my @records = map {
        {
            record_id => $_,
            title     => sprintf( 'Demo bibliographic record %d', $_ ),
        }
    } 1001 .. 1040;

    @records = grep { $_->{record_id} >= $params->{from_id} } @records if defined $params->{from_id};
    @records = grep { $_->{record_id} <= $params->{to_id} } @records   if defined $params->{to_id};
    @records = splice @records, 0, $params->{limit} if $params->{limit};

    return @records;
}

sub process_record {
    my ( $record, $params ) = @_;

    usleep $sleep_ms * 1000 if $sleep_ms;

    return if $params->{dry_run};

    return;
}

sub show_progress {
    my ( $output, $params ) = @_;

    return if $params->{quiet};
    return if $params->{processed} % $params->{progress_step} && $params->{processed} != $params->{selected};

    my $percent = $params->{selected} ? ( $params->{processed} / $params->{selected} ) * 100 : 100;

    $output->status_parts(
        [
            [ sprintf( '%5.1f%%', $percent ), 'bold green' ],
            [ ' done | ',                  'bright_black' ],
            [ $params->{processed},        'bold' ],
            [ sprintf( '/%d', $params->{selected} ), 'bright_black' ],
            [ ' | last id ',               'bright_black' ],
            [ $params->{record_id},        'bold' ],
            [ $params->{dry_run} ? ' | dry-run' : q{}, 'yellow' ],
        ]
    );

    return;
}

sub elapsed_summary {
    my ($started) = @_;

    my $elapsed = time - $started;
    return sprintf( '%.2fs', $elapsed );
}

sub validate_positive_integer {
    my ( $name, $value, $params ) = @_;

    return if !defined $value;

    $params //= {};

    my $minimum = $params->{allow_zero} ? 0 : 1;
    return if $value =~ /^\d+\z/ && $value >= $minimum;

    pod2usage(
        -message => sprintf( '--%s must be %s', $name, $minimum ? 'a positive integer' : 'zero or a positive integer' ),
        -exitval => 2,
        -verbose => 1,
    );
}
