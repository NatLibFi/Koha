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
use utf8;
use Test::More tests => 34;
use Test::NoWarnings;
use Test::MockObject;

use Koha::Database;
use Koha::ILL::Requests;
use Koha::Notice::Templates;
use t::lib::Mocks;
use t::lib::TestBuilder;

my $schema  = Koha::Database->new->schema;
my $builder = t::lib::TestBuilder->new;

$schema->storage->txn_begin;
t::lib::Mocks::mock_preference( 'TranslateNotices',    1 );
t::lib::Mocks::mock_preference( 'IndependentBranches', 0 );
my $library =
    $builder->build_object( { class => 'Koha::Libraries', value => { branchemail => 'ill@example.invalid' } } );
my $category  = $builder->build_object( { class => 'Koha::Patron::Categories' } );
my $requester = $builder->build_object( { class => 'Koha::Patrons', value => { lang => 'en' } } );
my $request   = $builder->build_object(
    {
        class => 'Koha::ILL::Requests',
        value => {
            branchcode => $library->branchcode, borrowernumber => $requester->id,
            backend    => undef, biblio_id => undef, status => 'NEW',
        },
    }
);
my $config = Test::MockObject->new;
$config->set_always( 'partner_code', $category->categorycode );
$request->_config($config);
my $backend = Test::MockObject->new;
$backend->mock( 'metadata', sub { return { title => 'Test request' }; } );
$backend->mock(
    'capabilities',
    sub {
        return sub { return 1; };
    }
);
$request->_backend($backend);

for my $lang (qw(default en fi-FI sv-SE)) {
    $builder->build_object(
        {
            class => 'Koha::Notice::Templates',
            value => {
                module => 'ill', code                   => 'ILL_PARTNER_REQ', branchcode => $library->branchcode,
                lang   => $lang, message_transport_type => 'email',           is_html    => 0,
                title  => "Subject $lang", content      => "Body $lang",
            },
        }
    );
}
my @partners;
for my $lang ( 'fi-FI', 'fi-FI', 'sv-SE', '', 'xx-XX' ) {
    push @partners, $builder->build_object(
        {
            class => 'Koha::Patrons',
            value => {
                categorycode => $category->categorycode, lang => $lang,
                email        => 'partner' . scalar(@partners) . '@example.invalid',
            },
        }
    );
}
my $draft  = $request->generic_confirm( { current_branchcode => $library->branchcode } );
my %drafts = map { $_->{lang} => $_ } @{ $draft->{value}->{drafts} };
is( scalar keys %drafts,                4,               'One draft per partner language, including default' );
is( $drafts{'fi-FI'}->{subject},        'Subject fi-FI', 'Finnish partner selects Finnish notice' );
is( $drafts{'sv-SE'}->{body},           'Body sv-SE',    'Swedish partner selects Swedish notice' );
is( $drafts{default}->{body},           'Body default',  'Missing partner language uses default' );
is( $drafts{'xx-XX'}->{body},           'Body default',  'Missing translation falls back to default' );
is( $draft->{value}->{partners}->count, 5,               'Draft generation preserves all selectable partners' );
is(
    $request->get_notice( { notice_code => 'ILL_PARTNER_REQ', transport => 'email' } )->{content},
    'Body en', 'Other get_notice callers retain requesting-patron language'
);

t::lib::Mocks::mock_preference( 'TranslateNotices', 0 );
my $untranslated = $request->generic_confirm( { current_branchcode => $library->branchcode } );
is_deeply(
    [ map { $_->{body} } @{ $untranslated->{value}->{drafts} } ],
    [ ('Body default') x 4 ], 'Disabled notice translations retain default templates'
);
t::lib::Mocks::mock_preference( 'TranslateNotices', 1 );

my %params = ( stage => 'draft', current_branchcode => $library->branchcode );
for my $lang ( keys %drafts ) {
    $params{"subject_$lang"} = "Edited subject $lang";
    $params{"body_$lang"}    = "Edited body $lang: Pyyntö";
}
$params{partners} = join "\x00", map { $_->id } @partners;
my $sent = $request->generic_confirm( \%params );
is( $sent->{error},                    0,        'Mixed-language partners queue successfully' );
is( $request->discard_changes->status, 'GENREQ', 'Successful queueing advances request status' );
for my $partner (@partners) {
    my $lang     = $partner->lang || 'default';
    my $messages = $schema->resultset('MessageQueue')->search( { borrowernumber => $partner->id } );
    is( $messages->count, 1, "Exactly one message for partner $lang" );
    my $message = $messages->next;
    is( $message->to_address, $partner->email,          'Message goes to the selected partner' );
    is( $message->subject,    $params{"subject_$lang"}, 'Edited subject is preserved' );
    like( $message->content, qr/\Q$params{"body_$lang"}\E/, 'Edited body is preserved' );
}

my $own_messages =
    $schema->resultset('MessageQueue')->search( { borrowernumber => { -in => [ map { $_->id } @partners ] } } );
$own_messages->delete;
$params{partners} = $partners[0]->id;
is( $request->generic_confirm( \%params )->{error},    0,                'One selected partner queues successfully' );
is( $own_messages->count,                              1,                'Unselected partners receive no messages' );
is( $own_messages->next->get_column('borrowernumber'), $partners[0]->id, 'Only the selected recipient is queued' );

$schema->storage->txn_rollback;
