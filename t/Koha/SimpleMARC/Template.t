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
use Test::More tests => 4;

my $path = 'koha-tmpl/intranet-tmpl/prog/en/modules/tools/marc_modification_templates.tt';
open my $template_fh, '<', $path or die "Cannot open $path: $!";
my $template = do { local $/; <$template_fh> };
close $template_fh or die "Cannot close $path: $!";

like(
    $template,
    qr/id="to_regex_modifiers"[^>]*aria-describedby="to_regex_modifiers_hint"[^>]*placeholder="igT"/,
    'the modifiers input advertises T and references its help text'
);
like(
    $template,
    qr/id="to_regex_modifiers_hint".*?\{\{245\$a\}\}/s,
    'the interface explains the basic MARC placeholder syntax'
);
like(
    $template,
    qr/id="to_regex_modifiers_hint".*?\{\{245\$a\?\}\}.*?\{\{245\$a\[2\]\}\}.*?\{\{245\$a\?b\}\}/s,
    'the interface shows optional, occurrence and fallback forms'
);
