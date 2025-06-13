package Koha::Filter::MARC::EmbedHoldingsRecords;

# Copyright 2025  National Library of Finland

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

=head1 NAME

Koha::Filter::MARC::EmbedHoldingsRecords - Inserts tags information of MARC::Record objects with MARC Holdings Record info.

=head1 SYNOPSIS

my $record_processor = Koha::RecordProcessor->new(
    {
        filters => ['EmbedHoldingsRecords'],
        options => {
            biblionumber     => $self->biblionumber,
        }
    }
);

$record_processor->process($record);

=head1 DESCRIPTION

Inserts tags information of MARC::Record objects with MARC Holdings Record info.

=cut

use Modern::Perl;
use C4::Biblio;
use Koha::Holdings;

use base qw(Koha::RecordProcessor::Base);
our $NAME = 'EmbedHoldingsRecords';

=head2 filter

Inserts MARC Holdings Record tags over MARC::Record MARC::Record object.

=cut

sub filter {
    my $self    = shift;
    my $record = shift;

    return unless defined $record and ref($record) eq 'MARC::Record';

    my $params                  = $self->params;
    my $biblionumber            = $params->{options}->{biblionumber};
    my $holdings_records_fields = Koha::Holdings->get_embeddable_marc_fields({ biblionumber => $biblionumber });

    return $record
        if ! defined $holdings_records_fields || ! @$holdings_records_fields;

    $record->insert_fields_ordered(@$holdings_records_fields);

    return $record;
}

1;
