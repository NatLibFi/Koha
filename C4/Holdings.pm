package C4::Holdings;

# Copyright 2000-2002 Katipo Communications
# Copyright 2010 BibLibre
# Copyright 2011 Equinox Software, Inc.
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
use Carp;

# TODO check which use's are really necessary

use Encode qw( decode is_utf8 );
use MARC::Record;
use MARC::File::USMARC;
use MARC::File::XML;
use POSIX qw(strftime);
use Module::Load::Conditional qw(can_load);

use C4::Koha;
use C4::Log;    # logaction
use C4::ClassSource;
use C4::Charset;
use C4::Debug;

use Koha::Caches;
use Koha::Holdings::Metadata;
use Koha::Holdings::Metadatas;
use Koha::Libraries;

use vars qw(@ISA @EXPORT);
use vars qw($debug $cgi_debug);

BEGIN {

    require Exporter;
    @ISA = qw( Exporter );

    # to add holdings
    # EXPORTED FUNCTIONS.
    push @EXPORT, qw(
      &AddHolding
    );

    # to get something
    push @EXPORT, qw(
      GetHolding
    );

    # To modify something
    push @EXPORT, qw(
      &ModHolding
    );

    # To delete something
    push @EXPORT, qw(
      &DelHolding
    );
}

=head1 NAME

C4::Holding - cataloging management functions

=head1 DESCRIPTION

Holding.pm contains functions for managing storage and editing of holdings data within Koha. Most of the functions in this module are used for cataloging holdings records: adding, editing, or removing holdings. Koha stores holdings information in two places:

=over 4

=item 1. in the holdings table which is limited to a one-to-one mapping to underlying MARC data

=item 2. as MARC XML in holdings_metadata.metadata

=back

In the 3.0 version of Koha, the authoritative record-level information is in holdings_metadata.metadata

Because the data isn't completely normalized there's a chance for information to get out of sync. The design choice to go with a un-normalized schema was driven by performance and stability concerns. However, if this occur, it can be considered as a bug : The API is (or should be) complete & the only entry point for all holdings management.

=over 4

=item 1. Add*/Mod*/Del*/ - high-level external functions suitable for being called from external scripts to manage the collection

=back

The MARC record (in holdings_metadata.metadata) contains the MARC holdings record. It also contains the holding_id. That is the reason why it is not stored directly by AddHolding, with all other fields. To save a holding, we need to:

=over 4

=item 1. save data in holdings table, that gives us a holding_id

=item 2. add the holding_id into the MARC record

=item 3. save the marc record

=back

=head1 EXPORTED FUNCTIONS

=head2 AddHolding

  $holding_id = AddHolding($record, $frameworkcode, $biblionumber);

Exported function (core API) for adding a new holding to koha.

The first argument is a C<MARC::Record> object containing the
holding to add, while the second argument is the desired MARC
framework code and third the biblionumber to link to.

=cut

sub AddHolding {
    my $record          = shift;
    my $frameworkcode   = shift;
    my $biblionumber    = shift;
    if (!$record) {
        carp('AddHolding called with undefined record');
        return;
    }

    my $dbh = C4::Context->dbh;

    # transform the data into koha-table style data
    SetUTF8Flag($record);
    my $rowData = C4::Biblio::TransformMarcToKoha( $record, $frameworkcode, 'holdings' );
    my ($holding_id) = _koha_add_holding( $dbh, $rowData, $frameworkcode, $biblionumber );

    # update biblionumber, biblioitemnumber and holding_id in MARC
    # FIXME - this is assuming a 1 to 1 relationship between
    # biblios and biblioitems
    my $sth = $dbh->prepare("select biblioitemnumber from biblioitems where biblionumber=?");
    $sth->execute($biblionumber);
    my ($biblioitemnumber) = $sth->fetchrow;
    $sth->finish();

    _koha_marc_update_ids( $record, $frameworkcode, $holding_id, $biblionumber, $biblioitemnumber );

    # now add the record
    ModHoldingMarc( $record, $holding_id, $frameworkcode );

    logaction( "CATALOGUING", "ADD", $holding_id, "holding" ) if C4::Context->preference("CataloguingLog");
    return $holding_id;
}

=head2 ModHolding

  ModHolding($record, $holding_id, $frameworkcode);

