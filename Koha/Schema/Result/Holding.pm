use utf8;
package Koha::Schema::Result::Holding;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Koha::Schema::Result::Holding

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<holdings>

=cut

__PACKAGE__->table("holdings");

=head1 ACCESSORS

=head2 holding_id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

unique identifier assigned to each holdings record

=head2 biblionumber

  data_type: 'integer'
  default_value: 0
  is_foreign_key: 1
  is_nullable: 0

foreign key from biblio table used to link this record to the right bib record

=head2 frameworkcode

  data_type: 'varchar'
  default_value: (empty string)
  is_nullable: 0
  size: 4

foreign key from the biblio_framework table to identify which framework was used in cataloging this record

=head2 holdingbranch

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 10

foreign key from the branches table for the library that owns this record (MARC21 852$a)

=head2 location

  data_type: 'varchar'
  is_nullable: 1
  size: 80

authorized value for the shelving location for this record (MARC21 852$b)

=head2 ccode

  data_type: 'varchar'
  is_nullable: 1
  size: 80

authorized value for the collection code associated with this item (MARC21 852$g)

=head2 callnumber

  data_type: 'varchar'
  is_nullable: 1
  size: 255

call number (852$h+$i in MARC21)

=head2 suppress

  data_type: 'tinyint'
  default_value: 0
  is_nullable: 0

Boolean indicating whether the record is suppressed in OPAC

=head2 timestamp

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: current_timestamp
  is_nullable: 0

date and time this record was last touched

=head2 datecreated

  data_type: 'date'
  datetime_undef_if_invalid: 1
  is_nullable: 0

the date this record was added to Koha

=head2 deleted_on

  data_type: 'datetime'
  datetime_undef_if_invalid: 1
  is_nullable: 1

the date this record was deleted

=cut

__PACKAGE__->add_columns(
  "holding_id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "biblionumber",
  {
    data_type      => "integer",
    default_value  => 0,
    is_foreign_key => 1,
    is_nullable    => 0,
  },
  "frameworkcode",
  { data_type => "varchar", default_value => "", is_nullable => 0, size => 4 },
  "holdingbranch",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 10 },
  "location",
  { data_type => "varchar", is_nullable => 1, size => 80 },
  "ccode",
  { data_type => "varchar", is_nullable => 1, size => 80 },
  "callnumber",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "suppress",
  { data_type => "tinyint", default_value => 0, is_nullable => 0 },
  "timestamp",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 0,
  },
  "datecreated",
  { data_type => "date", datetime_undef_if_invalid => 1, is_nullable => 0 },
  "deleted_on",
  {
    data_type => "datetime",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</holding_id>

=back

=cut

__PACKAGE__->set_primary_key("holding_id");

=head1 RELATIONS

=head2 biblionumber

Type: belongs_to

Related object: L<Koha::Schema::Result::Biblio>

=cut

__PACKAGE__->belongs_to(
  "biblionumber",
  "Koha::Schema::Result::Biblio",
  { biblionumber => "biblionumber" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);

=head2 holdingbranch

Type: belongs_to

Related object: L<Koha::Schema::Result::Branch>

=cut

__PACKAGE__->belongs_to(
  "holdingbranch",
  "Koha::Schema::Result::Branch",
  { branchcode => "holdingbranch" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "CASCADE",
  },
);

=head2 holdings_metadatas

Type: has_many

Related object: L<Koha::Schema::Result::HoldingsMetadata>

=cut

__PACKAGE__->has_many(
  "holdings_metadatas",
  "Koha::Schema::Result::HoldingsMetadata",
  { "foreign.holding_id" => "self.holding_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 items

Type: has_many

Related object: L<Koha::Schema::Result::Item>

=cut

__PACKAGE__->has_many(
  "items",
  "Koha::Schema::Result::Item",
  { "foreign.holding_id" => "self.holding_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07046 @ 2021-03-19 12:18:01
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Q9Pn2fbd7/xNx7heNn/n5Q

=head2 metadata

This relationship makes it possible to use metadata as a prefetch table:

my $holdings = Koha::Holdings->search({}, {prefetch => 'metadata'});
my $metadata = $holdings->next()->metadata();

=cut

__PACKAGE__->has_one(
  "metadata",
  "Koha::Schema::Result::HoldingsMetadata",
  { "foreign.holding_id" => "self.holding_id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

__PACKAGE__->add_columns(
    '+suppress' => { is_boolean => 1 },
);

1;
