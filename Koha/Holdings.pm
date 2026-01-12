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

use Carp qw( carp );

use C4::Biblio;
use C4::Charset qw( SetMarcUnicodeFlag );
use C4::Context;

use MARC::Field;

use Koha::Holding;

use base qw(Koha::Objects);

=head1 NAME

Koha::Holdings - Koha Holdings object set class

=head1 API

=head2 Class Methods

=cut

=head3 get_embeddable_marc_fields

  my $marc_fields = Koha::Holdings->get_embeddable_marc_fields({
      biblionumber       => $biblionumber,
      embed_holdings_mode => 'oai',      # oai | search | item_edit
  });

Returns an arrayref of MARC::Field objects taken from the MARC holdings (MFHD) records
attached to the given biblionumber.
The list of tags to embed is controlled by the SummaryHoldingsEmbedTagsInBiblio or
SummaryHoldingsEmbedTagsInSearch system preference, depending on the embed_holdings_mode parameter.
(comma-separated list of three-digit tags and subtags with negation, e.g. "583!x,852!x", "852abc").

=cut

my %mode_map = (
    oai       => [ 'SummaryHoldingsEmbedTagsInBiblio', '852!x'   ],
    item_edit => [ 'SummaryHoldingsEmbedTagsInBiblio', '852!x'   ],
    search    => [ 'SummaryHoldingsEmbedTagsInSearch', '583!x,852!x' ],
);

sub get_embeddable_marc_fields {
    my ( $class, $params ) = @_;

    if ( !defined $params->{biblionumber} ) {
        carp 'get_embeddable_marc_fields called with undefined biblionumber';
        return [];
    }

    # Read preference:
    #   undef  -> use default: "852!x" only
    #   ''     -> explicitly no embedding
    #   'all'  -> embed all MFHD data fields (except control fields 00X and 999)
    my $mode = $params->{embed_holdings_mode} // '';
    my $map  = $mode_map{$mode};
    if ( !$map ) {
        carp "get_embeddable_marc_fields called with unknown embed_holdings_mode: $mode"
            if defined $params->{embed_holdings_mode};   # warn only if caller passed it
        # default to oai mode since it the safest
        $map = $mode_map{oai};
    }

    my ( $pref_name, $default ) = @$map;
    my $pref = C4::Context->preference($pref_name) // $default;
    $pref =~ s/^\s+|\s+$//g;

    # Explicitly no embedding if empty string:
    return [] if $pref eq '';

    my ( $embed_all, $tag_rules ) = _parse_embed_spec($pref);

    # return early if we won't embed anything - avoids unnecessary DB queries and MARC processing
    return [] if !$embed_all && !%$tag_rules;

    my $holdings = $class->search({
        biblionumber => $params->{biblionumber},
        ( $params->{holding_id} ? ( holding_id => $params->{holding_id} ) : () ),
        deleted_on => undef,
    }, { order_by => { -asc => 'holding_id' } } );

    my @holdings_fields;
    while ( my $holding = $holdings->next ) {
        next unless $holding->metadata;

        my $full_marc = $holding->metadata->record;
        next unless $full_marc;

        for my $field ( $full_marc->fields ) {
            my $tag = $field->tag;

            # Never embed control fields 00X (001–009) nor Koha internal 999
            next if $tag !~ /^\d{3}$/ || $tag < 10 || $tag == 999;

            my $rule = $tag_rules->{$tag};

            # If not "all", only take tags explicitly configured
            next if !$embed_all && !$rule;

            my $filtered = _apply_rule_to_field( $field, $rule );
            push @holdings_fields, $filtered if $filtered;
        }
    }

    return \@holdings_fields;
}

# Filter a MARC::Field according to a parsed rule (include/exclude/all/skip).
sub _apply_rule_to_field {
    my ( $field, $rule ) = @_;

    # No rule (in "all" mode) => keep full field
    return $field->clone if !$rule || $rule->{type} eq 'all';

    return if $rule->{type} eq 'skip';

    my @subfields = $field->subfields;
    return unless @subfields;

    my $set = $rule->{set};

    my @kept =
        $rule->{type} eq 'include'
        ? grep { $set->{ $_->[0] } } @subfields
        : grep { !$set->{ $_->[0] } } @subfields;

    return unless @kept;

    my @flat = map { @$_ } @kept;
    return MARC::Field->new(
        $field->tag,
        $field->indicator(1),
        $field->indicator(2),
        @flat
    );
}

sub _parse_embed_spec {
    my ($pref) = @_;

    my $embed_all = 0;
    my %rules;

    for my $raw ( split /\s*,\s*/, $pref ) {
        next unless length $raw;

        if ( lc($raw) eq 'all' ) {
            $embed_all = 1;
            next;
        }

        # Single tag spec: 852 / 852abc / 852!x
        my ( $tag, $rest ) = $raw =~ /^(\d{3})(.*)$/;
        if ( !$tag ) {
            carp "Invalid tag spec ignored: $raw";
            next;
        }

        my $new_rule = _parse_tag_rule( $tag, $rest );
        if ( my $old = $rules{$tag} ) {
            my ( $ot, $nt ) = ( $old->{type}, $new_rule->{type} );

            if ( $ot eq 'all' && $nt ne 'all' ) {
                # any non-bare rule overrides bare tag ("all"); this also lets 'skip' poison the tag
                $rules{$tag} = $new_rule;
            }
            elsif ( $ot eq $nt && $new_rule->{set} ) {
                $old->{set}{$_} = 1 for keys %{ $new_rule->{set} };  # merge sets
            }
            elsif ( $ot ne $nt && $nt ne 'all' ) {
                carp "Conflicting subfield specs for tag $tag, skipping tag entirely";
                $rules{$tag} = { type => 'skip' };
            }
            # else: bare tag does NOT override a more specific rule (first-specific-wins),
            # and duplicate bare tags are harmless - keep existing rule
            next;
        }
        $rules{$tag} = $new_rule;
    }

    return ( $embed_all, \%rules );
}

sub _parse_tag_rule {
    my ( $tag, $rest ) = @_;

    $rest //= '';
    $rest =~ s/^\s+|\s+$//g;
    $rest =~ s/^(!?)\$(.+)/$1$2/;         # allow "852$ab" "852!$ab" as well
    if ( $rest =~ /\s/ ) {
        carp "Whitespace is not allowed inside tag spec '$tag$rest' (did you forget a comma?)";
        return { type => 'skip' };
    }

    # Bare tag → embed all subfields
    return { type => 'all' } if $rest eq '';

    # Exclude mode: !xz
    if ( $rest =~ /^!([0-9a-zA-Z]+)$/ ) {
        return { type => 'exclude', set => _parse_subfield_set($1) };
    }

    # Include mode: abc
    if ( $rest =~ /^[0-9a-zA-Z]+$/ ) {
        return { type => 'include', set => _parse_subfield_set($rest) };
    }

    # Anything else is a syntax error → skip tag entirely
    carp "Invalid subfield spec for tag $tag: '$rest', skipping";
    return { type => 'skip' };
}

sub _parse_subfield_set {
    my ($s) = @_;
    return { map { $_ => 1 } split //, ($s // '') };
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