Replace an existing holding record identified by C<$holding_id>
with one supplied by the MARC::Record object C<$record>.

C<$frameworkcode> specifies the MARC framework to use
when storing the modified holdings record.

Returns 1 on success 0 on failure

=cut

sub ModHolding {
    my ( $record, $holding_id, $frameworkcode ) = @_;
    if (!$record) {
        carp 'No record passed to ModHolding';
        return 0;
    }

    if ( C4::Context->preference("CataloguingLog") ) {
        my $newrecord = GetMarcHolding($holding_id);
        logaction( "CATALOGUING", "MODIFY", $holding_id, "holding BEFORE=>" . $newrecord->as_formatted );
    }

    # Cleaning up invalid fields must be done early or SetUTF8Flag is liable to
    # throw an exception which probably won't be handled.
    foreach my $field ($record->fields()) {
        if (! $field->is_control_field()) {
            if (scalar($field->subfields()) == 0 || (scalar($field->subfields()) == 1 && $field->subfield('9'))) {
                $record->delete_field($field);
            }
        }
    }

    SetUTF8Flag($record);
    my $dbh = C4::Context->dbh;

    $frameworkcode = C4::Context->preference('DefaultSummaryHoldingsFrameworkCode') if !$frameworkcode || $frameworkcode eq "Default";

    # update holding_id in MARC
    _koha_marc_update_ids( $record, $frameworkcode, $holding_id );

    # load the koha-table data object
    my $rowData = C4::Biblio::TransformMarcToKoha( $record, $frameworkcode, 'holdings' );
    # update the MARC record (that now contains biblio and items) with the new record data
    &ModHoldingMarc( $record, $holding_id, $frameworkcode );

    # modify the other koha tables
    _koha_modify_holding( $dbh, $holding_id, $rowData, $frameworkcode );

    return 1;
}

=head2 DelHolding

  my $error = &DelHolding($holding_id);

Exported function (core API) for deleting a holding in koha.
Deletes holding record from Koha tables (holdings, holdings_metadata)
Also backs it up to deleted* tables.
Checks to make sure that the holding has no items attached.
return:
C<$error> : undef unless an error occurs

=cut

sub DelHolding {
    my ($holding_id) = @_;
    my $dbh = C4::Context->dbh;
    my $error;    # for error handling

    # First make sure this holding has no items attached
    my $sth = $dbh->prepare("SELECT itemnumber FROM items WHERE holding_id=?");
    $sth->execute($holding_id);
    if ( my $itemnumber = $sth->fetchrow ) {

        # Fix this to use a status the template can understand
        $error .= "This holding record has items attached, please delete them first before deleting this holding record ";
    }

    return $error if $error;

    # delete holding from Koha tables and save in deletedholdings
    $error = _koha_delete_holding( $dbh, $holding_id );

    logaction( "CATALOGUING", "DELETE", $holding_id, "holding" ) if C4::Context->preference("CataloguingLog");

    return;
}

=head2 GetHolding

  my $holding = &GetHolding($holding_id);

=cut

sub GetHolding {
    my ($holding_id) = @_;
    my $dbh            = C4::Context->dbh;
    my $sth            = $dbh->prepare("SELECT * FROM holding WHERE holding_id = ?");
    my $count          = 0;
    my @results;
    $sth->execute($holding_id);
    if ( my $data = $sth->fetchrow_hashref ) {
        return $data;
    }
    return;
}

=head2 GetHoldingsByBiblionumber

  GetHoldingsByBiblionumber($biblionumber);

Returns an arrayref of hashrefs suitable for use in a TMPL_LOOP
Called by C<C4::XISBN>

=cut

sub GetHoldingsByBiblionumber {
    my ( $bib ) = @_;
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT * FROM holdings WHERE holdings.biblionumber = ?") || die $dbh->errstr;
    # Get all holdings attached to a biblioitem
    my $i = 0;
    my @results;
    $sth->execute($bib) || die $sth->errstr;
    while ( my $data = $sth->fetchrow_hashref ) {
        push(@results, $data);
    }
    return (\@results);
}

=head2 GetMarcHolding

  my $record = GetMarcHolding(holding_id, [$opac]);

Returns MARC::Record representing a holding record, or C<undef> if the
record doesn't exist.

=over 4

=item C<$holding_id>

