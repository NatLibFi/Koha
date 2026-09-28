package Koha::Holding;

# Copyright ByWater Solutions 2014
# Copyright 2017-2020 University of Helsinki (The National Library Of Finland)
#
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

use Carp;

use C4::Charset qw( SetUTF8Flag );
use C4::Log qw( logaction );

use Koha::Biblio;
use Koha::Database;
use Koha::DateUtils qw(dt_from_string);
use Koha::Holdings::Metadatas;
use Koha::Items;

use base qw(Koha::Object);

=head1 NAME

Koha::Holding - Koha Holding Object class

=head1 API

=head2 Class Methods

=cut

=head3 biblio

  my $biblio = $holding->biblio();

Returns the holding biblio for this record.

=cut

sub biblio {
    my ($self) = @_;

    my $biblio = $self->_result->biblionumber();
    return unless $biblio;
    return Koha::Biblio->_new_from_dbic($biblio);
}

=head3 holding_branch

my $branch = $hold->holding_branch();

Returns the holding branch for this record.

=cut

sub holding_branch {
    my ($self) = @_;

    my $branch = $self->_result->holdingbranch();
    return unless $branch;
    return Koha::Library->_new_from_dbic($branch);
}

=head3 metadata

my $metadata = $holding->metadata();

Returns a Koha::Holding::Metadata object

=cut

sub metadata {
    my ($self) = @_;

    my $metadata = $self->_result()->metadata();
    return unless $metadata;
    return Koha::Holdings::Metadata->_new_from_dbic($metadata);
}

=head3 record

my $record = $holding->record();

Returns a Marc::Record object

=cut

sub record {
    my ( $self ) = @_;

    return $self->metadata->record;
}

=head3 can_be_edited

    if ( $holding->can_be_edited( $patron ) ) { ... }

Returns a boolean denoting whether the passed I<$patron> meets the required
conditions to manually edit the record (follows up how its made for biblio).

=cut

sub can_be_edited {
    my ( $self, $patron ) = @_;

    Koha::Exceptions::MissingParameter->throw( error => "The patron parameter is missing or invalid" )
        unless $patron && ref($patron) eq 'Koha::Patron';

    return (
        ( $self->metadata->source_allows_editing && $patron->has_permission( { editcatalogue => 'edit_catalogue' } ) )
            || $patron->has_permission( { editcatalogue => 'edit_locked_records' } ) ) ? 1 : 0;
}

=head3 set_marc

$holding->set_marc({ record => $record });

Updates the MARC format metadata from a Marc::Record.
Does not store the results in the database.

If passed an undefined record will log the error.

Returns $self

=cut

sub set_marc {
    my ($self, $params) = @_;

    if (!defined $params->{record}) {
        carp('set_marc called with undefined record');
        return $self;
    }

    # Clone record as it gets modified
    my $record = $params->{record}->clone();
    SetUTF8Flag($record);
    my $encoding = C4::Context->preference('marcflavour');
    if ($encoding eq 'MARC21' || $encoding eq 'UNIMARC') {
      # YY MM DD HH MM SS (update year and month)
      my @a = (localtime) [5,4,3,2,1,0]; $a[0] += 1900; $a[1]++;
      my $f005 = $record->field('005');
      $f005->update(sprintf('%4d%02d%02d%02d%02d%04.1f', @a)) if $f005;
    }

    $self->{_marcxml} = $record->as_xml_record($encoding);
    my $fields = $self->marc_to_koha_fields({ record => $record });
    delete $fields->{holding_id};
    # Filter the columns since we have e.g. public_note that's not stored in the database
    my $columns = [$self->_result()->result_source()->columns()];
    my $db_fields = {};
    foreach my $key (keys %{$fields}) {
        if (grep {/^$key$/} @{$columns}) {
            $db_fields->{$key} = $fields->{$key};
        }
    }
    $self->set($db_fields);

    return $self;
}

=head3 items

my $items = $holding->items();

Returns the related Koha::Items object for this record.

=cut

sub items {
    my ($self) = @_;

    my $items_rs = $self->_result->items;
    return Koha::Items->_new_from_dbic($items_rs);
}

=head3 store

    $holding->store([$params]);

Saves the holdings record.

$params can take an optional 'skip_record_index' parameter.
If set, the reindexing process will not happen (index_records is not called).
This is useful for batch processes where the biblio record is reindexed at the end.

Returns:
    $self  if the store was a success
    undef  if the store failed

=cut

