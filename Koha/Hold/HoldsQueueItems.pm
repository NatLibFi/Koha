package Koha::Hold::HoldsQueueItems;

# Copyright 2023 Koha development team
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
# along with Koha; if not, see <https://www.gnu.org/licenses>.

use Modern::Perl;

use C4::Context;
use Koha::Database;

use Koha::Hold::HoldsQueueItem;

use base qw(Koha::Objects);

=head1 NAME

Koha::Hold::HoldsQueueItems - Koha holds queue items object set class

=head1 API

=head2 Class methods

=head3 search

Apply HoldsCallnumberSortQueue when ordering by the queue's call number.
Missing classification keys fall back to the displayed call number. Call number
ties are resolved by item number, after any other requested ordering fields.

=cut

sub search {
    my ( $self, $params, $attributes ) = @_;

    return $self->SUPER::search( $params, $attributes ) unless $attributes->{order_by};

    my @requested =
        ref( $attributes->{order_by} ) eq 'ARRAY'
        ? @{ $attributes->{order_by} }
        : ( $attributes->{order_by} );
    my @order_by;
    my $callnumber_direction;
    my $classification = ( C4::Context->preference('HoldsCallnumberSortQueue') // '' ) eq 'classification';

    for my $order (@requested) {
        my ( $direction, $column ) = ( '-asc', $order );
        if ( ref($order) eq 'HASH' && keys %$order == 1 ) {
            ($direction) = keys %$order;
            $column = $order->{$direction};
        }
        unless ( $direction =~ /\A-(?:asc|desc)\z/
            && !ref($column)
            && defined $column
            && $column =~ /\A(?:me\.)?itemcallnumber\z/ )
        {
            push @order_by, $order;
            next;
        }

        if ($classification) {
            push @order_by, { $direction => \q{COALESCE(NULLIF(item.cn_sort, ''), me.itemcallnumber)} };
        }
        push @order_by, { $direction => 'me.itemcallnumber' };
        $callnumber_direction = $direction;
    }

    if ($callnumber_direction) {
        push @order_by, { $callnumber_direction => 'me.itemnumber' };
        $self       = $self->SUPER::search( undef, { join => 'item' } ) if $classification;
        $attributes = { %$attributes, order_by => \@order_by };
    }

    return $self->SUPER::search( $params, $attributes );
}

=head2 Internal methods

=head3 _type

=cut

sub _type {
    return 'TmpHoldsqueue';
}

=head3 object_class

=cut

sub object_class {
    return 'Koha::Hold::HoldsQueueItem';
}

=head1 AUTHORS

Kyle Hall <kyle@bywatersolutions.com>

=cut

1;
