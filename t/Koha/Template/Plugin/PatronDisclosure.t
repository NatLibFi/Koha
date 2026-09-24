#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use Test::Exception;
use Test::MockModule;
use Test::More;

use C4::Context;
use Koha::Template::Plugin::PatronDisclosure;

my $enabled = 1;
my $limit   = 15;
my $context = Test::MockModule->new('C4::Context');
$context->redefine(
    config => sub {
        my ( $class, $name ) = @_;
        return $enabled if $name eq 'patron_data_disclosure_log';
        return $limit if $name eq 'patron_data_disclosure_max_subjects';
        return;
    }
);

my $plugin = 'Koha::Template::Plugin::PatronDisclosure';
is( $plugin->enabled, 1, 'plugin reports config-enabled audit' );
is( $plugin->page_size_limit('GET /patrons'), 15, 'staff search uses the server policy ceiling' );
is( $plugin->page_size_limit('GET /bookings'), 7, 'global bookings use two subjects per row' );
is( $plugin->page_size_limit('GET /biblios/{biblio_id}/bookings'), 15,
    'record bookings use one subject per row' );
is( $plugin->page_size_limit('GET /biblios/{biblio_id}/items'), 3,
    'item status uses the four-subject fanout ceiling' );
$limit = 2;
is( $plugin->page_size_limit('GET /biblios/{biblio_id}/items'), 0,
    'an impossible item page is identified before it can disclose data' );
$limit = 5000;
is( $plugin->page_size_limit('GET /patrons'), 1000, 'the operation ceiling also applies' );
$enabled = 0;
is( $plugin->enabled, 0, 'plugin reports config-disabled audit' );
is( $plugin->page_size_limit('GET /patrons'), undef, 'off leaves the ordinary table length' );
$enabled = 1;
throws_ok { $plugin->page_size_limit('GET /unknown') } qr/Unknown patron disclosure operation/,
    'a missing operation cannot silently use a guessed limit';

done_testing;
