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
use utf8;

use Test::Exception;
use Test::NoWarnings;
use Test::More tests => 8;

use MARC::Field;
use MARC::Record;

use Koha::Regex::Replacement;
use Koha::SimpleMARC::Replacement;

sub new_record {
    my $record = MARC::Record->new;
    $record->append_fields(
        MARC::Field->new( '008', 'control data' ),
        MARC::Field->new(
            '245', ' ', ' ',
            a => 'seed',
            c => 'creator',
        ),
        MARC::Field->new(
            '509', ' ', ' ',
            a => 'alpha',
            a => 'bravo',
            b => 'beta',
        ),
        MARC::Field->new(
            '510', ' ', ' ',
            a => 'gamma',
            b => q{price $1 and \t and {{509$a}}},
            c => 'äiti, їжак',
        ),
        MARC::Field->new(
            '511', ' ', ' ',
            a => q{},
        ),
        MARC::Field->new( '512', ' ', ' ', b => 'other' ),
        MARC::Field->new( '512', ' ', ' ', a => 'delta' ),
    );
    return $record;
}

sub expand_placeholder {
    my ($params) = @_;

    my $replacement = Koha::SimpleMARC::Replacement::expand(
        {
            template         => $params->{replace},
            record           => $params->{record} // new_record(),
            current_tag      => $params->{current_tag},
            current_subfield => $params->{current_subfield},
        }
    );
    return Koha::Regex::Replacement::expand_template(
        $replacement,
        $params->{captures}       // [],
        $params->{named_captures} // {},
    );
}

subtest 'required placeholders and concatenation' => sub {
    is(
        expand_placeholder( { replace => q{{{509$a}}} } ),
        "alpha \x{2021}bravo",
        'all matching values use the default double-dagger delimiter'
    );
    is(
        expand_placeholder( { replace => q{{{509$a[1]}} + {{509$b}} + {{510$a}}} } ),
        'alpha + beta + gamma',
        'multiple placeholders concatenate values from the record'
    );
    is(
        expand_placeholder(
            {
                replace          => q{{{008}}},
                current_tag      => '245',
                current_subfield => 'a',
            }
        ),
        'control data',
        'an explicit control field ignores inherited subfield context'
    );
    is(
        expand_placeholder( { replace => q{{{512$a}}} } ), 'delta',
        'fields without the requested subfield are ignored'
    );
};
subtest 'one-based occurrence slices' => sub {
    is( expand_placeholder( { replace => q{{{509$a[1]}}} } ),  'alpha', '[1] selects one value' );
    is( expand_placeholder( { replace => q{{{509$a[2:]}}} } ), 'bravo', '[2:] selects to the end' );
    is(
        expand_placeholder( { replace => q{{{509$a[:3]}}} } ), "alpha \x{2021}bravo",
        '[:3] clamps to available values'
    );
    is(
        expand_placeholder( { replace => q{{{509$a[1:2]}}} } ), "alpha \x{2021}bravo",
        '[1:2] selects an inclusive range'
    );
    is( expand_placeholder( { replace => q{{{509$a[1:1]}}} } ),   'alpha', '[1:1] selects an inclusive range' );
    is( expand_placeholder( { replace => q{{{509$a[3]?[2]}}} } ), 'bravo', 'an out-of-range slice falls back' );
};

subtest 'fallbacks inherit tag, subfield and slice context' => sub {
    is( expand_placeholder( { replace => q{{{509$c?b}}} } ), 'beta', 'fallback inherits the explicit tag' );
    is(
        expand_placeholder( { replace => q{{{509$a?b}}} } ), "alpha \x{2021}bravo",
        'the first non-empty fallback wins'
    );
    is( expand_placeholder( { replace => q{{{509$c?510$a}}} } ), 'gamma', 'fallback can select another field' );
    is(
        expand_placeholder( { replace => q{{{509$a[3]?[2]?}}} } ), 'bravo',
        'slice fallback inherits tag and subfield'
    );
    is( expand_placeholder( { replace => q{{{509$c?"-"}}} } ), '-', 'a quoted literal terminates a fallback chain' );
    is(
        expand_placeholder(
            {
                replace          => q{{{[2]}}},
                current_tag      => '509',
                current_subfield => '$a',
            }
        ),
        'bravo',
        'tag and subfield can be inherited from the current operation'
    );
};

