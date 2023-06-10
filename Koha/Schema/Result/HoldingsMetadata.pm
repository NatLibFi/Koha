use utf8;
package Koha::Schema::Result::HoldingsMetadata;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Koha::Schema::Result::HoldingsMetadata

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<holdings_metadata>

=cut

__PACKAGE__->table("holdings_metadata");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 holding_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 format

  data_type: 'varchar'
  is_nullable: 0
  size: 16

=head2 schema

  data_type: 'varchar'
  is_nullable: 0
  size: 16

=head2 metadata

  data_type: 'longtext'
  is_nullable: 0

=head2 deleted_on

  data_type: 'datetime'
  datetime_undef_if_invalid: 1
  is_nullable: 1

the date this record was deleted

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "holding_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "format",
  { data_type => "varchar", is_nullable => 0, size => 16 },
  "schema",
  { data_type => "varchar", is_nullable => 0, size => 16 },
  "metadata",
  { data_type => "longtext", is_nullable => 0 },
  "deleted_on",
  {
    data_type => "datetime",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<holdings_metadata_uniq_key>

=over 4

=item * L</holding_id>

=item * L</format>

=item * L</schema>

=back

=cut

__PACKAGE__->add_unique_constraint(
  "holdings_metadata_uniq_key",
  ["holding_id", "format", "schema"],
);

=head1 RELATIONS

=head2 holding

Type: belongs_to

Related object: L<Koha::Schema::Result::Holding>

=cut

__PACKAGE__->belongs_to(
  "holding",
  "Koha::Schema::Result::Holding",
  { holding_id => "holding_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07048 @ 2021-01-24 12:34:57
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:msXxqOTn5rKZf188+KFk8g


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
