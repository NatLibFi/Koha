#!/usr/bin/perl

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

use Test::More tests => 2;
use Test::NoWarnings;

use Koha::Template::Plugin::GD::Barcode;

my $plugin = Koha::Template::Plugin::GD::Barcode->new;

subtest 'create_as_data_url' => sub {
    plan tests => 4;

    my $constructor_calls = 0;
    no warnings 'redefine';
    local *GD::Barcode::new = sub {
        $constructor_calls++;
        return bless {}, 'Test::BarcodeImage';
    };

    my $data_url = $plugin->create_as_data_url( 'Code39', '12345' );
    like( $data_url, qr{\Adata:image/png;base64,}, 'A PNG data URL is returned' );
    unlike( $data_url, qr{\s}, 'The data URL does not contain base64 line breaks' );
    is( $constructor_calls, 1, 'An allowed type reaches GD::Barcode' );

    my $error = eval { $plugin->create_as_data_url( q{Code39; die 'executed'}, '12345' ); 1 };
    ok(
        !$error && $@ eq "Unsupported barcode type\n" && $constructor_calls == 1,
        'An untrusted module name is rejected before GD::Barcode eval'
    );
};

package Test::BarcodeImage;

sub plot {
    return shift;
}

sub png {
    return 'png-data' x 20;
}