the holding_id

=item C<$opac>

set to true to make the result suited for OPAC view. This causes things like
OpacHiddenItems to be applied.

=back

=cut

sub GetMarcHolding {
    my $holding_id = shift;
    my $opac         = shift || 0;

    if (not defined $holding_id) {
        carp 'GetMarcHolding called with undefined holding_id';
        return;
    }

    # Use state to speed up repeated calls in batch processes
    state $marcflavour = C4::Context->preference('marcflavour');

    my $marcxml = GetXmlHolding( $holding_id );
    $marcxml = StripNonXmlChars( $marcxml );
    my $frameworkcode = GetHoldingFrameworkCode( $holding_id );
    MARC::File::XML->default_record_format( $marcflavour );
    my $record = MARC::Record->new();

    if ($marcxml) {
        $record = eval {
            MARC::Record::new_from_xml( $marcxml, "utf8", $marcflavour );
        };
        if ($@) { warn " problem with holding $holding_id : $@ \n$marcxml"; }
        return unless $record;

        _koha_marc_update_ids( $record, $frameworkcode, $holding_id );

        return $record;
    }
    return;
}

=head2 GetXmlHolding

  my $marcxml = GetXmlHolding($holding_id);

Returns holdings_metadata.metadata/marcxml of the holding_id passed in parameter.

=cut

sub GetXmlHolding {
    my ($holding_id) = @_;
    return unless $holding_id;

    # Use state to speed up repeated calls in batch processes
    state $marcflavour = C4::Context->preference('marcflavour');
    state $sth = C4::Context->dbh->prepare(
        q|
        SELECT metadata
        FROM holdings_metadata
        WHERE holding_id=?
            AND format='marcxml'
            AND marcflavour=?
        |
    );

    $sth->execute( $holding_id, $marcflavour );
    my ($marcxml) = $sth->fetchrow();
    $sth->finish();
    return $marcxml;
}

=head2 GetHoldingFrameworkCode

  $frameworkcode = GetFrameworkCode( $holding_id )

=cut

sub GetHoldingFrameworkCode {
    my ($holding_id) = @_;
    # Use state to speed up repeated calls in batch processes
    state $sth         = C4::Context->dbh->prepare("SELECT frameworkcode FROM holdings WHERE holding_id=?");
    $sth->execute($holding_id);
    my ($frameworkcode) = $sth->fetchrow;
    $sth->finish();
    return $frameworkcode;
}

=head1 INTERNAL FUNCTIONS

=head2 _koha_add_holding

  my ($holding_id,$error) = _koha_add_hodings($dbh, $holding, $frameworkcode, $biblionumber);

Internal function to add a holding ($holding is a hash with the values)

=cut

sub _koha_add_holding {
    my ( $dbh, $holding, $frameworkcode, $biblionumber ) = @_;

    my $error;

    my $biblioitem = ( C4::Biblio::GetBiblioItemByBiblioNumber( $biblionumber, undef ) )[0];

    my $query = "INSERT INTO holdings
        SET biblionumber = ?,
            biblioitemnumber = ?,
            frameworkcode = ?,
            holdingbranch = ?,
            location = ?,
            callnumber = ?,
            suppress = ?,
            datecreated=NOW()
        ";

    my $sth = $dbh->prepare($query);
    $sth->execute(
        $biblionumber, $biblioitem->{'biblioitemnumber'}, $frameworkcode,
        $holding->{holdingbranch}, $holding->{location}, $holding->{callnumber}, $holding->{suppress}
    );

    my $holding_id = $dbh->{'mysql_insertid'};
    if ( $dbh->errstr ) {
        $error .= "ERROR in _koha_add_holding $query" . $dbh->errstr;
        warn $error;
    }

    $sth->finish();

    return ( $holding_id, $error );
}

=head2 _koha_modify_holding

  my ($biblionumber,$error) == _koha_modify_holding($dbh, $holding, $frameworkcode);

Internal function for updating the holdings table

=cut

