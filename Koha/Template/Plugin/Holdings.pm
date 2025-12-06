package Koha::Template::Plugin::Holdings;

# Copyright ByWater Solutions 2012
# Copyright BibLibre 2014
# Copyright 2017-2019 University of Helsinki (The National Library Of Finland)

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

use Template::Plugin;
use base qw( Template::Plugin );

use C4::Context;

use Koha::Holdings;

=head1 NAME

Koha::Template::Plugin::Holdings - TT Plugin for holdings

=head1 SYNOPSIS

[% USE Holdings %]

[% Holdings.GetLocation(holding) | html %]

=head1 ROUTINES

=head2 GetLocation

Get a location string for a holdings record

    [% Holdings.GetLocation(holding) | html %]

=cut

sub GetLocation {
    my ($self, $holding) = @_;
    my $opac = shift || 0;

    if (!$holding) {
        return '';
    }

    if (ref($holding) ne 'Koha::Holding') {
        $holding = Koha::Holdings->find($holding);
        if (!$holding) {
            return '';
        }
    }

    my @parts;

    if ($opac) {
        if (my $branch = $holding->holding_branch()) {
            push @parts, $branch->branchname();
        }
        if ($holding->location()) {
            my $av = Koha::AuthorisedValues->search({ category => 'LOC', authorised_value => $holding->location() });
            push @parts, $av->next()->opac_description() if $av->count;
        }
        push @parts, $holding->callnumber() if $holding->callnumber();
        return join(' - ', @parts);
    }

    push @parts, $holding->holding_id();
    push @parts, $holding->holdingbranch() if $holding->holdingbranch();
    push @parts, $holding->location() if $holding->location();
    push @parts, $holding->ccode() if $holding->ccode();
    push @parts, $holding->callnumber() if $holding->callnumber();
    return join(' ', @parts);
}

=head2 GetDetails

Get the Koha fields for a holdings record

    [% details = Holdings.GetDetails(holding) %]

=cut

sub GetDetails {
    my ($self, $holding) = @_;
    my $opac = shift || 0;

    if (!$holding) {
        return '';
    }

    if (ref($holding) ne 'Koha::Holding') {
        $holding = Koha::Holdings->find($holding);
        if (!$holding) {
            return '';
        }
    }

    my $holding_marc = $holding->metadata()->record();

    return Koha::Holding->marc_to_koha_fields({ record => $holding_marc });
}

1;
