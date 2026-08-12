package Koha::SimpleMARC::Replacement;

# Copyright 2026 Nugged Team
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

use constant MAX_PLACEHOLDERS => 30;

=head1 NAME

Koha::SimpleMARC::Replacement - expand MARC placeholders in replacement strings

=head1 SYNOPSIS

    my $replacement = Koha::SimpleMARC::Replacement::expand(
        {
            template         => '{{509$a[1]?b}}',
            record           => $record,
            current_tag      => '245',
            current_subfield => 'a',
        }
    );

=head1 DESCRIPTION

Expands the C<{{...}}> placeholders enabled by the C<T> MARC modification
template modifier. The returned string is safe to pass to
C<Koha::Regex::Replacement::expand_template>: values read from the MARC record
are quoted as literal data, while capture references written outside the
placeholders retain their normal replacement semantics.

=head1 FUNCTIONS

=head2 expand

    my $replacement = Koha::SimpleMARC::Replacement::expand(
        {
            template         => $template,
            record           => $record,
            current_tag      => $tag,
            current_subfield => $subfield,
        }
    );

Supports fallback candidates separated by C<?>, an optional trailing C<?>,
one-based occurrence slices, inherited tags/subfields, quoted delimiters and
quoted literal fallback values.

=cut

sub expand {
    my ($params) = @_;

    my $template = $params->{template} // q{};
    my $record   = $params->{record};
    die "MARC modification templates: A MARC record is required for the T modifier\n" unless $record;

    my $current_tag      = _normalise_tag( $params->{current_tag} );
    my $current_subfield = _normalise_subfield( $params->{current_subfield} );

    my $expanded          = q{};
    my $cursor            = 0;
    my $placeholder_count = 0;

    while ( $template =~ /\{\{([^{}]+)\}\}/g ) {
        my $match_start = $-[0];
        my $match_end   = $+[0];
        my $inner       = $1;

        die "MARC modification templates: Exceeded " . MAX_PLACEHOLDERS . " placeholder expansions\n"
            if ++$placeholder_count > MAX_PLACEHOLDERS;

        my ( $resolved, $optional ) = _resolve_placeholder(
            {
                inner            => $inner,
                record           => $record,
                current_tag      => $current_tag,
                current_subfield => $current_subfield,
            }
        );

        my $prefix = substr( $template, $cursor, $match_start - $cursor );

        if ( defined $resolved && length $resolved ) {
            $expanded .= $prefix;
            $expanded = _close_template_fragment($expanded);
            $expanded .= _quote_replacement_literal($resolved);
            $cursor = $match_end;
            next;
        }

        unless ( defined $resolved || $optional ) {
            die "MARC modification templates: Placeholder $inner not found and is not optional\n";
        }

        my ( $prefix_text, $left_whitespace ) = $prefix =~ /\A(.*?)(\s*)\z/s;
        my $suffix = substr( $template, $match_end );
        my ($right_whitespace) = $suffix =~ /\A(\s*)/;

        $expanded .= $prefix_text;
        if ( $left_whitespace =~ /\n/ || $right_whitespace =~ /\n/ ) {
            $expanded =~ s/[^\S\r\n]+\z//;
            $expanded .= "\n" unless $expanded =~ /\n\z/;
        } elsif ( length $left_whitespace || length $right_whitespace ) {
            $expanded .= q{ } unless $expanded =~ /\s\z/;
        }

        $cursor = $match_end + length $right_whitespace;
        pos($template) = $cursor;
    }

    $expanded .= substr( $template, $cursor );
    return $expanded;
}

=head2 _resolve_placeholder

Resolve the first non-empty candidate in one placeholder and report whether
the placeholder is optional.

=cut

sub _resolve_placeholder {
    my ($params) = @_;

    my $inner             = $params->{inner};
    my $record            = $params->{record};
    my $previous_tag      = $params->{current_tag};
    my $previous_subfield = $params->{current_subfield};
    my $subfield_selected = 0;

    my @candidates = _split_candidates($inner);
    for my $candidate (@candidates) {
        $candidate =~ s/\A\s+//;
        $candidate =~ s/\s+\z//;
    }
    my $optional = @candidates && $candidates[-1] eq q{};
    pop @candidates if $optional;

    die "MARC modification templates: Invalid placeholder $inner\n"
        unless @candidates && !grep { $_ eq q{} } @candidates;

    my $last_defined;
    for my $candidate (@candidates) {
        my $parsed = _parse_candidate( $candidate, $previous_tag, $previous_subfield, $subfield_selected );
        die "MARC modification templates: Invalid candidate '$candidate' in placeholder $inner\n" unless $parsed;

        return ( $parsed->{literal}, $optional ) if exists $parsed->{literal};

        $previous_tag      = $parsed->{tag}      if defined $parsed->{tag};
        $previous_subfield = $parsed->{subfield} if defined $parsed->{subfield};
        $subfield_selected = $parsed->{subfield_selected};

        my $value = _fetch_value(
            {
                record            => $record,
                tag               => $parsed->{tag},
                subfield          => $parsed->{subfield},
                subfield_selected => $parsed->{subfield_selected},
                slice_start       => $parsed->{slice_start},
                slice_end         => $parsed->{slice_end},
                delimiter         => $parsed->{delimiter},
            }
        );

        if ( defined $value ) {
            $last_defined = $value;
            return ( $value, $optional ) if length $value;
        }
    }

    return ( $last_defined, $optional );
}

=head2 _split_candidates

