package Koha::CLI::Output;

# Copyright 2026 Koha Development Team
#
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

use Term::ANSIColor ();

=head1 NAME

Koha::CLI::Output - Terminal-aware output helper for Koha command line scripts

=head1 SYNOPSIS

    my $output = Koha::CLI::Output->new( { color => $color } );

    $output->say( 'Processing records...', 'cyan' );
    $output->status_parts(
        [
            [ '42%', 'bold green' ],
            [ ' done', 'bright_black' ],
        ]
    );
    $output->finish_status;
    $output->warn( 'Some records failed', 'yellow' );

=head1 DESCRIPTION

This helper centralizes common output behavior for long-running Koha command
line scripts: color policy, terminal detection, carriage-return status lines,
and status-line cleanup before normal output.

=head1 API

=head2 Class methods

=head3 new

    my $output = Koha::CLI::Output->new(
        {
            color          => $color, # optional; undef means auto
            interactive    => 1,      # optional test override
            terminal_width => 80,     # optional test override
            out_fh         => $out_fh,
            err_fh         => $err_fh,
        }
    );

Create a new output helper. By default, output goes to C<STDOUT>, warnings go
to C<STDERR>, interactive mode is enabled only for usable terminals, and color
is enabled only in interactive mode unless C<NO_COLOR> or
C<ANSI_COLORS_DISABLED> is set. Passing a defined C<color> value forces color
on or off.

=cut

sub new {
    my ( $class, $params ) = @_;

    $params //= {};

    my $out_fh = $params->{out_fh} // \*STDOUT;
    my $err_fh = $params->{err_fh} // \*STDERR;

    my $interactive =
          exists $params->{interactive} ? $params->{interactive}
        : -t $out_fh && ( $ENV{TERM} // '' ) ne 'dumb';
    my $auto_color = !exists $ENV{NO_COLOR} && !$ENV{ANSI_COLORS_DISABLED};
    my $color =
          defined $params->{color} ? $params->{color}
        : $auto_color              ? $interactive
        :                            0;
    my $terminal_width =
        exists $params->{terminal_width}
        ? $params->{terminal_width}
        : $class->_detect_terminal_width($out_fh);

    my $self = {
        color          => $color ? 1 : 0,
        err_fh         => $err_fh,
        interactive    => $interactive ? 1 : 0,
        out_fh         => $out_fh,
        status_active  => 0,
        terminal_width => $terminal_width,
    };

    return bless $self, $class;
}

=head2 Instance methods

=head3 is_interactive

    my $is_interactive = $output->is_interactive;

Return true if status output will be rendered as an interactive status line.

=cut

sub is_interactive {
    my ($self) = @_;

    return $self->{interactive};
}

=head3 has_color

    my $has_color = $output->has_color;

Return true if ANSI color output is enabled.

=cut

sub has_color {
    my ($self) = @_;

    return $self->{color};
}

=head3 terminal_width

    my $terminal_width = $output->terminal_width;

Return the detected or injected terminal width.

=cut

sub terminal_width {
    my ($self) = @_;

    return $self->{terminal_width};
}

=head3 colorize

    my $text = $output->colorize( 'green', 'Done' );

Apply ANSI color to C<$text> when color is enabled and a style is provided.

=cut

sub colorize {
    my ( $self, $style, $text ) = @_;

    return $text if !$self->{color} || !$style;

    local $ENV{ANSI_COLORS_DISABLED};
    local $ENV{NO_COLOR};
    delete $ENV{ANSI_COLORS_DISABLED};
    delete $ENV{NO_COLOR};

    return Term::ANSIColor::color($style) . $text . Term::ANSIColor::color('reset');
}

=head3 say

    $output->say( $message, $style );

Clear any active status line and print C<$message> with a trailing newline to
the output filehandle.

=cut

sub say {
    my ( $self, $text, $style ) = @_;

    $self->finish_status();
    print { $self->{out_fh} } $self->colorize( $style, $text ) . "\n";

    return;
}

=head3 warn

    $output->warn( $message, $style );

Clear any active status line and print C<$message> with a trailing newline to
the warning filehandle. The default style is yellow.

=cut

sub warn {
    my ( $self, $text, $style ) = @_;

    $self->finish_status();
    print { $self->{err_fh} } $self->colorize( $style // 'yellow', $text ) . "\n";

    return;
}

=head3 blank_line

    $output->blank_line;
    $output->blank_line('stderr');

Clear any active status line and print one blank line. Pass C<stderr> to print
the blank line to the warning filehandle.

=cut

sub blank_line {
    my ( $self, $stream ) = @_;

    $self->finish_status();
    print { $self->{err_fh} } "\n" if ( $stream // q{} ) eq 'stderr';
    print { $self->{out_fh} } "\n" if ( $stream // q{} ) ne 'stderr';

    return;
}

=head3 status

    $output->status( $message, $style );

Print C<$message> as a status line.

=cut

sub status {
    my ( $self, $text, $style ) = @_;

    $self->status_parts( [ [ $text, $style ] ] );

    return;
}

=head3 status_parts

    $output->status_parts(
        [
            [ '42%', 'bold green' ],
            [ ' done', 'bright_black' ],
        ]
    );

Print a status line from segmented text/style pairs. In interactive mode the
line is rewritten in place and fitted to the terminal width. In noninteractive
mode the status is printed with a trailing newline.

=cut

sub status_parts {
    my ( $self, $parts ) = @_;

    my @parts = map { ref $_ eq 'ARRAY' ? $_ : [ $_, undef ] } @{$parts};

    if ( $self->{interactive} ) {
        @parts = $self->_fit_parts_to_terminal_width(@parts);
        print { $self->{out_fh} } "\r\033[K" . $self->_colorize_parts(@parts);
        $self->{status_active} = 1;
        return;
    }

    print { $self->{out_fh} } $self->_colorize_parts(@parts) . "\n";

    return;
}

=head3 finish_status

    $output->finish_status;

Clear an active interactive status line and move following output to a new line.

=cut

sub finish_status {
    my ($self) = @_;

    return if !$self->{status_active};

    print { $self->{out_fh} } "\r\033[K\n";
    $self->{status_active} = 0;

    return;
}

sub _detect_terminal_width {
    my ( $class, $out_fh ) = @_;

    my $columns = $ENV{COLUMNS};
    return $columns if defined $columns && $columns =~ /^\d+\z/ && $columns > 0;
    return 80 if !-t $out_fh;

    my @size = eval {
        local $SIG{__WARN__} = sub { };
        require Term::ReadKey;
        Term::ReadKey::GetTerminalSize($out_fh);
    };
    return $size[0] if @size && $size[0];

    return 80;
}

sub _colorize_parts {
    my ( $self, @parts ) = @_;

    return join q{}, map { $self->colorize( $_->[1], $_->[0] ) } @parts;
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

=head1 AUTHORS

Koha Development Team

=cut

1;
