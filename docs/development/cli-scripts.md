# Unified command-line scripts

Koha command-line scripts should expose a predictable operator interface for
batch work: help, dry-run mode, quiet and verbose output, safe progress, color
policy, and readable summaries.

This page documents the current shared output helper and the recommended shape
for new or refactored batch scripts. It is intentionally a starting point; more
shared helpers can be added as common script behavior moves out of individual
scripts.

## Output helper

Scripts that print progress, warnings, or long-running status updates should
use `Koha::CLI::Output` instead of handling terminal control sequences and
color policy locally.

The helper provides:

- automatic interactive terminal detection
- automatic color only for interactive output
- support for `NO_COLOR` and `ANSI_COLORS_DISABLED`
- explicit `--color` and `--no-color` style overrides from callers
- carriage-return status lines in interactive mode
- newline-delimited status output in noninteractive mode
- status-line cleanup before normal output or warnings
- terminal-width fitting for long status lines

## Common option pattern

New batch-oriented scripts should consider this baseline when it fits their
scope:

- `-h`, `--help` to show usage
- `-n`, `--dry-run` to show what would change without changing data
- `-q`, `--quiet` for cron-friendly output
- `-v`, `--verbose` for extra operator detail; repeated `-v` can increase
  detail
- `--color`, `--no-color` to override automatic color policy
- script-specific selectors such as `--from-id`, `--to-id`, `--limit`, or
  `--batch-size`
- `--progress-step` for long-running progress cadence when useful

For Perl scripts using `Getopt::Long`, use explicit parser configuration when
adding a new option block:

```perl
use Getopt::Long qw( GetOptions :config no_ignore_case bundling );

my $color;
my $dry_run;
my $quiet;
my $verbose = 0;

GetOptions(
    'color!'    => \$color,
    'dry-run|n' => \$dry_run,
    'help|h'    => \$help,
    'quiet|q'   => \$quiet,
    'verbose|v+' => \$verbose,
) or pod2usage( -exitval => 2, -verbose => 1 );
```

With `Getopt::Long`, `color!` gives callers both `--color` and `--no-color`.
When neither option is passed, `Koha::CLI::Output` keeps the automatic policy.

## Basic output use

```perl
use Koha::CLI::Output;

my $output = Koha::CLI::Output->new( { color => $color } );

$output->say( 'Starting batch job', 'cyan' ) unless $quiet;

$output->status_parts(
    [
        [ '42%',       'bold green' ],
        [ ' processed', 'bright_black' ],
    ]
) unless $quiet;

$output->finish_status;
$output->say( 'Done', 'green' ) unless $quiet;
$output->warn( 'Some records were skipped' );
```

`color` is optional. If it is not supplied, color is enabled only when output
is interactive and color has not been disabled through the environment.

## Status lines

Use `status` for a single text fragment:

```perl
$output->status( 'Processing records...', 'cyan' );
```

Use `status_parts` when different fragments need different styles:

```perl
$output->status_parts(
    [
        [ 'Processing ', 'cyan' ],
        [ $record_id,    'bold' ],
        [ ' failed',     'red' ],
    ]
);
```

In interactive mode, status output rewrites one terminal line. In
noninteractive mode, each status update is printed on its own line so redirected
logs remain readable.

Call `finish_status` before exiting after a status update if the script does
not print another message through the helper:

```perl
$output->finish_status;
```

`say`, `warn`, and `blank_line` call `finish_status` automatically.

## Developer example

The manual demo script lives under `docs/development/examples` because it is a
developer aid, not a deployed Koha maintenance script. It uses in-memory demo
records so it can be run from a checkout without a Koha database.

From the repository root:

```sh
perl docs/development/examples/unified-cli-script-demo.pl
perl docs/development/examples/unified-cli-script-demo.pl --dry-run -v
perl docs/development/examples/unified-cli-script-demo.pl --non-interactive --progress-step 3
perl docs/development/examples/unified-cli-script-demo.pl --quiet
```

The example demonstrates record selection, safe dry-run behavior, quiet mode,
verbosity levels, progress output, color policy, interactive detection, and a
compact summary.

Run the automated output helper test from the repository root with:

```sh
prove -I . t/Koha/CLI/Output.t
```

## Future shared helpers

The current reusable piece is `Koha::CLI::Output`. Future helpers can move more
batch behavior out of scripts when enough scripts need the same pattern:

- record range parsing and validation
- keyset iteration helpers
- progress and ETA formatting
- interruption and resume hints
- retry command formatting for failed records
- warning capture around per-record operations
- standard summary blocks
