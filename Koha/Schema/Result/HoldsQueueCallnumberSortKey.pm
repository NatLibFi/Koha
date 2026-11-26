package Koha::Schema::Result::HoldsQueueCallnumberSortKey;

# Copyright 2026 Nugged Team
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or any later version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;
use base qw(DBIx::Class::Core);

=head1 NAME

Koha::Schema::Result::HoldsQueueCallnumberSortKey

=head1 DESCRIPTION

A virtual, read-only source with one classification sort key per queue item.
Declaring the key as a column lets DBIC preserve grouping and pagination when
report searches join multiple bibliographic item rows. No database view is
created. Missing item keys fall back to the queue's displayed call number.

=cut

__PACKAGE__->table_class('DBIx::Class::ResultSource::View');
__PACKAGE__->table('holds_queue_callnumber_sort_key');
__PACKAGE__->add_columns(
    itemnumber => { data_type => 'integer', is_nullable => 0 },
    sort_key   => { data_type => 'varchar', size => 255, is_nullable => 1 },
);
__PACKAGE__->set_primary_key('itemnumber');
__PACKAGE__->result_source_instance->is_virtual(1);
__PACKAGE__->result_source_instance->view_definition(
    q{
        SELECT q.itemnumber,
               COALESCE(NULLIF(i.cn_sort, ''), q.itemcallnumber) AS sort_key
        FROM tmp_holdsqueue q
        LEFT JOIN items i ON i.itemnumber = q.itemnumber
    }
);

1;
