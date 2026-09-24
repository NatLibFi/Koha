#!/usr/bin/env perl

# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.

use Modern::Perl;

use FindBin;
use Test::More;
use Test::NoWarnings qw( had_no_warnings );

use Koha::Database;

my $atomicupdate_path =
    "$FindBin::Bin/../../../installer/data/mysql/atomicupdate/bug_25673.pl";
my $atomicupdate = do $atomicupdate_path;

ok( $atomicupdate, 'the patron disclosure atomic update loads' )
    or diag( $@ || $! );

my $schema = Koha::Database->new->schema;
my $dbh    = $schema->storage->dbh;

sub preference_value {
    my ($variable) = @_;
    return $dbh->selectrow_array(
        q{SELECT value FROM systempreferences WHERE variable = ?},
        undef,
        $variable
    );
}

sub run_update {
    my $output = q{};
    open my $out, '>', \$output or die "Cannot open scalar output: $!";
    $atomicupdate->{up}->( { dbh => $dbh, out => $out } );
    close $out;
    return $output;
}

$schema->storage->txn_begin;

$dbh->do(
    q{
        DELETE FROM systempreferences
        WHERE variable IN (
            'StaffPatronDataDisclosureLog',
            'StaffPatronDataDisclosureMaxSubjects'
        )
    }
);

like(
    run_update(),
    qr/Added or repaired patron data disclosure logging preferences/,
    'the migration reports its action'
);
is( preference_value('StaffPatronDataDisclosureLog'),         '0',    'missing logging preference defaults off' );
is( preference_value('StaffPatronDataDisclosureMaxSubjects'), '1000', 'missing subject limit receives its default' );

$dbh->do(
    q{
        UPDATE systempreferences
        SET value = CASE variable
            WHEN 'StaffPatronDataDisclosureLog' THEN '1'
            WHEN 'StaffPatronDataDisclosureMaxSubjects' THEN '250'
        END
        WHERE variable IN (
            'StaffPatronDataDisclosureLog',
            'StaffPatronDataDisclosureMaxSubjects'
        )
    }
);

run_update();
is( preference_value('StaffPatronDataDisclosureLog'),         '1',   'a valid enabled setting is preserved' );
is( preference_value('StaffPatronDataDisclosureMaxSubjects'), '250', 'a valid custom subject limit is preserved' );

$dbh->do(
    q{
        UPDATE systempreferences
        SET value = CASE variable
            WHEN 'StaffPatronDataDisclosureLog' THEN 'sometimes'
            WHEN 'StaffPatronDataDisclosureMaxSubjects' THEN ''
        END
        WHERE variable IN (
            'StaffPatronDataDisclosureLog',
            'StaffPatronDataDisclosureMaxSubjects'
        )
    }
);

run_update();
is( preference_value('StaffPatronDataDisclosureLog'),         '0',    'an invalid logging setting is repaired safely off' );
is( preference_value('StaffPatronDataDisclosureMaxSubjects'), '1000', 'an invalid subject limit is repaired' );

$schema->storage->txn_rollback;

had_no_warnings;
done_testing;
