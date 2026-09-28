#!/usr/bin/perl

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

use Modern::Perl;

use Test::NoWarnings;
use Test::More tests => 10;

BEGIN {
    use_ok('Koha::CLI::Output');
}

subtest 'color policy' => sub {
    plan tests => 7;

    local $ENV{ANSI_COLORS_DISABLED};
    local $ENV{NO_COLOR};
    delete $ENV{ANSI_COLORS_DISABLED};
    delete $ENV{NO_COLOR};

    my ( $out_fh, $err_fh ) = scalar_output_handles();

    my $output = Koha::CLI::Output->new(
        {
            out_fh      => $out_fh,
            err_fh      => $err_fh,
            interactive => 1,
        }
    );
    ok( $output->has_color, 'Color is enabled by default in interactive mode' );

    $ENV{NO_COLOR} = 1;
    $output        = Koha::CLI::Output->new(
        {
            out_fh      => $out_fh,
            err_fh      => $err_fh,
            interactive => 1,
        }
    );
    ok( !$output->has_color, 'NO_COLOR disables automatic color' );

    delete $ENV{NO_COLOR};
    $ENV{ANSI_COLORS_DISABLED} = 1;
    $output                    = Koha::CLI::Output->new(
        {
            out_fh      => $out_fh,
            err_fh      => $err_fh,
            interactive => 1,
        }
    );
    ok( !$output->has_color, 'ANSI_COLORS_DISABLED disables automatic color' );

    delete $ENV{ANSI_COLORS_DISABLED};
    $ENV{NO_COLOR} = 1;
    $output = Koha::CLI::Output->new(
        {
            out_fh      => $out_fh,
            err_fh      => $err_fh,
            interactive => 0,
            color       => 1,
        }
    );
    ok( $output->has_color, 'Forced color works in noninteractive mode' );

    $output = Koha::CLI::Output->new(
        {
            out_fh      => $out_fh,
            err_fh      => $err_fh,
            interactive => 1,
            color       => 0,
        }
    );
    ok( !$output->has_color, 'Forced no-color disables color in interactive mode' );

    delete $ENV{NO_COLOR};
    $output = Koha::CLI::Output->new(
        {
            out_fh => $out_fh,
            err_fh => $err_fh,
        }
    );
    ok( !$output->is_interactive, 'Scalar output handles are noninteractive by default' );
    ok( !$output->has_color,      'Noninteractive output has no automatic color' );
};

subtest 'colorize()' => sub {
    plan tests => 2;

    my ( $out_fh, $err_fh ) = scalar_output_handles();
    my $output              = Koha::CLI::Output->new(
        {
            out_fh => $out_fh,
            err_fh => $err_fh,
            color  => 1,
        }
    );

    like( $output->colorize( 'red', 'Failure' ), qr/^\e\[[\d;]+mFailure\e\[0m\z/, 'Applies ANSI color' );

    $output = Koha::CLI::Output->new(
        {
            out_fh => $out_fh,
            err_fh => $err_fh,
            color  => 0,
        }
    );
    is( $output->colorize( 'red', 'Failure' ), 'Failure', 'Returns plain text when color is disabled' );
};

subtest 'say(), warn(), and blank_line()' => sub {
    plan tests => 2;

    my ( $out_fh, $err_fh, $out, $err ) = scalar_output_handles();
    my $output = Koha::CLI::Output->new(
        {
            out_fh => $out_fh,
            err_fh => $err_fh,
            color  => 0,
        }
    );

    $output->say( 'Started', 'cyan' );
    $output->warn('Careful');
    $output->blank_line();
    $output->blank_line('stderr');

    is( ${$out}, "Started\n\n", 'say() and stdout blank line use the output handle' );
    is( ${$err}, "Careful\n\n", 'warn() and stderr blank line use the warning handle' );
};

subtest 'status_parts() in noninteractive mode' => sub {
    plan tests => 1;

    my ( $out_fh, $err_fh, $out ) = scalar_output_handles();
    my $output = Koha::CLI::Output->new(
        {
            out_fh      => $out_fh,
            err_fh      => $err_fh,
            color       => 0,
            interactive => 0,
        }
    );

    $output->status_parts( [ [ '42%', 'green' ], ' done' ] );

    is( ${$out}, "42% done\n", 'Noninteractive status output is newline-delimited' );
};

subtest 'status() and finish_status() in interactive mode' => sub {
    plan tests => 3;

    my ( $out_fh, $err_fh, $out ) = scalar_output_handles();
    my $output = Koha::CLI::Output->new(
        {
            out_fh         => $out_fh,
            err_fh         => $err_fh,
            color          => 0,
            interactive    => 1,
            terminal_width => 80,
        }
    );

    $output->status( 'Working', 'green' );
    is( ${$out}, "\r\e[KWorking", 'Interactive status uses carriage return and clear-line' );

    $output->finish_status();
    is( ${$out}, "\r\e[KWorking\r\e[K\n", 'finish_status() clears active status line' );

    $output->finish_status();
    is( ${$out}, "\r\e[KWorking\r\e[K\n", 'finish_status() is idempotent without an active status line' );
};

subtest 'normal output clears active status first' => sub {
    plan tests => 2;

    my ( $out_fh, $err_fh, $out, $err ) = scalar_output_handles();
    my $output = Koha::CLI::Output->new(
        {
            out_fh         => $out_fh,
            err_fh         => $err_fh,
            color          => 0,
            interactive    => 1,
            terminal_width => 80,
        }
    );

    $output->status('Working');
    $output->say('Done');
    $output->warn('Warning');

    is( ${$out}, "\r\e[KWorking\r\e[K\nDone\n", 'say() clears the active status before printing' );
    is( ${$err}, "Warning\n",                         'warn() prints to the warning handle after status cleanup' );
};

subtest 'interactive status is fitted to terminal width' => sub {
    plan tests => 1;

    my ( $out_fh, $err_fh, $out ) = scalar_output_handles();
    my $output = Koha::CLI::Output->new(
        {
            out_fh         => $out_fh,
            err_fh         => $err_fh,
            color          => 0,
            interactive    => 1,
            terminal_width => 10,
        }
    );

    $output->status_parts( [ [ '12345', 'red' ], [ '67890', 'green' ], [ 'abc', 'blue' ] ] );

    is( ${$out}, "\r\e[K123456...", 'Long interactive status is truncated with an ellipsis' );
};

subtest 'terminal width can be detected or injected' => sub {
    plan tests => 2;

    local $ENV{COLUMNS} = 42;
    my ( $out_fh, $err_fh ) = scalar_output_handles();

    my $output = Koha::CLI::Output->new(
        {
            out_fh => $out_fh,
            err_fh => $err_fh,
        }
    );
    is( $output->terminal_width, 42, 'Terminal width uses COLUMNS when provided' );

    $output = Koha::CLI::Output->new(
        {
            out_fh         => $out_fh,
            err_fh         => $err_fh,
            terminal_width => 132,
        }
    );
    is( $output->terminal_width, 132, 'Injected terminal width overrides detection' );
};

sub scalar_output_handles {
    my $out = q{};
    my $err = q{};

    open my $out_fh, '>', \$out or die "Cannot open scalar output handle: $!";
    open my $err_fh, '>', \$err or die "Cannot open scalar error handle: $!";

    return ( $out_fh, $err_fh, \$out, \$err );
}
