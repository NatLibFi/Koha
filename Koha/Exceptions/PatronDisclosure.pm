package Koha::Exceptions::PatronDisclosure;

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Koha::Exception;
use Exception::Class (
    'Koha::Exceptions::PatronDisclosure' => {
        isa         => 'Koha::Exception',
        description => 'Patron disclosure audit failed',
        fields      => ['reason'],
    },
);

1;
