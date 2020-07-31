#!/usr/bin/perl

# Copyright University of Helsinki 2020
#
# This file is part of Koha.
#
# Koha is free software; you can redistribute it and/or modify it under the
# terms of the GNU General Public License as published by the Free Software
# Foundation; either version 3 of the License, or (at your option) any later
# version.
#
# Koha is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with Koha; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Modern::Perl;
use C4::Context;

my $dbh = C4::Context->dbh;

sub deleteUnneededData {
  my @tables_to_truncate = (
			  "atomicupdates",
#			  "action_logs_cache", # needs to be preserved for statistics
			  "api_keys",
			 );
  my @tables_to_delete = (
			  "borrower_permissions",
			  "permission_modules",
			 );

  foreach my $table (@tables_to_truncate) {
    $dbh->do("DROP TABLE IF EXISTS " . $table);
  }

  foreach my $table (@tables_to_delete) {
    $dbh->do("DELETE IGNORE FROM " . $table);
  }

}

sub dropUnusedTables {
  # TODO: Verify tables are dropped
  my @tables_to_drop = (
			"vetuma_transaction_accountlines_link",
			"vetuma_transaction",
			"payments_transactions_accountlines",
			"payments_transactions",
			"collections_tracking",
			"batch_overlay_diff_header",
			"batch_overlay_diff",
			"batch_overlay_reports",
			"borrower_ss_blocks",
			"message_queue_items",
			"borrower_permissions",
			"user_permissions",
			"permissions",
			"userflags",
			"permission_modules",
			"overduebills",
			"overdue_calendar_weekdays",
			"overdue_calendar_exceptions",
			"floating_matrix",
			"atomicupdates",
			"collections",
#			"action_logs_cache", # This is needed for statistics, in the future action_logs can be used.
			"api_keys", # dropping this requires to regenerate api keys when migration is done, community has slightly different implementation of this
			"biblio_data_elements",
		       );

    foreach my $table (@tables_to_drop) {
	$dbh->do("DROP TABLE IF EXISTS " . $table);
    }

}

sub dropUnusedColumns {
    # TODO: Verify column is dropped
    $dbh->do("ALTER TABLE message_queue DROP COLUMN delivery_note");
}

# Re-creates tables Koha-Suomi fork dropped from KC schema
sub recreateDeletedTables {
    # collections_tracking
    $dbh->do("
CREATE TABLE collections_tracking (
  collections_tracking_id integer(11) NOT NULL auto_increment,
  colId integer(11) NOT NULL DEFAULT 0 comment 'collections.colId',
  itemnumber integer(11) NOT NULL DEFAULT 0 comment 'items.itemnumber',
  PRIMARY KEY (collections_tracking_id)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
	     ");

    # collections
    $dbh->do("
CREATE TABLE collections (
  colId integer(11) NOT NULL auto_increment,
  colTitle varchar(100) NOT NULL DEFAULT '',
  colDesc text NOT NULL,
  colBranchcode varchar(10) DEFAULT NULL, -- 'branchcode for branch where item should be held.'
  PRIMARY KEY (colId)
) ENGINE=InnoDB  DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
")

    # userflags
    $dbh->do("
CREATE TABLE `userflags` (
  `bit` int(11) NOT NULL default 0,
  `flag` varchar(30) default NULL,
  `flagdesc` varchar(255) default NULL,
  `defaulton` int(11) default NULL,
  PRIMARY KEY  (`bit`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
	     ");

    # permissions
    $dbh->do("
CREATE TABLE `permissions` (
  `module_bit` int(11) NOT NULL DEFAULT 0,
  `code` varchar(64) NOT NULL DEFAULT '',
  `description` varchar(255) DEFAULT NULL,
  PRIMARY KEY  (`module_bit`, `code`),
  CONSTRAINT `permissions_ibfk_1` FOREIGN KEY (`module_bit`) REFERENCES `userflags` (`bit`)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
	     ");


    # user_permissions
    $dbh->do("

CREATE TABLE `user_permissions` (
  `borrowernumber` int(11) NOT NULL DEFAULT 0,
  `module_bit` int(11) NOT NULL DEFAULT 0,
  `code` varchar(64) DEFAULT NULL,
  CONSTRAINT `user_permissions_ibfk_1` FOREIGN KEY (`borrowernumber`) REFERENCES `borrowers` (`borrowernumber`)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `user_permissions_ibfk_2` FOREIGN KEY (`module_bit`, `code`) REFERENCES `permissions` (`module_bit`, `code`)
     ON DELETE CASCADE ON UPDATE CASCADE
 ) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci;
	     ");




}

sub modifyColumns {
    $dbh->do("ALTER TABLE deletedborrowers ADD COLUMN flags int(11) default NULL");
    $dbh->do("ALTER TABLE borrowers ADD COLUMN flags int(11) default NULL");
    $dbh->do("ALTER TABLE borrower_modifications ADD COLUMN flags int(11) default NULL");
    $dbh->do("ALTER TABLE deletedborrowers MODIFY COLUMN othernames mediumtext");
    $dbh->do("ALTER TABLE borrowers DROP INDEX othernames_3");
    $dbh->do("ALTER TABLE borrowers MODIFY COLUMN othernames mediumtext");
    $dbh->do("ALTER TABLE borrowers ADD KEY `othernames_idx` (`othernames`(255))");

    $dbh->do("ALTER TABLE subscription DROP INDEX by_biblionumber");

#    $dbh->do("ALTER TABLE reserves DELETE KEY `old_reserves_pickupexpired`");
    $dbh->do("ALTER TABLE reserves DROP COLUMN pickupexpired");
#    $dbh->do("ALTER TABLE old_reserves DELETE KEY `old_reserves_pickupexpired`");
    $dbh->do("ALTER TABLE old_reserves DROP COLUMN pickupexpired");

    $dbh->do("ALTER TABLE overduerules DROP COLUMN fine1, DROP COLUMN fine2, DROP COLUMN fine3");


    $dbh->do("ALTER TABLE issuingrules DROP INDEX issuingrules_selects");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN issuingrules_id");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN ccode");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN permanent_location");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN sub_location");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN circulation_level");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN hold_max_pickup_delay");
    $dbh->do("ALTER TABLE issuingrules DROP COLUMN hold_expiration_charge");

}

deleteUnneededData();
dropUnusedTables();
dropUnusedColumns();
recreateDeletedTables();
modifyColumns();

# These steps are still to be manually completed:
#
# run koha-mysql <instance > < /usr/share/koha/intranet/cgi-bin/installer/data/mysql/userflags.sql
# run koha-mysql <instance> < /usr/share/koha/intranet/cgi-bin/installer/data/mysql/userpermissions.sql
# run koha-upgrade-schema
