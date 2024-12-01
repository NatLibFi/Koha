package Koha::Holdings::Metadata;

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

use C4::Charset qw( StripNonXmlChars );

use Koha::Database;
use Koha::Exceptions::Metadata;

use base qw(Koha::Object);

=head1 NAME

Koha::Holdings::Metadata - Koha Holdings Metadata Object class

=head1 API

=head2 Class methods

=cut

=head3 record

my $record = $metadata->record;

Returns an object representing the metadata record. The expected record type
corresponds to this table:

    -------------------------------
    | format     | object type    |
    -------------------------------
    | marcxml    | MARC::Record   |
    -------------------------------

=head4 Error handling

=over

=item If an unsupported format is found, it throws a I<Koha::Exceptions::Metadata> exception.

=item If it fails to create the record object, it throws a I<Koha::Exceptions::Metadata::Invalid> exception.

=back

=cut

sub record {
    my ($self) = @_;

    my $record;

    if ($self->format eq 'marcxml') {
        $record = eval { MARC::Record::new_from_xml( $self->metadata, 'utf-8', $self->schema ); };
        unless ($record) {
            Koha::Exceptions::Metadata::Invalid->throw(
                id     => $self->id,
                format => $self->format,
                schema => $self->schema
            );
        }
    } else {
        Koha::Exceptions::Metadata->throw(
            'Koha::Holdings::Metadata->record called on unhandled format: ' . $self->format );
    }

    return $record;
}

=head3 record_strip_nonxml

my $record = $metadata->record_strip_nonxml;

This subroutine is intended for cases where we encounter a record that cannot be parsed, but want
to make a good effort to present the record (for harvesting, deletion, editing) rather than throwing
an exception

Will return undef if the record cannot be built

=cut

sub record_strip_nonxml {

    my ( $self, $params ) = @_;
    $params //= {};

    my $record;
    my $marcxml_error;

    eval {
        $record = MARC::Record->new_from_xml(
            StripNonXmlChars( $self->metadata ), 'UTF-8',
            $self->schema
        );
    };
    if ($@) {
        $marcxml_error = $@;
        chomp $marcxml_error;
        warn $marcxml_error;
        return;
    }

    return $self->record( { %$params, record => $record } );
}

=head3 source_allows_editing

    if ( $metadata->source_allows_editing ) { ... }

Returns a boolean denoting whether the metadata's record source allows
it to be edited.

=cut

sub source_allows_editing {
    my ($self) = @_;

    return 1;
    # TODO: obtain as sample from Biblios?
    # my $rs = $self->_result->record_source;
    # return 1 unless $rs;
    # return $rs->can_be_edited;
}

=head3 record_source

    my $record_source = $metadata->record_source;

Returns a I<Koha::RecordSource> object for the linked record source.

=cut

sub record_source {
    my ($self) = @_;

    return;
    # TODO: obtain as sample from Biblios?
    # my $rs = $self->_result->record_source;
    # return unless $rs;
    # return Koha::RecordSource->_new_from_dbic($rs);
}

=head2 Internal methods

=head3 _type

=cut

sub _type {
    return 'HoldingsMetadata';
}

=head1 AUTHOR

Ere Maijala ere.maijala@helsinki.fi

=cut

1;
