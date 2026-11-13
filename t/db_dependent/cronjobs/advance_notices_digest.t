#!/usr/bin/perl
#
# This file is part of Koha.
#
# Copyright (C) 2018  Andreas Jonsson <andreas.jonsson@kreablo.se>
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

use Test::More tests => 3;
use t::lib::TestBuilder;
use t::lib::Mocks;
use File::Spec;
use File::Basename;

use Koha::DateUtils qw( dt_from_string );
use Koha::Items;

my $scriptDir = dirname( File::Spec->rel2abs(__FILE__) );

my $schema = Koha::Database->new->schema;
my $dbh    = C4::Context->dbh;

my $library1;
my $library2;
my $library3;
my $borrower;

sub build_test_objects {

    # Set only to avoid exception.
    t::lib::Mocks::mock_preference( 'dateformat', 'metric' );

    my $builder = t::lib::TestBuilder->new;

    $library1 = $builder->build(
        {
            source => 'Branch',
        }
    );
    $library2 = $builder->build(
        {
            source => 'Branch',
        }
    );
    $library3 = $builder->build(
        {
            source => 'Branch',
        }
    );
    $borrower = $builder->build(
        {
            source => 'Borrower',
            value  => {
                branchcode => $library1->{branchcode},
            }
        }
    );
    $dbh->do(<<DELETESQL);
DELETE FROM letter
 WHERE module='circulation'
   AND code = 'PREDUEDGST'
   AND message_transport_type='email'
   AND branchcode=''
DELETESQL

    $dbh->do(<<DELETESQL);
DELETE FROM message_attributes WHERE message_name = 'Advance_Notice'
DELETESQL

    my $message_attribute = $builder->build(
        {
            source => 'MessageAttribute',
            value  => { message_name => 'Advance_Notice' }
        }
    );

    my $letter = $builder->build(
        {
            source => 'Letter',
            value  => {
                module                 => 'circulation',
                code                   => 'PREDUEDGST',
                branchcode             => '',
                message_transport_type => 'email',
                lang                   => 'default',
                is_html                => 0,
                content                => '<<count>> <<branches.branchname>>'
            }
        }
    );
    my $borrower_message_preference = $builder->build(
        {
            source => 'BorrowerMessagePreference',
            value  => {
                borrowernumber       => $borrower->{borrowernumber},
                wants_digest         => 1,
                days_in_advance      => 1,
                message_attribute_id => $message_attribute->{message_attribute_id}
            }
        }
    );

    my $borrower_message_transport_preference = $builder->build(
        {
            source => 'BorrowerMessageTransportPreference',
            value  => {
                borrower_message_preference_id => $borrower_message_preference->{borrower_message_preference_id},
                message_transport_type         => 'email'
            }
        }
    );

    #Adding a second preference for a notice that isn't defined, should just be skipped
    my $borrower_message_transport_preference_1 = $builder->build(
        {
            source => 'BorrowerMessageTransportPreference',
            value  => {
                borrower_message_preference_id => $borrower_message_preference->{borrower_message_preference_id},
                message_transport_type         => 'phone'
            }
        }
    );

    my $item1    = $builder->build_sample_item;
    my $item2    = $builder->build_sample_item;
    my $item3    = $builder->build_sample_item;
    my $now      = dt_from_string();
    my $tomorrow = $now->add( days => 1 )->strftime('%F');

    my $issue1 = $builder->build(
        {
            source => 'Issue',
            value  => {
                date_due       => $tomorrow,
                itemnumber     => $item1->itemnumber,
                branchcode     => $library2->{branchcode},
                borrowernumber => $borrower->{borrowernumber},
                returndate     => undef
            }
        }
    );

    my $issue2 = $builder->build(
        {
            source => 'Issue',
            value  => {
                date_due       => $tomorrow,
                itemnumber     => $item2->itemnumber,
                branchcode     => $library3->{branchcode},
                borrowernumber => $borrower->{borrowernumber},
                returndate     => undef
            }
        }
    );
    my $issue3 = $builder->build(
        {
            source => 'Issue',
            value  => {
                date_due       => $tomorrow,
                itemnumber     => $item3->itemnumber,
                branchcode     => $library3->{branchcode},
                borrowernumber => $borrower->{borrowernumber},
                returndate     => undef
            }
        }
    );

    C4::Context->set_preference( 'EnhancedMessagingPreferences', 1 );
}

sub run_script {
    my $script = shift;
    local @ARGV = @_;

    # We simulate script execution by evaluating the script code in the context
    # of this unit test.

    eval $script;    ## no critic (StringyEval)

    die $@ if $@;
}

my $scriptContent = '';
my $scriptFile    = "$scriptDir/../../../misc/cronjobs/advance_notices.pl";
open my $scriptfh, "<", $scriptFile or die "Failed to open $scriptFile: $!";

