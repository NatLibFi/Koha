package Koha::Template::Plugin::Holdings;

# Copyright ByWater Solutions 2012
# Copyright BibLibre 2014
# Copyright University of Helsinki 2017

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

use Koha::Holdings;

sub GetLocation {
    my ( $self, $holdingnumber ) = @_;

    if ( !$holdingnumber ) {
        return '';
    }

    my $holding = Koha::Holdings->find( $holdingnumber );
    if ( $holding ) {
        my @parts;

        push @parts, $holdingnumber;
        push @parts, $holding->holdingbranch() if $holding->holdingbranch();
        push @parts, $holding->location() if $holding->location();
        push @parts, $holding->callnumber() if $holding->callnumber();

        return join(' ', @parts);
    }
    return '';
}

1;
