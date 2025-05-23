use utf8;
package Koha::Schema::Result::AqbooksellerAlias;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Koha::Schema::Result::AqbooksellerAlias

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<aqbookseller_aliases>

=cut

__PACKAGE__->table("aqbookseller_aliases");

=head1 ACCESSORS

=head2 vendor_alias_id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

primary key and unique identifier assigned by Koha

=head2 vendor_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

link to the vendor

=head2 alias

  data_type: 'varchar'
  is_nullable: 0
  size: 255

the alias

=cut

__PACKAGE__->add_columns(
  "vendor_alias_id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "vendor_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "alias",
  { data_type => "varchar", is_nullable => 0, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</vendor_alias_id>

=back

=cut

__PACKAGE__->set_primary_key("vendor_alias_id");

=head1 RELATIONS

=head2 vendor

Type: belongs_to

Related object: L<Koha::Schema::Result::Aqbookseller>

=cut

__PACKAGE__->belongs_to(
  "vendor",
  "Koha::Schema::Result::Aqbookseller",
  { id => "vendor_id" },
  { is_deferrable => 1, on_delete => "CASCADE", on_update => "CASCADE" },
);


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2025-05-13 16:36:20
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:y5DViXa8QqOFm3uhRp3jVw

=head2 koha_object_class

Missing POD for koha_object_class.

=cut

sub koha_object_class {
    'Koha::Acquisition::Bookseller::Alias';
}

=head2 koha_objects_class

Missing POD for koha_objects_class.

=cut

sub koha_objects_class {
    'Koha::Acquisition::Bookseller::Aliases';
}

1;