while (<$scriptfh>) {
    $scriptContent .= $_;
}
close $scriptfh;

my $sthmq = $dbh->prepare('SELECT * FROM message_queue WHERE borrowernumber = ?');

subtest 'Default behaviour tests' => sub {

    plan tests => 3;

    $schema->storage->txn_begin;

    build_test_objects();

    run_script( $scriptContent, 'advanced_notices.pl', '-c' );

    $sthmq->execute( $borrower->{borrowernumber} );

    my $messages = $sthmq->fetchall_hashref('message_id');

    is( scalar( keys %$messages ), 1, 'There is one message in the queue' );

    for my $message ( keys %$messages ) {
        $messages->{$message}->{content} =~ /(\d+) (.*)/;
        my $count      = $1;
        my $branchname = $2;

        is( $count,      '3',                     'Issue count is 3' );
        is( $branchname, $library1->{branchname}, 'Branchname is that of borrowers home branch.' );
    }

    $schema->storage->txn_rollback;
};

subtest '--digest-per-branch tests' => sub {

    plan tests => 5;

    $schema->storage->txn_begin;

    build_test_objects();

    run_script( $scriptContent, 'advanced_notices.pl', '-c', '-digest-per-branch' );

    $sthmq->execute( $borrower->{borrowernumber} );

    my $messages = $sthmq->fetchall_hashref('message_id');

    is( scalar( keys %$messages ), 2, 'There are two messages in the queue' );

    my %expected = (
        $library2->{branchname} => {
            count => 1,
        },
        $library3->{branchname} => {
            count => 2,
        }
    );

    my %expected_branchnames = (
        $library2->{branchname} => 1,
        $library3->{branchname} => 1
    );

    my $i = 0;
    for my $message ( keys %$messages ) {
        $messages->{$message}->{content} =~ /(\d+) (.*)/;
        my $count      = $1;
        my $branchname = $2;

        ok( $expected_branchnames{$branchname}, 'Branchname is that of expected issuing branch.' );

        $expected_branchnames{$branchname} = 0;

        is( $count, $expected{$branchname}->{count}, 'Issue count is ' . $expected{$branchname}->{count} );

        $i++;
    }

    $schema->storage->txn_rollback;
};

