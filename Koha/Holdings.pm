package Koha::Holdings;

# Copyright ByWater Solutions 2015
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

use C4::Biblio;
use C4::Charset qw( SetMarcUnicodeFlag );
use C4::Context;

use Koha::Holding;

use base qw(Koha::Objects);

=head1 NAME

Koha::Holdings - Koha Holdings object set class

=head1 API

=head2 Class Methods

=cut

=head3 get_embeddable_marc_fields

  my $marc_fields = Koha::Holdings->get_embeddable_marc_fields({ biblionumber => $biblionumber });

Returns an arrayref of MARC::Field objects taken from the MARC holdings (MFHD) records
attached to the given biblionumber.

=cut

sub get_embeddable_marc_fields {
    my ( $class, $params ) = @_;

    my @holdings_fields;

    if ( not defined $params->{biblionumber} ) {
        carp('get_embeddable_marc_fields called with undefined biblionumber');
        return \@holdings_fields;
    }

    my ($holdingstag, $holdingssubfield) = Koha::Holding->get_marc_field_mapping({ field => 'holdings.holdingbranch' });
    my $holdings = $class->search({
        biblionumber => $params->{biblionumber},
        ($params->{holding_id} ? (holding_id => $params->{holding_id}) : ()),
        deleted_on => undef })->unblessed();
    foreach my $holding (@$holdings) {
        my $mungedholding = {
            map {
                defined($holding->{$_}) && $holding->{$_} ne '' ? ("holdings.$_" => $holding->{$_}) : ()
            } keys %{ $holding }
        };
        my $marc = $class->_holding_to_marc($mungedholding);
        push @holdings_fields, $marc->field($holdingstag);
    }

    return \@holdings_fields;
}

=head2 _holding_to_marc

    $record = $class->_holding_to_marc($hash)

This function builds partial MARC::Record from holdings hash entries.
This function is called when embedding holdings into a biblio record.

=cut

sub _holding_to_marc {
    my ( $class, $hash, $params ) = @_;

    my $record = MARC::Record->new();
    SetMarcUnicodeFlag($record, C4::Context->preference('marcflavour'));

    # The next call uses the HLD framework since it is AUTHORITATIVE
    # for all Koha to MARC mappings for holdings.
    my $mss = C4::Biblio::GetMarcSubfieldStructure('HLD', { unsafe => 1 }); # do not change framewok
    my $tag_hr = {};
    while (my ($kohafield, $value) = each %$hash) {
        foreach my $fld (@{$mss->{$kohafield}}) {
            my $tagfield    = $fld->{tagfield};
            my $tagsubfield = $fld->{tagsubfield};
            next if !$tagfield;
            my @values = $params->{no_split}
                ? ( $value )
                : split(/\s?\|\s?/, $value, -1);
            foreach my $value (@values) {
                next if $value eq '';
                $tag_hr->{$tagfield} //= [];
                push @{$tag_hr->{$tagfield}}, [($tagsubfield, $value)];
            }
        }
    }
    foreach my $tag (sort keys %$tag_hr) {
        my @sfl = @{$tag_hr->{$tag}};
        @sfl = sort { $a->[0] cmp $b->[0]; } @sfl;
        @sfl = map { @{$_}; } @sfl;
        # Special care for control fields: remove the subfield indication @
        # and do not insert indicators.
        my @ind = $tag < 10 ? () : ( " ", " " );
        @sfl = grep { $_ ne '@' } @sfl if $tag < 10;
        $record->insert_fields_ordered(MARC::Field->new($tag, @ind, @sfl));
    }
    return $record;
}

=head3 move_to_biblio

 $holdings->move_to_biblio($to_biblio);

Move items to a given biblio.

=cut

sub move_to_biblio {
    my ( $self, $to_biblio ) = @_;

    my $biblionumbers = { $to_biblio->biblionumber => 1 };
    while (my $holding = $self->next()) {
        $biblionumbers->{ $holding->biblionumber } = 1;
        $holding->move_to_biblio( $to_biblio, { skip_record_index => 1 } );
    }
    my $indexer = Koha::SearchEngine::Indexer->new({ index => $Koha::SearchEngine::BIBLIOS_INDEX });
    for my $biblionumber ( keys %{$biblionumbers} ) {
        $indexer->index_records( $biblionumber, "specialUpdate", "biblioserver" );
    }

    return;
}

=head2 Internal methods

=head3 _type

=cut

sub _type {
    return 'Holding';
}

=head3 object_class

=cut

sub object_class {
    return 'Koha::Holding';
}

=head1 AUTHOR

Kyle M Hall <kyle@bywatersolutions.com>
Ere Maijala <ere.maijala@helsinki.fi>

=cut

1;
