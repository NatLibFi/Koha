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
use Test::More tests => 2;

use C4::MarcModificationTemplates qw(
    AddModificationTemplate
    AddModificationTemplateAction
    DelModificationTemplate
    GetModificationTemplateActions
    ModifyRecordWithTemplate
);
use Koha::Database;
use MARC::Field;
use MARC::Record;

my $schema = Koha::Database->new->schema;
$schema->storage->txn_begin;

subtest 'T replacement modifier is stored and applied end to end' => sub {
    plan tests => 10;

    my $template_id = AddModificationTemplate('T replacement modifier test');
    is(
        AddModificationTemplateAction(
            $template_id,   'copy_field',      0,
            '245',          'a',               '', '700', 'a',
            '\\A(seed)\\z', '{{509$a[2]}}-$1', 'T',
            '',             '',                '', '', '', '',
            'Copy 245$a to 700$a using a MARC placeholder'
        ),
        1,
        'T copy action is stored'
    );
    is(
        AddModificationTemplateAction(
            $template_id,    'move_field', 0,
            '245',           'c',          '', '700', 'c',
            '\\Acreator\\z', '{{509$b}}',  'T',
            '',              '',           '', '', '', '',
            'Move 245$c to 700$c using a MARC placeholder'
        ),
        1,
        'T move action is stored'
    );

    my @actions = GetModificationTemplateActions($template_id);
    is( scalar @actions,                   2,                 'both T actions round-trip through storage' );
    is( $actions[0]->{to_regex_replace},   '{{509$a[2]}}-$1', 'placeholder replacement round-trips through storage' );
    is( $actions[0]->{to_regex_modifiers}, 'T',               'T modifier round-trips through storage' );
    is( $actions[1]->{to_regex_modifiers}, 'T',               'T modifier is retained for the move action' );

    my $record = MARC::Record->new;
    $record->append_fields(
        MARC::Field->new( '245', ' ', ' ', a => 'seed',  c => 'creator' ),
        MARC::Field->new( '509', ' ', ' ', a => 'alpha', a => 'bravo', b => 'beta' ),
    );
    ModifyRecordWithTemplate( $template_id, $record );

    is( $record->field('245')->subfield('a'), 'seed',       'copy action preserves the source value' );
    is( $record->field('245')->subfield('c'), undef,        'move action removes the source value' );
    is( $record->field('700')->subfield('a'), 'bravo-seed', 'copy action expands a placeholder and capture' );
    is( $record->field('700')->subfield('c'), 'beta',       'move action expands a placeholder' );

    DelModificationTemplate($template_id);
};

$schema->storage->txn_rollback;