sub _koha_modify_holding {
    my ( $dbh, $holding_id, $holding, $frameworkcode ) = @_;
    my $error;

    my $query = "
        UPDATE holdings
        SET    frameworkcode = ?,
               holdingbranch = ?,
               location = ?,
               callnumber = ?,
               suppress = ?
        WHERE  holding_id = ?
        "
      ;
    my $sth = $dbh->prepare($query);

    $sth->execute(
        $frameworkcode, $holding->{holdingbranch}, $holding->{location}, $holding->{callnumber}, $holding->{suppress}, $holding_id
    ) if $holding_id;

    if ( $dbh->errstr || !$holding_id ) {
        die "ERROR in _koha_modify_holding for holding $holding_id: " . $dbh->errstr;
    }
    return ( $holding_id, $error );
}

=head2 _koha_delete_holding

  $error = _koha_delete_holding($dbh, $holding_id);

Internal sub for deleting from holdings table -- also saves to deletedholdings

C<$dbh> - the database handle

C<$holding_id> - the holding_id of the holding to be deleted

=cut

# FIXME: add error handling

sub _koha_delete_holding {
    my ( $dbh, $holding_id ) = @_;

    # get all the data for this holding
    my $sth = $dbh->prepare("SELECT * FROM holdings WHERE holding_id=?");
    $sth->execute($holding_id);

    # FIXME There is a transaction in _koha_delete_holding_metadata
    # But actually all the following should be done inside a single transaction
    if ( my $data = $sth->fetchrow_hashref ) {

        # save the record in deletedholdings
        # find the fields to save
        my $query = "INSERT INTO deletedholdings SET ";
        my @bind  = ();
        foreach my $temp ( keys %$data ) {
            $query .= "$temp = ?,";
            push( @bind, $data->{$temp} );
        }

        # replace the last , by ",?)"
        $query =~ s/\,$//;
        my $bkup_sth = $dbh->prepare($query);
        $bkup_sth->execute(@bind);
        $bkup_sth->finish;

        _koha_delete_holding_metadata( $holding_id );

        # delete the holding
        my $sth2 = $dbh->prepare("DELETE FROM holdings WHERE holding_id=?");
        $sth2->execute($holding_id);
        # update the timestamp (Bugzilla 7146)
        $sth2= $dbh->prepare("UPDATE deletedholdings SET timestamp=NOW() WHERE holding_id=?");
        $sth2->execute($holding_id);
        $sth2->finish;
    }
    $sth->finish;
    return;
}

=head2 _koha_delete_holding_metadata

  $error = _koha_delete_holding_metadata($holding_id);

C<$holding_id> - the holding_id of the holding metadata to be deleted

=cut

sub _koha_delete_holding_metadata {
    my ($holding_id) = @_;

    my $dbh    = C4::Context->dbh;
    my $schema = Koha::Database->new->schema;
    $schema->txn_do(
        sub {
            $dbh->do( q|
                INSERT INTO deletedholdings_metadata (holding_id, format, marcflavour, metadata)
                SELECT holding_id, format, marcflavour, metadata FROM holdings_metadata WHERE holding_id=?
            |,  undef, $holding_id );
            $dbh->do( q|DELETE FROM holdings_metadata WHERE holding_id=?|,
                undef, $holding_id );
        }
    );
}

=head1 INTERNAL FUNCTIONS

=head2 _koha_marc_update_ids


  _koha_marc_update_ids($record, $frameworkcode, $holding_id[, $biblionumber, $biblioitemnumber]);

Internal function to add or update holding_id, biblionumber and biblioitemnumber to
the MARC XML.

=cut

sub _koha_marc_update_ids {
    my ( $record, $frameworkcode, $holding_id, $biblionumber, $biblioitemnumber ) = @_;

    my ( $holding_tag, $holding_subfield ) = C4::Biblio::GetMarcFromKohaField( "holdings.holding_id", $frameworkcode );
    die qq{No holding_id tag for framework "$frameworkcode"} unless $holding_tag;

    if ( $holding_tag < 10 ) {
        C4::Biblio::UpsertMarcControlField( $record, $holding_tag, $holding_id );
    } else {
        C4::Biblio::UpsertMarcSubfield($record, $holding_tag, $holding_subfield, $holding_id);
    }

    if ( defined $biblionumber ) {
        my ( $biblio_tag, $biblio_subfield ) = C4::Biblio::GetMarcFromKohaField( "biblio.biblionumber", $frameworkcode );
        die qq{No biblionumber tag for framework "$frameworkcode"} unless $biblio_tag;
        if ( $biblio_tag < 10 ) {
            C4::Biblio::UpsertMarcControlField( $record, $biblio_tag, $biblionumber );
        } else {
            C4::Biblio::UpsertMarcSubfield($record, $biblio_tag, $biblio_subfield, $biblionumber);
        }
    }
    if ( defined $biblioitemnumber ) {
        my ( $biblioitem_tag, $biblioitem_subfield ) = C4::Biblio::GetMarcFromKohaField( "biblioitems.biblioitemnumber", $frameworkcode );
        die qq{No biblioitemnumber tag for framework "$frameworkcode"} unless $biblioitem_tag;
        if ( $biblioitem_tag < 10 ) {
            C4::Biblio::UpsertMarcControlField( $record, $biblioitem_tag, $biblioitemnumber );
        } else {
            C4::Biblio::UpsertMarcSubfield($record, $biblioitem_tag, $biblioitem_subfield, $biblioitemnumber);
        }
    }
}

