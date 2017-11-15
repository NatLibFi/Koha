use utf8;
package Koha::Schema::Result::DeletedholdingsMetadata;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Koha::Schema::Result::DeletedholdingsMetadata

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<deletedholdings_metadata>

=cut

__PACKAGE__->table("deletedholdings_metadata");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 holdingnumber

  data_type: 'integer'
  is_nullable: 0

=head2 format

  data_type: 'varchar'
  is_nullable: 0
  size: 16

=head2 marcflavour

  data_type: 'varchar'
  is_nullable: 0
  size: 16

=head2 metadata

  data_type: 'longtext'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "holdingnumber",
  { data_type => "integer", is_nullable => 0 },
  "format",
  { data_type => "varchar", is_nullable => 0, size => 16 },
  "marcflavour",
  { data_type => "varchar", is_nullable => 0, size => 16 },
  "metadata",
  { data_type => "longtext", is_nullable => 0 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");


# Created by DBIx::Class::Schema::Loader v0.07045 @ 2017-11-13 15:27:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:04H0Q+1rygNEahEhA5tUKA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
