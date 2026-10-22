package Koha::Template::Plugin::PatronDisclosure;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use base qw( Template::Plugin );

use Carp qw( croak );
use Koha::Patron::Disclosure;
use Koha::Patron::Disclosure::Definitions;

sub enabled {
    return Koha::Patron::Disclosure->enabled;
}

sub page_size_limit {
    my ( $self, $operation ) = @_;
    return unless Koha::Patron::Disclosure->enabled;

    my $policy = Koha::Patron::Disclosure::Definitions->rest_operation($operation);
    croak "Unknown patron disclosure operation '$operation'" unless $policy;
    return unless $policy->{max_page_size};

    my $available = Koha::Patron::Disclosure->max_subjects - ( $policy->{fixed_subjects} // 0 );
    return 0 unless $available > 0;
    my $audit_max = int( $available / $policy->{subjects_per_page_item} );
    return $audit_max < $policy->{max_page_size} ? $audit_max : $policy->{max_page_size};
}

1;