subtest 'Item type exclusions by checkout library' => sub {
    $schema->storage->txn_begin;
    build_test_objects();
    $dbh->do(
        q{DELETE FROM borrower_message_transport_preferences
          WHERE message_transport_type = 'phone' AND borrower_message_preference_id IN
          (SELECT borrower_message_preference_id FROM borrower_message_preferences WHERE borrowernumber = ?)},
        undef, $borrower->{borrowernumber}
    );

    my $builder       = t::lib::TestBuilder->new;
    my $excluded_type = $builder->build( { source => 'Itemtype' } )->{itemtype};
    my $normal_type   = $builder->build( { source => 'Itemtype' } )->{itemtype};
    my @loans =
        $schema->resultset('Issue')
        ->search( { borrowernumber => $borrower->{borrowernumber} }, { order_by => 'issue_id' } )
        ->all;
    my @items = map { Koha::Items->find( $_->get_column('itemnumber') ) } @loans;
    my @types = ( $excluded_type, $excluded_type, $normal_type );

    for my $extra ( [ $library2, $normal_type ], [ $library1, $excluded_type ] ) {
        my $item = $builder->build_sample_item;
        push @items, $item;
        push @types, $extra->[1];
        $builder->build(
            {
                source => 'Issue',
                value  => {
                    itemnumber     => $item->itemnumber,
                    borrowernumber => $borrower->{borrowernumber},
                    branchcode     => $extra->[0]->{branchcode},
                    date_due       => dt_from_string()->add( days => 1 )->ymd,
                    returndate     => undef,
                }
            }
        );
    }
    for my $i ( 0 .. $#items ) {
        $items[$i]->set( { itype => $types[$i], homebranch => $library1->{branchcode} } )->store;
        $dbh->do(
            'UPDATE biblioitems SET itemtype = ? WHERE biblioitemnumber = ?',
            undef, $types[$i], $items[$i]->biblioitemnumber
        );
    }

    # Exercise bibliographic fallback as well as explicit item types.
    $dbh->do( 'UPDATE items SET itype = NULL WHERE itemnumber = ?', undef, $items[4]->itemnumber );

    my ($due_attribute) =
        $dbh->selectrow_array(q{SELECT message_attribute_id FROM message_attributes WHERE message_name = 'Item_Due'});
    $due_attribute //= $builder->build( { source => 'MessageAttribute', value => { message_name => 'Item_Due' } } )
        ->{message_attribute_id};
    my $due_preference = $builder->build(
        {
            source => 'BorrowerMessagePreference',
            value  => {
                borrowernumber       => $borrower->{borrowernumber},
                message_attribute_id => $due_attribute,
                wants_digest         => 0,
            }
        }
    );
    $builder->build(
        {
            source => 'BorrowerMessageTransportPreference',
            value  => {
                borrower_message_preference_id => $due_preference->{borrower_message_preference_id},
                message_transport_type         => 'email',
            }
        }
    );
    for my $library ( $library1, $library2, $library3 ) {
        for my $code (qw(DUE PREDUE DUEDGST PREDUEDGST)) {
            $builder->build(
                {
                    source => 'Letter',
                    value  => {
                        module                 => 'circulation', code => $code, branchcode  => $library->{branchcode},
                        message_transport_type => 'email',       lang => 'default', is_html => 0,
                        content                => $code =~ /DGST/
                        ? 'COUNT <<count>> ITEMS <<items.content>>'
                        : 'ITEM <<items.barcode>>',
                    }
                }
            );
        }
    }

    my @scope = map { ( '--itemtypesout-library', $_->{branchcode} ) } ( $library1, $library2 );
    my @cases = (
        [ 'global', [ '--itemtypesout', $excluded_type ], [ 2, 3 ] ],
        [ 'selected libraries', [ '--itemtypesout', $excluded_type, @scope ], [ 1, 2, 3 ] ],
        [
            'per-library digests', [ '--itemtypesout', $excluded_type, @scope, '--digest-per-branch' ], [ 1, 2, 3 ], 1,
            1
        ],
        [ 'bibliographic types', [ '--itemtypesout', $excluded_type, @scope ], [ 1, 2, 3 ], 0 ],
        [
            'owning-library sender', [ '--itemtypesout', $excluded_type, @scope, '--frombranch', 'item-homebranch' ],
            [ 1, 2, 3 ]
        ],
        [ 'no exclusions',        [],                                                                   [ 0 .. 4 ] ],
        [ 'library option alone', [@scope],                                                             [ 0 .. 4 ] ],
        [ 'all types excluded',   [ '--itemtypesout', $excluded_type, '--itemtypesout', $normal_type ], [] ],
    );
    for my $day ( 0, 1 ) {
        $dbh->do(
            'UPDATE issues SET date_due = ? WHERE borrowernumber = ?',
            undef, dt_from_string()->add( days => $day )->ymd, $borrower->{borrowernumber}
        );
        for my $digest ( 0, 1 ) {
            $dbh->do(
                'UPDATE borrower_message_preferences SET wants_digest = ? WHERE borrowernumber = ?',
                undef, $digest, $borrower->{borrowernumber}
            );
            for my $case (@cases) {
                subtest "$case->[0], day $day, digest $digest" => sub {
                    $dbh->do(
                        'DELETE FROM message_queue WHERE borrowernumber = ?', undef,
                        $borrower->{borrowernumber}
                    );
                    t::lib::Mocks::mock_preference( 'item-level_itypes', $case->[3] // 1 );
                    run_script( $scriptContent, '-c', '--itemscontent', 'barcode', @{ $case->[1] } );
                    my $messages = $dbh->selectall_arrayref(
                        'SELECT letter_code, content FROM message_queue WHERE borrowernumber = ?',
                        { Slice => {} }, $borrower->{borrowernumber}
                    );
                    my %included     = map { $_ => 1 } @{ $case->[2] };
                    my $count        = scalar @{ $case->[2] };
                    my $notice_count = $digest ? ( $count ? ( $case->[4] ? 2 : 1 ) : 0 ) : $count;
                    is( scalar @$messages, $notice_count, 'Expected number of notices' );
                    my $code = $day ? ( $digest ? 'PREDUEDGST' : 'PREDUE' ) : ( $digest ? 'DUEDGST' : 'DUE' );
                    is_deeply(
                        [ map { $_->{letter_code} } @$messages ], [ ($code) x $notice_count ],
                        'Expected notice code'
                    );
                    my $content = join "\n", map { $_->{content} } @$messages;
                    for my $i ( 0 .. $#items ) {
                        my $barcode = $items[$i]->barcode;
                        is( $content =~ /\Q$barcode\E/ ? 1 : 0, $included{$i} ? 1 : 0, "Item $i inclusion" );
                    }
                    if ( $digest && $count ) {
                        my @counts =
                            sort { $a <=> $b } map { my ($count) = $_->{content} =~ /COUNT (\d+)/; $count } @$messages;
                        is_deeply(
                            \@counts, $case->[4] ? [ 1, 2 ] : [$count],
                            'Digest counts exclude only matching loans'
                        );
                    }
                    done_testing;
                };
            }
        }
    }
    $schema->storage->txn_rollback;
    done_testing;
};
