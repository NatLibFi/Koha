use utf8;
package Koha::Schema::Result::Deletedholding;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Koha::Schema::Result::Deletedholding

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<deletedholdings>

=cut

__PACKAGE__->table("deletedholdings");

=head1 ACCESSORS

=head2 holdingnumber

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 biblionumber

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 biblioitemnumber

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 frameworkcode

  data_type: 'varchar'
  default_value: (empty string)
  is_nullable: 0
  size: 4

=head2 holdingbranch

  data_type: 'varchar'
  is_nullable: 1
  size: 10

=head2 location

  data_type: 'varchar'
  is_nullable: 1
  size: 80

=head2 callnumber

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 suppress

  data_type: 'tinyint'
  is_nullable: 1

=head2 timestamp

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: current_timestamp
  is_nullable: 0

=head2 datecreated

  data_type: 'date'
  datetime_undef_if_invalid: 1
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "holdingnumber",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "biblionumber",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "biblioitemnumber",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "frameworkcode",
  { data_type => "varchar", default_value => "", is_nullable => 0, size => 4 },
  "holdingbranch",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "location",
  { data_type => "varchar", is_nullable => 1, size => 80 },
  "callnumber",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "suppress",
  { data_type => "tinyint", is_nullable => 1 },
  "timestamp",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 0,
  },
  "datecreated",
  { data_type => "date", datetime_undef_if_invalid => 1, is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</holdingnumber>

=back

=cut

__PACKAGE__->set_primary_key("holdingnumber");


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2017-11-13 15:27:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:8g64WcrAsNSBCXkUx9OVPg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