=head1 UNEXPORTED FUNCTIONS

=head2 ModHoldingMarc

  &ModHoldingMarc($newrec,$holding_id,$frameworkcode);

Add MARC XML data for a holding to koha

Function exported, but should NOT be used, unless you really know what you're doing

=cut

sub ModHoldingMarc {
    # pass the MARC::Record to this function, and it will create the records in
    # the marcxml field
    my ( $record, $holding_id, $frameworkcode ) = @_;
    if ( !$record ) {
        carp 'ModHoldingMarc passed an undefined record';
        return;
    }

    # Clone record as it gets modified
    $record = $record->clone();
    my $dbh    = C4::Context->dbh;
    my @fields = $record->fields();
    if ( !$frameworkcode ) {
        $frameworkcode = "";
    }
    my $sth = $dbh->prepare("UPDATE holdings SET frameworkcode=? WHERE holding_id=?");
    $sth->execute( $frameworkcode, $holding_id );
    $sth->finish;
    my $encoding = C4::Context->preference("marcflavour");

    # deal with UNIMARC field 100 (encoding) : create it if needed & set encoding to unicode
    if ( $encoding eq "UNIMARC" ) {
        my $defaultlanguage = C4::Context->preference("UNIMARCField100Language");
        $defaultlanguage = "fre" if (!$defaultlanguage || length($defaultlanguage) != 3);
        my $string = $record->subfield( 100, "a" );
        if ( ($string) && ( length( $record->subfield( 100, "a" ) ) == 36 ) ) {
            my $f100 = $record->field(100);
            $record->delete_field($f100);
        } else {
            $string = POSIX::strftime( "%Y%m%d", localtime );
            $string =~ s/\-//g;
            $string = sprintf( "%-*s", 35, $string );
            substr ( $string, 22, 3, $defaultlanguage);
        }
        substr( $string, 25, 3, "y50" );
        unless ( $record->subfield( 100, "a" ) ) {
            $record->insert_fields_ordered( MARC::Field->new( 100, "", "", "a" => $string ) );
        }
    }

    #enhancement 5374: update transaction date (005) for marc21/unimarc
    if($encoding =~ /MARC21|UNIMARC/) {
      my @a= (localtime) [5,4,3,2,1,0]; $a[0]+=1900; $a[1]++;
        # YY MM DD HH MM SS (update year and month)
      my $f005= $record->field('005');
      $f005->update(sprintf("%4d%02d%02d%02d%02d%04.1f",@a)) if $f005;
    }

    my $metadata = {
        holding_id => $holding_id,
        format        => 'marcxml',
        marcflavour   => C4::Context->preference('marcflavour'),
    };
    # FIXME To replace with ->find_or_create?
    if ( my $m_rs = Koha::Holdings::Metadatas->find($metadata) ) {
        $m_rs->metadata( $record->as_xml_record($encoding) );
        $m_rs->store;
    } else {
        my $m_rs = Koha::Holdings::Metadata->new($metadata);
        $m_rs->metadata( $record->as_xml_record($encoding) );
        $m_rs->store;
    }
    return $holding_id;
}

1;


__END__

=head1 AUTHOR

Koha Development Team <http://koha-community.org/>

Paul POULAIN paul.poulain@free.fr

Joshua Ferraro jmf@liblime.com

Ere Maijala ere.maijala@helsinki.fi

=cut