sub store {
    my ($self, $params) = @_;

    $params //= {};

    my $action = $self->holding_id() ? 'MODIFY' : 'ADD';

    $self->datecreated(dt_from_string('', 'sql')) unless $self->datecreated();

    my $schema = Koha::Database->new()->schema();
    # Use a transaction only if AutoCommit is enabled - otherwise handled outside of this sub
    my $guard = C4::Context->dbh->{AutoCommit} ? $schema->txn_scope_guard() : undef;

    my $result = $self->SUPER::store();

    return unless $result;

    # Create or update the metadata record
    my $marcflavour = C4::Context->preference('marcflavour');
    my $marc_record = $self->{_marcxml}
        ? MARC::Record::new_from_xml($self->{_marcxml}, 'utf-8', $marcflavour)
        : $self->metadata()->record();
    my $old_marc = $marc_record->as_formatted;

    $self->_update_marc_ids($marc_record);

    my $metadata = {
        holding_id => $self->holding_id(),
        format     => 'marcxml',
        schema     => $marcflavour,
        metadata   => $marc_record->as_xml_record($marcflavour),
    };
    Koha::Holdings::Metadatas->update_or_create($metadata);
    $guard->commit() if defined $guard;

    # request that bib be reindexed so that any holdings-derived fields are updated
    unless ( $params->{skip_record_index} ) {
        my $indexer = Koha::SearchEngine::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX });
        $indexer->index_records( $self->biblionumber, "specialUpdate", "biblioserver" );
    }

    if (C4::Context->preference('CataloguingLog')) {
        logaction('CATALOGUING', $action, $self->holding_id(), $action eq 'ADD' ? 'holding' : "holding BEFORE=>$old_marc");
    }

    return $self;
}

=head3 delete

    $holding->delete();

Marks the holdings record deleted.

Returns:
    1  if the deletion was a success
    0  if the deletion failed
    -1 if the object was never in storage

=cut

sub delete {
    my ($self) = @_;

    return -1 unless $self->_result()->in_storage();

    if ($self->items()->count()) {
        return 0;
    }

    my $schema = Koha::Database->new()->schema();
    # Use a transaction only if AutoCommit is enabled - otherwise handled outside of this sub
    my $guard = C4::Context->dbh->{AutoCommit} ? $schema->txn_scope_guard() : undef;

    my $now = dt_from_string('', 'sql');
    $self->deleted_on($now)->store();
    Koha::Holdings::Metadatas->find({ holding_id => $self->holding_id() })->update({ deleted_on => $now });

    $guard->commit() if defined $guard;

    logaction('CATALOGUING', 'DELETE', $self->holding_id(), 'holding') if C4::Context->preference('CataloguingLog');

    return 1;
}

=head3 move_to_biblio

  $holding->move_to_biblio($to_biblio[, $params]);

Move the holdings record and any of its related records to another biblio.

The final optional parameter, C<$params>, is expected to contain the
'skip_record_index' key, which is relayed down to Koha::Holding->store.
There it prevents calling index_records, which takes most of the
time in batch adds/deletes. The caller must take care of calling
index_records separately.

$params:
    skip_record_index => 1|0

=cut

sub move_to_biblio {
    my ( $self, $to_biblio, $params ) = @_;

    $params //= {};

    my $old_biblionumber = $self->biblionumber;
    my $biblionumber = $to_biblio->biblionumber;

    # Own biblionumber
    $self->set({
        biblionumber => $biblionumber,
    })->store({ skip_record_index => 1 });

    # Items
    my $items => $self->items;
    if ($items) {
        while (my $item = $items->next()) {
            $item->move_to_biblio($to_biblio, { skip_record_index => 1 });
        }
    }

    # Request that bib be reindexed unless skip_record_index is set
    if (!$params->{skip_record_index}) {
        my $indexer = Koha::SearchEngine::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX });
        $indexer->index_records( $old_biblionumber, "specialUpdate", "biblioserver" );
        $indexer->index_records( $self->biblionumber, "specialUpdate", "biblioserver" );
    }
}

=head3 type

=cut

sub _type {
    return 'Holding';
}

=head2 marc_to_koha_fields

    $result = Koha::Holding->marc_to_koha_fields({ record => $record })

Extract data from a MARC::Record holdings record into a hashref representing
Koha holdings fields.

If passed an undefined record will log the error and return an empty
hash_ref.

=cut

