package Koha::Serial::Item;

# Copyright ByWater Solutions 2016
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

use Koha::Database;

use base qw(Koha::Object);

use Koha::Serials;

=head1 NAME

Koha::Serial::Item - Koha Serial Item Object class

=head1 API

=head2 Class Methods

=cut

=head3 serial

=cut

sub serial {
    my ($self) = @_;
    my $rs = $self->_result->serialid;
    return unless $rs;
    return Koha::Serial->_new_from_dbic($rs);
}

=head3 type

=cut

sub _type {
    return 'Serialitem';
}

=head1 AUTHOR

Kyle M Hall <kyle@bywatersolutions.com>

=cut

1;