Split a placeholder into fallback candidates without splitting quoted text or
slice expressions.

=cut

sub _split_candidates {
    my ($inner) = @_;

    my @candidates;
    my $candidate = q{};
    my $quote;
    my $bracket_depth = 0;
    my @characters    = split //, $inner;

    for ( my $position = 0 ; $position < @characters ; $position++ ) {
        my $character = $characters[$position];

        if ( defined $quote ) {
            $candidate .= $character;
            if ( $character eq '\\' && $position + 1 < @characters ) {
                $candidate .= $characters[ ++$position ];
            } elsif ( $character eq $quote ) {
                undef $quote;
            }
            next;
        }

        if ( $character eq q{"} || $character eq q{'} ) {
            $quote = $character;
            $candidate .= $character;
        } elsif ( $character eq q{[} ) {
            $bracket_depth++;
            $candidate .= $character;
        } elsif ( $character eq q{]} ) {
            $bracket_depth--;
            $candidate .= $character;
        } elsif ( $character eq q{?} && !$bracket_depth ) {
            push @candidates, $candidate;
            $candidate = q{};
        } else {
            $candidate .= $character;
        }
    }

    push @candidates, $candidate;
    return @candidates;
}

=head2 _parse_candidate

Parse one field, subfield, slice, delimiter or literal fallback candidate.

=cut

sub _parse_candidate {
    my ( $candidate, $default_tag, $default_subfield, $default_subfield_selected ) = @_;

    return unless $candidate =~ /\A(?:(\d{3}))?(?:\$?([[:alnum:]_]))?(?:\[(\d*)(?::(\d*))?\])?(?:(["'])(.*)\5)?\z/s;

    my ( $tag, $subfield, $slice_start, $slice_end, $quote, $delimiter ) = ( $1, $2, $3, $4, $5, $6 );
    my $has_selector      = defined $tag || defined $subfield || defined $slice_start || defined $slice_end;
    my $subfield_selected = defined $subfield ? 1 : $default_subfield_selected;

    return { literal => _decode_delimiter($delimiter) } if !$has_selector && defined $quote;
    return unless $has_selector;

    $tag      //= $default_tag;
    $subfield //= $default_subfield;
    $delimiter = defined $quote ? _decode_delimiter($delimiter) : " \x{2021}";

    return {
        tag               => $tag,
        subfield          => $subfield,
        subfield_selected => $subfield_selected,
        slice_start       => $slice_start,
        slice_end         => $slice_end,
        delimiter         => $delimiter,
    };
}

=head2 _fetch_value

Read and join the selected MARC values, applying an optional occurrence slice.

=cut

sub _fetch_value {
    my ($params) = @_;

    my $record            = $params->{record};
    my $tag               = $params->{tag};
    my $subfield          = $params->{subfield};
    my $subfield_selected = $params->{subfield_selected};
    my $slice_start       = $params->{slice_start};
    my $slice_end         = $params->{slice_end};
    my $delimiter         = $params->{delimiter};

    return unless defined $tag && length $tag;

    my @values;
    for my $field ( $record->field($tag) ) {
        if ( $field->is_control_field ) {
            next if $subfield_selected;
            my $value = $field->as_string;
            push @values, $value if defined $value;
        } elsif ( defined $subfield && length $subfield ) {
            push @values, grep { defined } $field->subfield($subfield);
        } else {
            my $value = $field->as_string;
            push @values, $value if defined $value;
        }
    }
    return unless @values;

    if ( defined $slice_start || defined $slice_end ) {
        $slice_start = 1       if !defined $slice_start || $slice_start eq q{};
        $slice_end   = @values if defined $slice_end && $slice_end eq q{};
        $slice_end   = $slice_start unless defined $slice_end;

        return if $slice_start < 1 || $slice_end < $slice_start || $slice_start > @values;
        $slice_end = @values if $slice_end > @values;
        @values    = @values[ $slice_start - 1 .. $slice_end - 1 ];
    }

    return join $delimiter, @values;
}

=head2 _decode_delimiter

Decode the supported newline, carriage-return and tab delimiter escapes.

=cut

sub _decode_delimiter {
    my ($delimiter) = @_;

    $delimiter =~ s/\\n/\n/g;
    $delimiter =~ s/\\r/\r/g;
    $delimiter =~ s/\\t/\t/g;
    return $delimiter;
}

=head2 _quote_replacement_literal

Quote MARC data so the regular-expression replacement expander treats it as
literal text.

=cut

sub _quote_replacement_literal {
    my ($value) = @_;

    $value =~ s/\\/\\\\/g;
    $value =~ s/\$/\\\$/g;
    return $value;
}

=head2 _close_template_fragment

Close a trailing replacement escape before appending quoted MARC data.

=cut

sub _close_template_fragment {
    my ($fragment) = @_;

    my ($trailing_backslashes) = $fragment =~ /(\\+)\z/;
    $fragment .= '\\' if defined $trailing_backslashes && length($trailing_backslashes) % 2;
    return $fragment;
}

=head2 _normalise_tag

Return a tag string from either a tag string or a MARC field object.

=cut

sub _normalise_tag {
    my ($tag) = @_;
    return $tag->tag if ref $tag && $tag->can('tag');
    return $tag;
}

=head2 _normalise_subfield

Return a subfield code without a leading dollar sign.

=cut

sub _normalise_subfield {
    my ($subfield) = @_;
    return unless defined $subfield && length $subfield;
    $subfield =~ s/\A\$//;
    return $subfield;
}

1;
