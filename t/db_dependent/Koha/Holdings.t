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

use Test::More tests => 2;

use t::lib::TestBuilder;

use C4::Biblio;

use Koha::BiblioFrameworks;
use Koha::Database;
use Koha::MarcSubfieldStructures;

BEGIN {
    use_ok('Koha::Holdings');
}

my $schema = Koha::Database->new->schema;

subtest 'Koha::Holdings tests' => sub {

    plan tests => 3;

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

    # Add branches
    Koha::Library->new({ branchcode => 'ABC', branchname => 'Abc' })->store() unless Koha::Libraries->find({ branchcode => 'ABC' });
    Koha::Library->new({ branchcode => 'BCD', branchname => 'Bcd' })->store() unless Koha::Libraries->find({ branchcode => 'BCD' });

    # Add a biblio
    my $title = 'Oranges and Peaches';
    my $record = MARC::Record->new();
    my $field = MARC::Field->new('245','','','a' => $title);
    $record->append_fields( $field );
    my ($biblionumber) = C4::Biblio::AddBiblio($record, '');

    # Add a couple of holdings records
    my $holding_marc = MARC::Record->new();
    $holding_marc->append_fields(MARC::Field->new('852','','','b' => 'ABC', 'c' => 'DEF'));
    my $new_holding = Koha::Holding->new({ biblionumber => $biblionumber, frameworkcode => $frameworkcode });
    $new_holding->set_marc({record => $holding_marc})->store();

    $holding_marc = MARC::Record->new();
    $holding_marc->append_fields(MARC::Field->new('852','','','b' => 'BCD', 'c' => 'DEF'));
    $new_holding = Koha::Holding->new({ biblionumber => $biblionumber, frameworkcode => $frameworkcode });
    $new_holding->set_marc({record => $holding_marc})->store();

    # Add and delete a holdings record
    $holding_marc = MARC::Record->new();
    $holding_marc->append_fields(MARC::Field->new('852','','','b' => 'BCD', 'c' => 'DEF'));
    $new_holding = Koha::Holding->new({ biblionumber => $biblionumber, frameworkcode => $frameworkcode });
    $new_holding->set_marc({record => $holding_marc})->store();
    $new_holding->delete();

    # Test results
    my $fields = Koha::Holdings->get_embeddable_marc_fields({ biblionumber => $biblionumber});
    is(scalar(@{$fields}), 2, 'get_embeddable_marc_fields returns two fields');
    is($fields->[0]->as_string, 'ABC DEF', 'get_embeddable_marc_fields returns correct data in first field');
    is($fields->[1]->as_string, 'BCD DEF', 'get_embeddable_marc_fields returns correct data in second field');

    $schema->storage->txn_rollback;
};
