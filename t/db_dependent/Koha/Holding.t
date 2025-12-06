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
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use Test::More tests => 3;

use t::lib::TestBuilder;

use C4::Biblio;

use Koha::BiblioFrameworks;
use Koha::Database;
use Koha::Libraries;
use Koha::Library;
use Koha::MarcSubfieldStructures;

BEGIN {
    use_ok('Koha::Holding');
    use_ok('Koha::Holdings');
}

my $schema = Koha::Database->new->schema;

subtest 'Koha::Holding tests' => sub {

    plan tests => 20;

    $schema->storage->txn_begin;

    # Add a framework
    my $frameworkcode = 'HLD';
    my $existing_mss = Koha::MarcSubfieldStructures->search({frameworkcode => $frameworkcode});
    $existing_mss->delete() if $existing_mss;
    my $existing_fw = Koha::BiblioFrameworks->find({frameworkcode => $frameworkcode});
    $existing_fw->delete() if $existing_fw;
    Koha::BiblioFramework->new({
        frameworkcode => $frameworkcode,
        frameworktext => 'Holdings'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'b',
        kohafield => 'holdings.holdingbranch'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'c',
        kohafield => 'holdings.location'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'g',
        kohafield => 'holdings.ccode'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'h',
        kohafield => 'holdings.callnumber'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'k',
        kohafield => 'holdings.callnumber'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'l',
        kohafield => 'holdings.callnumber'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'm',
        kohafield => 'holdings.callnumber'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 863,
        tagsubfield => 'a',
        kohafield => 'holdings.summary'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 867,
        tagsubfield => 'a',
        kohafield => 'holdings.supplements'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 868,
        tagsubfield => 'a',
        kohafield => 'holdings.indexes'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 942,
        tagsubfield => 'n',
        kohafield => 'holdings.suppress'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 852,
        tagsubfield => 'z',
        kohafield => 'holdings.public_note'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 999,
        tagsubfield => 'c',
        kohafield => 'biblio.biblionumber'
    })->store();
    Koha::MarcSubfieldStructure->new({
        frameworkcode => $frameworkcode,
        tagfield => 999,
        tagsubfield => 'e',
        kohafield => 'holdings.holding_id'
    })->store();

    # Add a branch
    Koha::Library->new({ branchcode => 'ABC', branchname => 'Abc' })->store() unless Koha::Libraries->find({ branchcode => 'ABC' });

    # Add a biblio
    my $title = 'Oranges and Peaches';
    my $record = MARC::Record->new();
    my $field = MARC::Field->new('245','','','a' => $title);
    $record->append_fields( $field );
    my ($biblionumber) = C4::Biblio::AddBiblio($record, '');

    # Add a holdings record
    my $holding_marc = MARC::Record->new();
    $holding_marc->append_fields(
        MARC::Field->new(
            '852',
            '',
            '',
            'b' => 'ABC', 'c' => 'DEF', 'h' => 'classification', 'k' => 'cnprefix', 'l' => 'shelving', 'm' => 'cnsuffix'
        )
    );
    my $new_holding = Koha::Holding->new({ biblionumber => $biblionumber, frameworkcode => $frameworkcode });
    is ($new_holding->set_marc({record => $holding_marc}), $new_holding, 'set_marc() returns the object');
    is($new_holding->store(), $new_holding, 'store() returns the object on create');
    is(defined $new_holding->holding_id(), 1, 'Newly added holdings record has a holding_id');

    # Check that the added record can be found and looks right
    my $holding = Koha::Holdings->find($new_holding->holding_id());
    is(ref $holding, 'Koha::Holding', 'Found a Koha::Holding object');
    is($holding->frameworkcode(), $frameworkcode, 'Framework code correct in Koha::Holding object');
    is($holding->holdingbranch(), 'ABC', 'Location correct in Koha::Holding object');
    is($holding->biblio()->biblionumber(), $biblionumber, 'Biblio correct in Koha::Holding object');

    my $branch = $holding->holding_branch();
    is(ref $branch, 'Koha::Library', 'holding_branch() returns a Koha::Library object');
    is($branch->branchname(), 'Abc', 'holding_branch() returns correct library');

    my $metadata = $holding->metadata;
    is( ref $metadata, 'Koha::Holdings::Metadata', 'Method metadata() returned a Koha::Holdings::Metadata object');

    my $holding_marc2 = $metadata->record;
    is(ref $holding_marc2, 'MARC::Record', 'Method record() returned a MARC::Record object');
    is($holding_marc2->field('852')->subfield('b'), 'ABC', 'Location in 852$b matches location from original record object');

    # Test updating the record
    $holding_marc2->append_fields(MARC::Field->new('942','','','n' => '1'));
    is($holding->set_marc({record => $holding_marc2}), $holding, 'set_marc() returns the object on update');
    is($holding->store(), $holding, 'store() returns the object on update');

    is($holding->suppress(), 1, 'Holdings record is suppressed');

    # Test misc methods
    my %mapping = Koha::Holding->get_marc_field_mapping({ field => 'holdings.location' });
    is_deeply(
        \%mapping,
        {852 => 'c'},
        'get_marc_field_mapping returns correct data'
    );

    my $fields = Koha::Holding->marc_to_koha_fields({ record => $holding_marc2 });
    is_deeply(
        $fields,
        {
            holdingbranch => 'ABC',
            location => 'DEF',
            ccode => undef,
            indexes => undef,
            public_note => undef,
            callnumber => 'classification | cnprefix | shelving | cnsuffix',
            summary => undef,
            supplements => undef,
            suppress => 1,
            holding_id => $new_holding->holding_id()
        },
        'marc_to_koha_fields returns correct data'
    );

    # Test deletion
    is(defined $holding->deleted_on(), '', 'Holdings record not marked as deleted');
    $holding->delete();
    $holding = Koha::Holdings->find($new_holding->holding_id());
    is(defined $holding->deleted_on(), 1, 'Holdings record marked as deleted');
    is(defined $holding->metadata()->deleted_on(), 1, 'Holdings metadata record marked as deleted');

    $schema->storage->txn_rollback;
};