subtest 'optional and empty values remove surrounding whitespace predictably' => sub {
    is(
        expand_placeholder( { replace => q{before {{599$a?}} after} } ), 'before after',
        'optional missing value collapses spaces'
    );
    is(
        expand_placeholder( { replace => "before\n  {{599\$a?}}\n  after" } ),
        "before\nafter",
        'optional missing value preserves a line boundary'
    );
    is(
        expand_placeholder( { replace => q{before {{511$a}} after} } ), 'before after',
        'a present empty value collapses spaces'
    );
    is( expand_placeholder( { replace => q{x{{599$a?}}y} } ),   'xy', 'optional missing value needs no padding' );
    is( expand_placeholder( { replace => q{x{{ 599$a? }}y} } ), 'xy', 'outer placeholder whitespace is ignored' );
    is(
        expand_placeholder( { replace => q{before {{599$a?}} {{598$a?}} after} } ),
        'before after',
        'adjacent optional values do not accumulate whitespace'
    );
};

subtest 'custom delimiters and inline literals' => sub {
    is( expand_placeholder( { replace => q{{{509$a[1:]"; "}}} } ), 'alpha; bravo', 'custom delimiter is used' );
    is(
        expand_placeholder( { replace => q{{{509$a[1:]"\n"}}} } ), "alpha\nbravo",
        '\\n in a delimiter becomes a newline'
    );
    is(
        expand_placeholder( { replace => q{{{509$a[1:]"\r"}}} } ), "alpha\rbravo",
        '\\r in a delimiter becomes a carriage return'
    );
    is( expand_placeholder( { replace => q{{{509$a[1:]"\t"}}} } ), "alpha\tbravo", '\\t in a delimiter becomes a tab' );
    is(
        expand_placeholder( { replace => q{{{509$a[1:]" ? "}}} } ), 'alpha ? bravo',
        'question marks inside delimiters are not fallbacks'
    );
    is( expand_placeholder( { replace => q{{{599$a?"?"}}} } ), '?', 'question marks can be inline literal fallbacks' );
};

subtest 'MARC values are inserted as literal data' => sub {
    is(
        expand_placeholder( { captures => ['seed'], replace => q{capture=$1; data={{510$b}}} } ),
        q{capture=seed; data=price $1 and \t and {{509$a}}},
        'placeholder data is not reinterpreted as captures, escapes or placeholders'
    );
    is(
        expand_placeholder( { replace => q{{{510$c}}} } ),
        'äiti, їжак',
        'Unicode MARC data round-trips through the replacement'
    );

    my $record = new_record();
    $record->append_fields(
        MARC::Field->new(
            '513', ' ', ' ',
            a => '$1',
            b => q{\1},
            c => 'newline',
        )
    );
    is(
        expand_placeholder( { record => $record, captures => ['seed'], replace => q!\{{513$a}}! } ),
        q!\$1!,
        'a preceding template backslash cannot expose a capture token in MARC data'
    );
    is(
        expand_placeholder( { record => $record, captures => ['seed'], replace => q!\{{513$b}}! } ),
        q!\\\\1!,
        'a preceding template backslash cannot expose a legacy capture token in MARC data'
    );
    is(
        expand_placeholder( { record => $record, captures => ['seed'], replace => q!\{{513$c}}! } ),
        q!\newline!,
        'a preceding template backslash cannot turn MARC data into a replacement escape'
    );
    is(
        expand_placeholder( { record => $record, captures => ['seed'], replace => q!\{{599$a?}}{{513$a}}! } ),
        q!\$1!,
        'an optional placeholder cannot carry a template escape into MARC data'
    );
    is(
        expand_placeholder( { record => $record, captures => ['seed'], replace => q!\{{511$a}}{{513$a}}! } ),
        q!\$1!,
        'an empty placeholder cannot carry a template escape into MARC data'
    );
};

subtest 'invalid and unresolved templates fail explicitly' => sub {
    throws_ok(
        sub { expand_placeholder( { replace => q{{{599$a}}} } ) },
        qr/Placeholder 599\$a not found and is not optional/,
        'a missing required value is fatal'
    );
    throws_ok(
        sub { expand_placeholder( { replace => q{{{not valid}}} } ) },
        qr/Invalid candidate 'not valid'/,
        'invalid placeholder syntax is fatal'
    );
    throws_ok(
        sub { expand_placeholder( { replace => q{{{008$a}}}, current_subfield => 'a' } ) },
        qr/Placeholder 008\$a not found and is not optional/,
        'an explicit subfield selector cannot read a control field'
    );

    my $too_many = q{{{509$a[1]}}} x 31;
    throws_ok(
        sub { expand_placeholder( { replace => $too_many } ) },
        qr/Exceeded 30 placeholder expansions/,
        'the placeholder expansion limit is enforced'
    );
    is(
        expand_placeholder( { replace => q{{{509$a[1]}}} x 30 } ),
        'alpha' x 30,
        'the documented placeholder limit remains usable'
    );
};