sub marc_to_koha_fields {
    my ($class, $params) = @_;

    my $result = {};
    if (!defined $params->{record}) {
        carp('marc_to_koha_fields called with undefined record');
        return $result;
    }
    my $record = $params->{record};

    # The next call uses the HLD framework since it is AUTHORITATIVE
    # for all Koha to MARC mappings for holdings.
    my $mss = C4::Biblio::GetMarcSubfieldStructure('HLD', { unsafe => 1 }); # Do not change framework
    foreach my $kohafield (keys %{ $mss }) {
        my ($table, $column) = split /[.]/, $kohafield, 2;
        next unless $table eq 'holdings' && $mss->{$kohafield};

        if ( $column eq 'callnumber' && C4::Context->preference('itemcallnumber') ) {

            my @CN_prefs_mapping;
            foreach my $itemcn_pref (split(/,/,C4::Context->preference('itemcallnumber'))){
                my $CNtag      = substr( $itemcn_pref, 0, 3 );
                my @CNsubfields = split('',substr( $itemcn_pref, 3 ));
                @CNsubfields = ('') unless @CNsubfields;
                foreach my $CNsubfield (@CNsubfields) {
                    push @CN_prefs_mapping, { tagfield => $CNtag, tagsubfield => $CNsubfield };
                }
            }
            @{$mss->{$kohafield}} = @CN_prefs_mapping if @CN_prefs_mapping;
        }

        my @values;
        foreach my $field (@{$mss->{$kohafield}}) {
            my $tag = $field->{tagfield};
            my $sub = $field->{tagsubfield};
            foreach my $fld ($record->field($tag)) {
                if( $sub eq '@' || $fld->is_control_field ) {
                    push @values, $fld->data;
                } else {
                    push @values, $fld->subfield($sub);
                }
            }
        }
        $result->{$column} = scalar(@values) ? join(' ', @values) : undef;
        # Note: here separation of field values done just by space, i.e. no special
        # separator char between - as requested by customers (librarians noted they
        # using this merged field for quick copy-pasting, and more: if extra chars,
        # that confuses patrons: they read roman numbers with extra separators wrongly)
    }

    # convert suppress field to boolean
    $result->{'suppress'} = $result->{'suppress'} ? 1 : 0;

    return $result;
}

=head3 get_marc_field_mapping

    ($field, $subfield) = Koha::Holding->get_marc_field_mapping({ field => $kohafield });
    @fields = Koha::Holding->get_marc_field_mapping({ field => $kohafield });
    $field = Koha::Holding->get_marc_field_mapping({ field => $kohafield });

    Returns the MARC fields & subfields mapped to $kohafield.
    Uses the HLD framework that is considered as authoritative.

    In list context all mappings are returned; there can be multiple
    mappings. Note that in the above example you could miss a second
    mapping in the first call.
    In scalar context only the field tag of the first mapping is returned.

=cut

sub get_marc_field_mapping {
    my ($class, $params) = @_;

    return unless $params->{field};

    # The next call uses the HLD framework since it is AUTHORITATIVE
    # for all Koha to MARC mappings for holdings.
    my $mss = C4::Biblio::GetMarcSubfieldStructure('HLD', { unsafe => 1 }); # Do not change framework
    my @retval;
    foreach (@{ $mss->{$params->{field}} }) {
        push @retval, $_->{tagfield}, $_->{tagsubfield};
    }
    return wantarray ? @retval : ( @retval ? $retval[0] : undef );
}

=head2 Internal methods

=head3 _update_marc_ids

  $self->_update_marc_ids($record);

Internal function to add or update holding_id, biblionumber and biblioitemnumber to
the MARC record.

=cut

sub _update_marc_ids {
    my ($self, $record) = @_;

    my ($holding_tag, $holding_subfield) = $self->get_marc_field_mapping({ field => 'holdings.holding_id' });
    die qq{No holding_id tag for framework "HLD"} unless $holding_tag;
    if ($holding_tag < 10) {
        C4::Biblio::UpsertMarcControlField($record, $holding_tag, $self->holding_id);
    } else {
        C4::Biblio::UpsertMarcSubfield($record, $holding_tag, $holding_subfield, $self->holding_id);
    }

    my ($biblio_tag, $biblio_subfield) = $self->get_marc_field_mapping({ field => 'biblio.biblionumber' });
    die qq{No biblionumber tag for framework "HLD"} unless $biblio_tag;
    if ($biblio_tag < 10) {
        C4::Biblio::UpsertMarcControlField($record, $biblio_tag, $self->biblionumber);
    } else {
        C4::Biblio::UpsertMarcSubfield($record, $biblio_tag, $biblio_subfield, $self->biblionumber);
    }
}


=head1 AUTHOR

Kyle M Hall <kyle@bywatersolutions.com>
Ere Maijala <ere.maijala@helsinki.fi>

=cut

1;
