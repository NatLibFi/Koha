package C4::Breeding;

# Copyright 2000-2002 Katipo Communications
# Parts Copyright 2013 Prosentient Systems
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

use strict;
use warnings;

use C4::Biblio  qw(TransformMarcToKoha);
use C4::Koha    qw( GetVariationsOfISBN );
use C4::Charset qw( MarcToUTF8Record SetUTF8Flag );
use MARC::File::USMARC;
use MARC::Field;
use C4::ImportBatch     qw( GetZ3950BatchId AddBiblioToBatch AddAuthToBatch );
use C4::AuthoritiesMarc qw( GuessAuthTypeCode GetAuthorizedHeading );
use C4::Languages;
use Koha::Database;
use Koha::XSLT::Base;

my %ERROR_CODE_MEANING = (
    # 2.1. General Messages
    1 => 'System unavailable - Permanent system error (ref. 1)',
    2 => 'System temporarily unavailable (ref. 2.)',
    100 => 'Unspecified error (ref. 100)',
    1001 => 'Do not display - origin should correct error or display "Protocol error (ref. 1001)"',
    1025 => 'Selected database {database} does not support {service} (ref. 1025)',
    1030 => 'Unknown message (ref. 1030)',
    1031 => 'Unknown message (ref. 1031)',
    1032 => 'Unknown message (ref. 1032)',
    1033 => 'Unknown message (ref. 1033)',
    1034 => 'Unknown message (ref. 1034)',
    1035 => 'Unknown message (ref. 1035)',
    1036 => 'Unknown message (ref. 1036)',
    1037 => 'Unknown message (ref. 1037)',
    1038 => 'Unknown message (ref. 1038)',
    1039 => 'Unknown message (ref. 1039)',

    # 2.2. Init
    1010 => 'Unknown user identification (ref. 1010)',
    1011 => 'Unknown user identification or invalid password (ref. 1011)',
    1012 => 'No searches remaining (pre-purchased searches exhausted) (ref. 1012)',
    1013 => 'User identifier not valid for this operation ref. 1013)',
    1014 => 'Unknown user identification or invalid password (ref. 1014)',
    1015 => 'System temporarily unavailable (ref. 1015)',
    1016 => 'System temporarily unavailable (ref. 1016)',
    1017 => 'User identifier not valid for any available databases (ref. 1017)',
    1018 => 'System temporarily unavailable (ref. 1018)',
    1019 => 'System temporarily unavailable (ref. 1019)',
    1020 => 'System temporarily available (ref. 1020)',
    1021 => 'Access denied - Account has expired (ref. 1021)',
    1022 => 'Password expired - please supply new password (ref. 1022)',
    1023 => 'Password changed - please supply new password (ref. 1023)',
    1054 => 'Access denied - transaction incomplete (ref. 1054)',
    1055 => 'Access denied - transaction incomplete (ref. 1055)',
    # For diagnostics 1054 and 1055, it is recommended that the origin should take remedial action instead of displaying this message.

    # 2.3. Search - General problems with the search statement
    3 => 'Unsupported search for this database (ref. 3)',
    11 => 'Search cannot be performed - Too long (too many characters in the search) (ref. 11)',
    101 => 'Security failure (ref. 101)',
    102 => 'Target protocol error (ref. 102) - (all targets should support search once init successful.)',
    107 => 'Origin should send a type 1 query. If the message is still received, origin should display "Target protocol error (ref. 107)".',
    108 => 'Cannot perform search - malformed query (ref. 108)',

    # 2.4. Search - Messages relating to Database Selection
    3 => 'Unsupported search for this database (ref. 3)',
    23 => 'Specific combination of databases not supported (ref. 23)',
    29 => '{Database name} currently unavailable (ref. 29)',
    109 => '{Database name} currently unavailable (ref. 109)',
    111 => 'Cannot perform search - too many databases (ref. 111)',
    235 => 'Database does not exist (ref. 235)',
    236 => 'Access to {database name} denied (ref. 236)',
    1025 => 'Target Protocol error (ref. 1025)',

    # 2.5. Search - Messages relating to Search Attributes
    113 => 'Cannot perform search as requested (ref. 113)',
    114 => 'Cannot perform search - {use attribute} not supported (ref. 114)',
    115 => 'Cannot perform search - structure of term not supported (ref. 115)',
    116 => 'Do not display - origin should correct error',
    117 => 'Cannot perform search - {relation attribute} not supported (ref. 117)',
    118 => 'Cannot perform search - {structure attribute} not supported (ref. 118)',
    119 => 'Cannot perform search - {position attribute} not supported (ref. 119)',
    120 => 'Cannot truncate search as requested (ref. 120)',
    121 => 'Cannot search by {attribute set / attribute} (ref. 121)',
    122 => 'Cannot perform search - {completeness attribute} not supported (ref. 122)',
    123 => 'Cannot search {attribute} with {attribute} as requested (ref. 123)',
    126 => 'Cannot perform search - incorrect construction (ref. 126)',
    245 => 'Cannot perform search as requested (ref. 245)',
    246 => 'Cannot perform search as requested (ref. 246)',
    247 => 'Cannot perform search as requested (ref. 247)',
    1024 => 'Cannot perform search as requested (ref. 1024)',
    1056 => 'Cannot perform search as requested (ref. 1056)',

    # 2.6. Search - Messages relating to Search Term or Terms
    4 => 'Search cannot be performed - only contains common words that are not indexed (ref. 4)',
    5 => 'Search cannot be performed - Too many words or phrases in the search (ref. 5)',
    6 => 'Search cannot be performed - Too many words or phrases in the search (ref. 6)',
    7 => 'Search cannot be performed - Too many truncated words or phrases in the search (ref. 7)',
    8 => 'Search cannot be performed (ref. 8)',
    9 => 'Search cannot be performed - Truncated words are too short (ref. 9)',
    10 => 'Search cannot be performed - Invalid format of record number (ref. 10)',
    110 => 'Cannot perform search - {operator} not supported (ref. 110)',
    124 => 'Cannot search by {term} (ref. 124)',
    125 => 'Cannot search by {term} (ref. 125)',
    127 => '{Unnormalised value} cannot be processed (ref. 127)',
    1027 => 'Cannot perform search - incorrect construction (ref. 1027) - to be displayed if SQL created by user, else, display "SQL error (ref. 1027)"',

    # 2.7. Search - Messages relating to Element Set Names and Element Specification
    24 => 'Origin should send a present request with an element set name of F or B and give message "Unable to specify record content as requested". If the message is still received, origin should display "Target protocol error (ref. 24)".',
    25 => 'Origin should send a present request with an element set name of F or B and give message "Unable to specify record content as requested". If the message is still received, origin should display "Target protocol error (ref. 25)".',
    26 => 'Origin should send a present request with an element set name of F or B and give message "Unable to specify record content as requested".',

    # 2.8. Search - Messages relating to Results Set Names
    18 => 'Cannot search by {result set name} (ref. 18)',
    19 => 'Cannot search by more than one named results set (ref. 19)',
    20 => 'Cannot perform search - {operator} not valid with a results set. Valid search = {Results set name} AND {term} - Perform search? (ref. 20)',
    21 => 'Cannot create a results set with this name because it already exists - Delete existing results set? (ref. 21)',
    22 => 'Naming of search results not supported (ref. 22)',
    112 => 'Too many results sets already exist, select one or more from the following list to delete (ref. 112)',
    128 => '{Results set name} is an illegal name (ref. 128)',

    # 2.9. Search - Messages relating to Piggyback Present
    # Messages relating to Individual Records
    14 => 'System error - cannot retrieve record or records (ref. 14)',
    15 => 'Cannot retrieve requested record - security failure (ref. 15)',
    16 => 'Oversized record, cannot be retrieved (ref. 16)',
    17 => 'Oversized record, cannot be retrieved (ref. 17)',
    103 => 'Record could not be retrieved - security failure (ref. 103)',
    104 => 'Record could not be retrieved - security failure (ref. 104)',
    1026 => 'Cannot retrieve record, currently locked (ref. 1026)',
    1028 => 'Cannot retrieve record - record deleted (ref. 1028)',
    # Messages relating to Record Syntax
    106 => 'Cannot retrieve record, record syntax not displayable (ref. 106)',
    227 => 'Cannot retrieve record, record syntax not displayable (ref. 227)',
    238 => 'Cannot retrieve record, record syntax not displayable (ref. 238)',
    239 => 'Cannot retrieve record, record syntax not displayable (ref. 239)',
    # Messages relating to Piggyback Present
    1005 => 'Do not display - perform a present request',
    1006 => 'Do not display - perform a present request',

    # 2.10 Search - Messages relating to Proximity
    129 => 'Cannot do a proximity search of a results set (ref. 129)',
    130 => 'Do not display - origin should correct error',
    131 => 'Cannot do a proximity search using {relation type} (ref. 131)',
    132 => 'Cannot do a proximity search based on {known proximity unit} (ref. 132)',
    201 => 'Cannot do a proximity search with {attribute} combined with {attribute} (ref. 201)',
    202 => 'Cannot do a proximity search with a distance of {distance} and {known proximity unit} (ref. 202)',
    203 => 'Do not display - origin should retry without the ordered flag.',
    # Note that if the origin did not prompt for the proximity parameters then it should not present these messages to the user. In preference, the origin should attempt to construct a proximity search that will be accepted by the target or should revert to a boolean AND combination in the search.

    # 2.11. Search - Messages relating to Search Results
    12 => 'Too many records retrieved (ref. 12)',
    31 => 'Search has not completed - No results available (ref. 31)',
    32 => 'Search has not completed - Partial results available, quality unknown (ref. 32)',
    33 => 'Search has not completed - Partial results available (ref. 33)',

    # 2.12. Present - General messages
    13 => 'No more records to display ( ref. 13)',
    101 => 'Security failure (ref. 101)',
    102 => 'Target protocol error (ref. 102) - (all targets should support present once init successful.)',
    243 => 'Cannot retrieve more than one range of records at once (ref. 243)',
    244 => 'Cannot retrieve record with contents as specified (ref. 244)',
    1066 => 'Cannot retrieve record with contents as specified (ref. 1066)',

    # 2.13. Present - Messages relating to Results Sets
    27 => 'Cannot retrieve records - results set was deleted (ref. 27)',
    28 => 'Cannot retrieve records - results set currently in use (ref. 28)',
    30 => 'Cannot retrieve records - results set not found (ref. 30)',

    # 2.14. Present - Messages relating to Record Syntax
    106 => 'Cannot retrieve record, record syntax not displayable (ref. 106)',
    227 => 'Cannot retrieve record, record syntax not displayable (ref. 227)',
    238 => 'Cannot retrieve record, record syntax not displayable (ref. 238)',
    239 => 'Cannot retrieve record, record syntax not displayable (ref. 239)',
    1070 => 'User not authorized to receive this record in requested syntax',

    # 2.15. Present - Messages relating to Segmentation
    217 => 'Oversized record or records, cannot guarantee quality of results (ref. 217)',
    242 => 'Cannot retrieve record - oversized (ref. 242)',

    # 2.16. Present - Messages relating to Individual Records
    14 => 'System error - cannot retrieve record or records (ref. 14)',
    15 => 'Cannot retrieve requested record - security failure (ref. 15)',
    16 => 'Oversized record, cannot be retrieved (ref. 16)',
    17 => 'Oversized record, cannot be retrieved (ref. 17)',
    103 => 'Record could not be retrieved - security failure (ref. 103)',
    104 => 'Record could not be retrieved - security failure (ref. 104)',
    1026 => 'Cannot retrieve record, currently locked (ref. 1026)',
    1028 => 'Cannot retrieve record - record deleted (ref. 1028)',

    # 2.17. Scan - General Messages
    101 => 'Security failure (ref. 101)',
    102 => 'Security failure (ref. 102)',
    205 => 'Cannot skip records when scanning, can only scan one by one (ref. 205)',
    206 => 'Cannot skip {step size} records when scanning (ref. 206)',
    228 => 'Do not display - origin should correct error',
    229 => 'Cannot scan by {term type} (ref. 229). Preferably, origin should retry scan using "general" type',
    232 => 'Cannot perform scan as requested (ref. 232) Preferably origin should perform multiple scans.',
    233 => 'Do not display - origin should resubmit scan without position in response.',
    234 => 'Cannot perform scan as requested (ref. 234) Preferably origin should perform multiple scans.',
    240 => 'Scan not completed - resources exhausted (ref. 240)',
    241 => 'Cannot scan any further - beginning or end reached (ref. 241)',
    1029 => 'Cannot perform scan as requested (ref. 1029) Preferably origin should perform multiple scans.',

    # 2.18. Scan - Messages relating to Database Selection
    109 => '{Database name} currently unavailable (ref. 109)',
    111 => 'Cannot perform scan - too many databases (ref. 111)',
    235 => 'Database does not exist (ref. 235)',
    236 => 'Access to {database name} denied (ref. 236)',
    1025 => 'Scan not available for {database name} (ref. 1025)',

    # 2.19. Scan - Messages relating to Scan attributes
    113 => 'Cannot perform scan as requested (ref. 113)',
    114 => 'Cannot perform scan - {use attribute} not supported (ref. 114)',
    115 => 'Cannot perform scan - structure of term not supported (ref. 115)',
    116 => 'Do not display - origin should correct error',
    117 => 'Cannot perform scan - {relation attribute} not supported (ref. 117)',
    118 => 'Cannot perform scan - {structure attribute} not supported (ref. 118)',
    119 => 'Cannot perform scan - {position attribute} not supported (ref. 119)',
    120 => 'Cannot truncate scan as requested (ref. 120)',
    121 => 'Cannot scan by {attribute set / attribute} (ref. 121)',
    122 => 'Cannot perform scan - {completeness attribute} not supported (ref. 122)',
    123 => 'Cannot scan {attribute} with {attribute} as requested (ref. 123)',
    126 => 'Cannot perform scan - incorrect construction (ref. 126)',
    1024 => 'Cannot perform scan as requested (ref. 1024)',
    1051 => 'Do not display - origin should correct error',

    # 2.20. Explain
    102 => 'Security failure (ref. 102)',
    1007 => 'Message not displayed - origin should redirect explain request.',

    # 2.21. Sort
    102 => 'Security failure (ref. 102)',
    207 => 'Cannot sort by {sequence} (ref. 207)',
    208 => 'Do not display - origin should correct error',
    209 => 'Can only sort the results from one database (ref. 209)',
    210 => 'Cannot sort results from {Database name} (ref. 210)',
    211 => 'Unable to sort - too many sort keys (ref. 211)',
    212 => 'Do not display - origin should correct error',
    213 => 'Do not display - origin should correct error',
    214 => 'Do not display - origin should correct error',
    215 => 'Do not display - origin should correct error',
    216 => 'Do not display - origin should correct error',
    230 => 'Too many records to sort (ref. 230)',
    231 => 'Unable to sort as requested (ref. 231)',
    237 => 'Do not display - origin should correct error',

    # 3. Messages - Numeric Sequence
    1 => 'System unavailable - Permanent system error (ref. 1)',
    2 => 'System temporarily unavailable (ref. 2.)',
    3 => 'Unsupported search for this database (ref. 3)',
    4 => 'Search cannot be performed - only contains common words that are not indexed (ref. 4)',
    5 => 'Search cannot be performed - Too many words or phrases in the search (ref. 5)',
    6 => 'Search cannot be performed - Too many words or phrases in the search (ref. 6)',
    7 => 'Search cannot be performed - Too many truncated words or phrases in the search (ref. 7)',
    8 => 'Search cannot be performed (ref. 8)',
    9 => 'Search cannot be performed - Truncated words are too short (ref. 9)',
    10 => 'Search cannot be performed - Invalid format of record number (ref. 10)',
    11 => 'Search cannot be performed - Too long (too many characters in the search) (ref. 11)',
    12 => 'Too many records retrieved (ref. 12)',
    13 => 'No more records to display ( ref. 13)',
    14 => 'System error - cannot retrieve record or records (ref. 14)',
    15 => 'Cannot retrieve requested record - security failure (ref. 15)',
    16 => 'Oversized record, cannot be retrieved (ref. 16)',
    17 => 'Oversized record, cannot be retrieved (ref. 17)',
    18 => 'Cannot search by {result set name} (ref. 18)',
    19 => 'Cannot search by more than one named results set (ref. 19)',
    20 => 'Cannot perform search - {operator} not valid with a results set. Valid search = {Results set name} AND {term} - Perform search? (ref. 20)',
    21 => 'Cannot create a results set with this name because it already exists - Delete existing results set? (ref. 21)',
    22 => 'Naming of search results not supported (ref. 22)',
    23 => 'Specific combination of databases not supported (ref. 23)',
    24 => 'Origin should send a present request with an element set name of F or B and give message "Unable to specify record content as requested". If the message is still received, origin should display "Target protocol error (ref. 24)".',
    25 => 'Origin should send a present request with an element set name of F or B and give message "Unable to specify record content as requested". If the message is still received, origin should display "Target protocol error (ref. 25)".',
    26 => 'Origin should send a present request with an element set name of F or B and give message "Unable to specify record content as requested".',
    27 => 'Cannot retrieve records - results set was deleted (ref. 27)',
    28 => 'Cannot retrieve records - results set currently in use (ref. 28)',
    29 => '{Database name} currently unavailable (ref. 29)',
    30 => 'Cannot retrieve records - results set not found (ref. 30)',
    31 => 'Search has not completed - No results available (ref. 31)',
    32 => 'Search has not completed - Partial results available, quality unknown (ref. 32)',
    33 => 'Search has not completed - Partial results available (ref. 33)',
    100 => 'Unspecified error (ref. 100)',
    101 => 'Security failure (ref. 101)',
    102 => 'For Search and Present: Target protocol error (ref. 102)',
    # For other services: Security failure (ref. 102)

    103 => 'Record could not be retrieved - security failure (ref. 103)',
    104 => 'Record could not be retrieved - security failure (ref. 104)',
    105 => 'Terminated as requested (ref. 105) (if user initiated the request)',
    106 => 'Cannot retrieve record, record syntax not displayable (ref. 106)',
    107 => 'Origin should send a type 1 query. If the message is still received, origin should display "Target protocol error (ref. 107)".',
    108 => 'Cannot perform search - malformed query (ref. 108)',
    109 => '{Database name} currently unavailable (ref. 109)',
    110 => 'Cannot perform search - {operator} not supported (ref. 110)',
    111 => 'Cannot perform search/scan - too many databases (ref. 111)',
    112 => 'Too many results sets already exist, select one or more from the following list to delete (ref. 112)',
    113 => 'Cannot perform search/scan as requested (ref. 113)',
    114 => 'Cannot perform search/scan - {use attribute} not supported (ref. 114)',
    115 => 'Cannot perform search/scan - structure of term not supported (ref. 115)',
    116 => 'Do not display - origin should correct error',
    117 => 'Cannot perform search/scan - {relation attribute} not supported (ref. 117)',
    118 => 'Cannot perform search/scan - {structure attribute} not supported (ref. 118)',
    119 => 'Cannot perform search/scan - {position attribute} not supported (ref. 119)',
    120 => 'Cannot truncate search/scan as requested (ref. 120)',
    121 => 'Cannot search/scan by {attribute set / attribute} (ref. 121)',
    122 => 'Cannot perform search/scan - {completeness attribute} not supported (ref. 122)',
    123 => 'Cannot search/scan {attribute} with {attribute} as requested (ref. 123)',
    124 => 'Cannot search by {term} (ref. 124)',
    125 => 'Cannot search by {term} (ref. 125)',
    126 => 'Cannot perform search/scan - incorrect construction (ref. 126)',
    127 => '{Unnormalised value} cannot be processed (ref. 127)',
    128 => '{Results set name} is an illegal name (ref. 128)',
    129 => 'Cannot do a proximity search of a results set (ref. 129)',
    130 => 'Do not display - origin should correct error',
    131 => 'Cannot do a proximity search using {relation type} (ref. 131)',
    132 => 'Cannot do a proximity search based on {known proximity unit} (ref. 132)',
    201 => 'Cannot do a proximity search with {attribute} combined with {attribute} (ref. 201)',
    202 => 'Cannot do a proximity search with a distance of {distance} and {known proximity unit} (ref. 202)',
    203 => 'Do not display - origin should retry without the ordered flag.',
    205 => 'Cannot skip records when scanning, can only scan one by one (ref. 205)',
    206 => 'Cannot skip {step size} records when scanning (ref. 206)',
    207 => 'Cannot sort by {sequence} (ref. 207)',
    208 => 'Do not display - origin should correct error',
    209 => 'Can only sort the results from one database (ref. 209)',
    210 => 'Cannot sort results from {Database name} (ref. 210)',
    211 => 'Unable to sort - too many sort keys (ref. 211)',
    212 => 'Do not display - origin should correct error',
    213 => 'Do not display - origin should correct error',
    214 => 'Do not display - origin should correct error',
    215 => 'Do not display - origin should correct error',
    216 => 'Do not display - origin should correct error',
    217 => 'Oversized record or records, cannot guarantee quality of results (ref. 217)',
    218 => 'Do not display - client should assign a different name',
    219 => 'Cannot perform {extended service} cannot find task reference number (ref. 219)',
    220 => 'Cannot perform {extended service}, quota exceeded (ref. 220)',
    221 => 'Cannot perform {extended service}, service not supported (ref. 221)',
    222 => 'Cannot perform {extended service}, not authorized (ref. 222)',
    223 => 'Cannot change or delete {extended service}, not authorized (ref. 223)',
    224 => 'Cannot perform {extended service} interactively (ref. 224)',
    225 => 'Cannot perform {extended service} interactively (ref. 225)',
    226 => 'Cannot perform this {extended service} interactively (ref. 226)',
    227 => 'Cannot retrieve record, record syntax not displayable (ref. 227)',
    228 => 'Do not display - origin should correct error',
    229 => 'Cannot scan by {term type} (ref. 229). Preferably, origin should retry scan using "general" type',
    230 => 'Too many records to sort (ref. 230)',
    231 => 'Unable to sort as requested (ref. 231)',
    232 => 'Cannot perform scan as requested (ref. 232) Preferably origin should perform multiple scans.',
    233 => 'Do not display - origin should resubmit scan without position in response.',
    234 => 'Cannot perform scan as requested (ref. 234) Preferably origin should perform multiple scans.',
    235 => 'Database does not exist (ref. 235)',
    236 => 'Access to {database name} denied (ref. 236)',
    237 => 'Do not display - origin should correct error',
    238 => 'Cannot retrieve record, record syntax not displayable (ref. 238)',
    239 => 'Cannot retrieve record, record syntax not displayable (ref. 239)',
    240 => 'Scan not completed - resources exhausted (ref. 240)',
    241 => 'Cannot scan any further - beginning or end reached (ref. 241)',
    242 => 'Cannot retrieve record - oversized (ref. 242)',
    243 => 'Cannot retrieve more than one range of records at once (ref. 243)',
    244 => 'Cannot retrieve record with contents as specified (ref. 244)',
    245 => 'Cannot perform search as requested (ref. 245)',
    246 => 'Cannot perform search as requested (ref. 246)',
    247 => 'Cannot perform search as requested (ref. 247)',
    1001 => 'Do not display - origin should correct error or display "Protocol error (ref. 1001)"',
    1002 => 'Cannot accept Item Order request as formatted (ref. 1002)',
    1003 => 'Cannot accept Item Order request as formatted (ref. 1003)',
    1004 => 'Cannot perform {extended service} - security procedures not met (ref. 1004)',
    1005 => 'Do not display - perform a present request',
    1006 => 'Do not display - perform a present request',
    1007 => 'Message not displayed - origin should redirect explain request.',
    1008 => 'Cannot perform {extended service} - missing data (ref. 1008)',
    1009 => 'Cannot accept Item Order request as formatted (ref. 1009)',
    1010 => 'Unknown user identification (ref. 1010)',
    1011 => 'Unknown user identification or invalid password (ref. 1011)',
    1012 => 'No searches remaining (pre-purchased searches exhausted) (ref. 1012)',
    1013 => 'User identifier not valid for this operation ref. 1013)',
    1014 => 'Unknown user identification or invalid password (ref. 1014)',
    1015 => 'System temporarily unavailable (ref. 1015)',
    1016 => 'System temporarily unavailable (ref. 1016)',
    1017 => 'User identifier not valid for any available databases (ref. 1017)',
    1018 => 'System temporarily unavailable (ref. 1018)',
    1019 => 'System temporarily unavailable (ref. 1019)',
    1020 => 'System temporarily available (ref. 1020)',
    1021 => 'Access denied - Account has expired (ref. 1021)',
    1022 => 'Password expired - please supply new password (ref. 1022)',
    1023 => 'Password changed - please supply new password (ref. 1023)',
    1024 => 'Cannot perform search as requested (ref. 1024)',
    1025 => 'For Search and Present - Target Protocol error (ref. 1025)',
    # For other services : Selected database {database} does not support {service} (ref. 1025)

    1026 => 'Cannot retrieve record, currently locked (ref. 1026)',
    1027 => 'Cannot perform search - incorrect construction (ref. 1027) - to be displayed if SQL created by user, else, display "SQL error (ref. 1027)"',
    1028 => 'Cannot retrieve record - record deleted (ref. 1028)',
    1029 => 'Cannot perform scan as requested (ref. 1029) Preferably origin should perform multiple scans.',
    1030 => 'Unknown message (ref. 1030)',
    1031 => 'Unknown message (ref. 1031)',
    1032 => 'Unknown message (ref. 1032)',
    1033 => 'Unknown message (ref. 1033)',
    1034 => 'Unknown message (ref. 1034)',
    1035 => 'Unknown message (ref. 1035)',
    1036 => 'Unknown message (ref. 1036)',
    1037 => 'Unknown message (ref. 1037)',
    1038 => 'Unknown message (ref. 1038)',
    1039 => 'Unknown message (ref. 1039)',
    1040 => 'Do not display - origin should correct error',
    1041 => 'Cannot perform {extended service} - invalid transaction data (ref. 1041)',
    1042 => 'Cannot perform {extended service} - invalid transaction data (ref. 1042)',
    1043 => 'Do not display - origin should correct error',
    1044 => 'Do not display - origin should correct error',
    1045 => 'Cannot perform {extended service} - {schema} schema unknown (ref. 1045)',
    1046 => 'Do not display - origin should break into two or more packages. If only one record in package, treat as if message 1052.',
    1047 => 'Do not display - origin should correct error',
    1048 => 'Do not display - origin should break into two or more packages. If only one record in package, treat as if message 1052.',
    1049 => 'Not displayed (but may be logged). Origin should search the task package or the database directly.',
    1050 => 'Do not display - origin should break into two or more packages. If only one record in package, treat as if message 1052.',
    1051 => 'Do not display - origin should correct error',
    1052 => 'Cannot update this record - too large (ref. 1052)',
    1053 => 'Not displayed (but may be logged). Origin should search the task package or the database directly.',
    1054 => 'Access denied - transaction incomplete (ref. 1054)',
    1055 => 'Access denied - transaction incomplete (ref. 1055)',
    1056 => 'Cannot perform search as requested (ref. 1056)',
    1057 => 'Cannot perform {extended service} as requested (ref. 1057)',
    1058 => 'Results may contain duplicates (ref. 1058)',
    1059 => 'Results may contain duplicates (ref. 1059)',
    1060 => 'Results may contain duplicates (ref. 1060)',
    1061 => 'Results may contain duplicates (ref. 1061)',
    1062 => 'Results may contain duplicates (ref. 1062)',
    1063 => 'Results may contain duplicates (ref. 1063)',
    1064 => 'Results may contain duplicates (ref. 1064)',
    1065 => 'Results may contain duplicates (ref. 1065)',
    1066 => 'Cannot retrieve record with contents as specified (ref. 1066)',
    # 1070 => 'User not authorized to receive this record in requested syntax',
);

our ( @ISA, @EXPORT_OK );

BEGIN {
    require Exporter;
    @ISA       = qw(Exporter);
    @EXPORT_OK = qw(BreedingSearch ImportBreedingAuth Z3950Search Z3950SearchAuth);
}

=head1 NAME

C4::Breeding : module to add biblios to import_records via
               the breeding/reservoir API.

=head1 SYNOPSIS

    Z3950Search($pars, $template);
    ($count, @results) = &BreedingSearch($title,$isbn);

=head1 DESCRIPTION

This module contains routines related to Koha's Z39.50 search into
cataloguing reservoir features.

=head2 BreedingSearch

($count, @results) = &BreedingSearch($term);
C<$term> contains the term to search, it will be searched as title,author, or isbn

C<$count> is the number of items in C<@results>. C<@results> is an
array of references-to-hash; the keys are the items from the C<import_records> and
C<import_biblios> tables of the Koha database.

=cut

sub BreedingSearch {
    my ($term) = @_;
    my $dbh    = C4::Context->dbh;
    my $count  = 0;
    my ( $query, @bind );
    my $sth;
    my @results;

    my $authortitle = $term;
    $authortitle =~ s/(\s+)/\%/g;               #Replace spaces with wildcard
    $authortitle = "%" . $authortitle . "%";    #Add wildcard to start and end of string
                                                # normalise ISBN like at import
    my @isbns = C4::Koha::GetVariationsOfISBN($term);

    $query = "SELECT import_biblios.import_record_id,
                import_batches.file_name,
                import_biblios.isbn,
                import_biblios.title,
                import_biblios.author,
                import_batches.upload_timestamp
              FROM  import_biblios
              JOIN import_records USING (import_record_id)
              JOIN import_batches USING (import_batch_id)
              WHERE title LIKE ? OR author LIKE ? OR isbn IN (" . join( ',', ('?') x @isbns ) . ")";
    @bind = ( $authortitle, $authortitle, @isbns );
    $sth  = $dbh->prepare($query);
    $sth->execute(@bind);
    while ( my $data = $sth->fetchrow_hashref ) {
        $results[$count] = $data;

        # FIXME - hack to reflect difference in name
        # of columns in old marc_breeding and import_records
        # There needs to be more separation between column names and
        # field names used in the templates </soapbox>
        $data->{'file'} = $data->{'file_name'};
        $data->{'id'}   = $data->{'import_record_id'};
        $count++;
    }    # while

    $sth->finish;
    return ( $count, @results );
}    # sub breedingsearch

=head2 Z3950Search

Z3950Search($pars, $template);

Parameters for Z3950 search are all passed via the $pars hash. It may contain isbn, title, author, dewey, subject, lccall, controlnumber, stdid, srchany.
Also it should contain an arrayref id that points to a list of id's of the z3950 targets to be queried (see z3950servers table).
This code is used in acqui/z3950_search and cataloging/z3950_search.
The second parameter $template is a Template object. The routine uses this parameter to store the found values into the template.

=cut

sub Z3950Search {
    my ( $pars, $template ) = @_;

    my @id           = @{ $pars->{id} };
    my $page         = $pars->{page};
    my $biblionumber = $pars->{biblionumber};

    my $show_next   = 0;
    my $total_pages = 0;
    my @results;
    my @breeding_loop = ();
    my @oConnection;
    my @oResult;
    my @errconn;
    my $s        = 0;
    my $imported = 0;

    my ( $zquery, $squery ) = _bib_build_query($pars);

    my $schema = Koha::Database->new()->schema();
    my $rs     = $schema->resultset('Z3950server')->search(
        { id           => [@id] },
        { result_class => 'DBIx::Class::ResultClass::HashRefInflator' },
    );
    my @servers = $rs->all;
    foreach my $server (@servers) {
        my $server_zquery = $zquery;
        if ( my $attributes = $server->{attributes} ) {
            $server_zquery = "$attributes $zquery";
        }
        $oConnection[$s] = _create_connection($server);
        $oResult[$s] =
              $server->{servertype} eq 'zed'
            ? $oConnection[$s]->search_pqf($server_zquery)
            : $oConnection[$s]->search( ZOOM::Query::CQL->new( _translate_query( $server, $squery ) ) );
        $s++;
    }
    my $xslh = Koha::XSLT::Base->new;

    my $nremaining = $s;
    while ( $nremaining-- ) {
        my $k;
        my $event;
        while ( ( $k = ZOOM::event( \@oConnection ) ) != 0 ) {
            $event = $oConnection[ $k - 1 ]->last_event();
            last if $event == ZOOM::Event::ZEND;
        }

        if ( $k != 0 ) {
            $k--;
            my ($error) = $oConnection[$k]->error_x();    #ignores errmsg, addinfo, diagset
            if ($error) {
                if ( $error =~ m/^(10000|10007)$/ ) {
                    push( @errconn, { server => $servers[$k]->{host}, error => $error } );
                } else {
                    # for example when we have 'http 400' or '404' or other errors - at least we should log those!
                    #  16  Record exceeds Preferred-message-size   Oversized record, cannot be retrieved (ref. 16)
                    warn "Error when doing search from remote: " . ($ERROR_CODE_MEANING{$error} || $error);
                }
            } else {
                my $numresults = $oResult[$k]->size();
                my $i;
                my $res;
                if ( $numresults > 0 and $numresults >= ( ( $page - 1 ) * 20 ) ) {
                    $show_next   = 1                           if $numresults >= ( $page * 20 );
                    $total_pages = int( $numresults / 20 ) + 1 if $total_pages < ( $numresults / 20 );
                    for (
                        $i = ( $page - 1 ) * 20 ;
                        $i < ( ( $numresults < ( $page * 20 ) ) ? $numresults : ( $page * 20 ) ) ;
                        $i++
                        )
                    {
                        if ( $oResult[$k]->record($i) ) {
                            undef $error;
                            ( $res, $error ) = _handle_one_result(
                                $oResult[$k]->record($i), $servers[$k], ++$imported, $biblionumber,
                                $xslh
                            );    #ignores error in sequence numbering
                            push @breeding_loop, $res if $res;
                            push @errconn, { server => $servers[$k]->{servername}, error => $error, seq => $i + 1 }
                                if $error;
                        } else {
                            push @errconn,
                                {
                                'server'  => $servers[$k]->{servername},
                                error     => ( ( $oConnection[$k]->error_x() )[0] ),
                                error_msg => ( ( $oConnection[$k]->error_x() )[1] ), seq => $i + 1
                                };
                        }
                    }
                }    #if $numresults
            }
        }    # if $k !=0

        $template->param(
            numberpending   => $nremaining,
            current_page    => $page,
            total_pages     => $total_pages,
            show_nextbutton => $show_next ? 1 : 0,
            show_prevbutton => $page != 1,
        );
    }    # while nremaining

    #close result sets and connections
    foreach ( 0 .. $s - 1 ) {
        $oResult[$_]->destroy();
        $oConnection[$_]->destroy();
    }

    $template->param(
        breeding_loop => \@breeding_loop,
        servers       => \@servers,
        errconn       => \@errconn
    );
}

sub _auth_build_query {
    my ($pars) = @_;

    my $qry_build = {
        nameany          => '@attr 1=1002 "#term" ',
        authorany        => '@attr 1=1003 "#term" ',
        authorcorp       => '@attr 1=2 "#term" ',
        authorpersonal   => '@attr 1=1 "#term" ',
        authormeetingcon => '@attr 1=3 "#term" ',
        subject          => '@attr 1=21 "#term" ',
        subjectsubdiv    => '@attr 1=47 "#term" ',
        title            => '@attr 1=4 "#term" ',
        uniformtitle     => '@attr 1=6 "#term" ',
        srchany          => '@attr 1=1016 "#term" ',
        controlnumber    => '@attr 1=12 "#term" ',
    };

    return _build_query( $pars, $qry_build );
}

sub _bib_build_query {

    my ($pars) = @_;

    my $qry_build = {
        isbn            => '@attr 1=7 @attr 5=1 "#term" ',
        issn            => '@attr 1=8 @attr 5=1 "#term" ',
        title           => '@attr 1=4 "#term" ',
        author          => '@attr 1=1003 "#term" ',
        dewey           => '@attr 1=16 "#term" ',
        subject         => '@attr 1=21 "#term" ',
        lccall          => '@attr 1=16 @attr 2=3 @attr 3=1 @attr 4=1 @attr 5=1 ' . '@attr 6=1 "#term" ',
        controlnumber   => '@attr 1=12 "#term" ',
        srchany         => '@attr 1=1016 "#term" ',
        stdid           => '@attr 1=1007 "#term" ',
        publicationyear => '@attr 1=31 "#term" '
    };

    return _build_query( $pars, $qry_build );
}

sub _build_query {

    my ( $pars, $qry_build ) = @_;

    my $zquery = '';
    my $squery = '';
    my $nterms = 0;
    foreach my $k ( sort keys %$pars ) {

        #note that the sort keys forces an identical result under Perl 5.18
        #one of the unit tests is based on that assumption
        if ( ( my $val = $pars->{$k} ) && $qry_build->{$k} ) {
            $qry_build->{$k} =~ s/#term/$val/g;
            $zquery .= $qry_build->{$k};
            $squery .= "[$k]=\"$val\" and ";
            $nterms++;
        }
    }
    $zquery = "\@and " . $zquery for 2 .. $nterms;
    $squery =~ s/ and $//;
    return ( $zquery, $squery );
}

sub _handle_one_result {
    my ( $zoomrec, $servhref, $seq, $bib, $xslh ) = @_;

    my $raw = $zoomrec->raw();
    my $marcrecord;
    if ( $servhref->{servertype} eq 'sru' ) {
        $marcrecord = MARC::Record->new_from_xml(
            $raw, 'UTF-8',
            $servhref->{syntax}
        );
        $marcrecord->encoding('UTF-8');
    } else {
        ($marcrecord) =
            MarcToUTF8Record( $raw, C4::Context->preference('marcflavour'), $servhref->{encoding} // "iso-5426" )
            ;    #ignores charset return values
    }
    SetUTF8Flag($marcrecord);
    my $error;
    ( $marcrecord, $error ) = _do_xslt_proc( $marcrecord, $servhref, $xslh );

    my $batch_id   = GetZ3950BatchId( $servhref->{servername} );
    my $breedingid = AddBiblioToBatch( $batch_id, $seq, $marcrecord, 'UTF-8', 0 );

    #Last zero indicates: no update for batch record counts

    my $row;
    if ($breedingid) {
        my @kohafields =
            ( 'biblio.title', 'biblio.author', 'biblioitems.isbn', 'biblioitems.lccn', 'biblioitems.editionstatement' );
        push @kohafields,
            C4::Context->preference('marcflavour') eq "MARC21" ? 'biblio.copyrightdate' : 'biblioitems.publicationyear';
        $row = C4::Biblio::TransformMarcToKoha(
            { record => $marcrecord, kohafields => \@kohafields, limit_table => 'no_items' } );
        $row->{date}         = $row->{copyrightdate} // $row->{publicationyear};
        $row->{biblionumber} = $bib;
        $row->{server}       = $servhref->{servername};
        $row->{breedingid}   = $breedingid;
        $row->{isbn}         = _isbn_replace( $row->{isbn} );
        my $pref_newtags = C4::Context->preference('AdditionalFieldsInZ3950ResultSearch');
        $row = _add_custom_field_rowdata( $row, $marcrecord, $pref_newtags );
    }
    return ( $row, $error );
}

sub _do_xslt_proc {
    my ( $marc, $server, $xslh ) = @_;
    return $marc if !$server->{add_xslt};

    my $htdocs = C4::Context->config('intrahtdocs');
    my $theme  = C4::Context->preference("template");    #staff
    my $lang   = C4::Languages::getlanguage() || 'en';

    my @files = split ',', $server->{add_xslt};
    my $xml   = $marc->as_xml;
    foreach my $f (@files) {
        $f =~ s/^\s+//;
        $f =~ s/\s+$//;
        next if !$f;
        $f   = C4::XSLT::_get_best_default_xslt_filename( $htdocs, $theme, $lang, $f ) unless $f =~ /^\//;
        $xml = $xslh->transform( $xml, $f );
        last if $xslh->err;    #skip other files
    }
    if ( !$xslh->err ) {
        return MARC::Record->new_from_xml( $xml, 'UTF-8' );
    } else {
        return ( $marc, $xslh->err );    #original record in case of errors
    }
}

sub _add_custom_field_rowdata {
    my ( $row, $record, $pref_newtags ) = @_;
    $pref_newtags //= '';
    my $pref_flavour = C4::Context->preference('MarcFlavour');

    $pref_newtags =~ s/^\s+|\s+$//g;
    $pref_newtags =~ s/\h+/ /g;

    my @addnumberfields;

    foreach my $field ( split /\,/, $pref_newtags ) {
        $field =~ s/^\s+|\s+$//g;    # trim whitespace
        my ( $tag, $subtags ) = split( /\$/, $field );

        if ( $record->field($tag) ) {
            my @content = ();

            for my $marcfield ( $record->field($tag) ) {
                if ($subtags) {
                    my $str = '';
                    for my $code ( split //, $subtags ) {
                        if ( $marcfield->subfield($code) ) {
                            $str .= $marcfield->subfield($code) . ' ';
                        }
                    }
                    if ( not $str eq '' ) {
                        push @content, $str;
                    }
                } elsif ( $tag == 10 ) {
                    push @content, ( $pref_flavour eq "MARC21" ? $marcfield->data : $marcfield->as_string );
                } elsif ( $tag < 10 ) {
                    push @content, $marcfield->data();
                } else {
                    push @content, $marcfield->as_string();
                }
            }

            if (@content) {
                $row->{$field} = \@content;
                push( @addnumberfields, $field );
            }
        }
    }

    $row->{'addnumberfields'} = \@addnumberfields;

    return $row;
}

sub _isbn_replace {
    my ($isbn) = @_;
    return unless defined $isbn;
    $isbn =~ s/ |-|\.//g;
    $isbn =~ s/\|/ \| /g;
    $isbn =~ s/\(/ \(/g;
    return $isbn;
}

sub _create_connection {
    my ($server) = @_;
    my $option1 = ZOOM::Options->new();
    $option1->option( 'async' => 1 );
    $option1->option( 'elementSetName',        'F' );
    $option1->option( 'preferredRecordSyntax', $server->{syntax} );
    $option1->option( 'timeout',               $server->{timeout} ) if $server->{timeout};

    if ( $server->{servertype} eq 'sru' ) {
        foreach ( split ',', $server->{sru_options} // '' ) {

            #first remove surrounding spaces at comma and equals-sign
            s/^\s+|\s+$//g;
            my @temp = split '=', $_, 2;
            @temp = map { my $c = $_; $c =~ s/^\s+|\s+$//g; $c; } @temp;
            $option1->option( $temp[0] => $temp[1] ) if @temp;
        }
    } elsif ( $server->{servertype} eq 'zed' ) {
        $option1->option( 'databaseName', $server->{db} );
        $option1->option( 'user',         $server->{userid} )   if $server->{userid};
        $option1->option( 'password',     $server->{password} ) if $server->{password};
    }
    my $obj = ZOOM::Connection->create($option1);
    if ( $server->{servertype} eq 'sru' ) {
        my $host = $server->{host};
        if ( $host !~ /^https?:\/\// ) {

            #Normally, host will not be prefixed by protocol.
            #In that case we can (safely) assume http.
            #In case someone prefixed with https, give it a try..
            $host = 'http://' . $host;
        }
        $obj->connect( $host . ':' . $server->{port} . '/' . $server->{db} );
    } else {
        $obj->connect( $server->{host}, $server->{port} );
    }
    return $obj;
}

sub _translate_query {    #SRU query adjusted per server cf. srufields column
    my ( $server, $query ) = @_;

    #sru_fields is in format title=field,isbn=field,...
    #if a field doesn't exist, try anywhere or remove [field]=
    my @parts = split( ',', $server->{sru_fields} );
    my %trans = map {
        if (/=/) { ( $`, $' ) }
        else     { () }
    } @parts;
    my $any = $trans{srchany} ? $trans{srchany} . '=' : '';

    my $q = $query;
    foreach my $key ( keys %trans ) {
        my $f = $trans{$key};
        if ($f) {
            $q =~ s/\[$key\]/$f/g;
        } else {
            $q =~ s/\[$key\]=/$any/g;
        }
    }
    $q =~ s/\[\w+\]=/$any/g;    # remove remaining fields (not found in field list)
    return $q;
}

=head2 ImportBreedingAuth

ImportBreedingAuth( $marcrecord, $filename, $encoding, $heading );

    ImportBreedingAuth imports MARC records in the reservoir (import_records table) or returns their id if they already exist.

=cut

sub ImportBreedingAuth {
    my ( $marcrecord, $filename, $encoding, $heading ) = @_;
    my $dbh = C4::Context->dbh;

    my $batch_id = GetZ3950BatchId($filename);
    my $searchbreeding =
        $dbh->prepare("select import_record_id from import_auths where control_number=? and authorized_heading=?");

    my $controlnumber = $marcrecord->field('001')->data;

    $searchbreeding->execute( $controlnumber, $heading );
    my ($breedingid) = $searchbreeding->fetchrow;

    return $breedingid if $breedingid;
    $breedingid = AddAuthToBatch( $batch_id, 0, $marcrecord, $encoding );
    return $breedingid;
}

=head2 Z3950SearchAuth

Z3950SearchAuth($pars, $template);

Parameters for Z3950 search are all passed via the $pars hash. It may contain nameany, namepersonal, namecorp, namemeetingcon,
title, uniform title, subject, subjectsubdiv, srchany.
Also it should contain an arrayref id that points to a list of IDs of the z3950 targets to be queried (see z3950servers table).
This code is used in cataloging/z3950_auth_search.
The second parameter $template is a Template object. The routine uses this parameter to store the found values into the template.

=cut

sub Z3950SearchAuth {
    my ( $pars, $template ) = @_;

    my $dbh  = C4::Context->dbh;
    my @id   = @{ $pars->{id} };
    my $page = $pars->{page} // 1;

    my $show_next   = 0;
    my $total_pages = 0;
    my @encoding;
    my @results;
    my @breeding_loop = ();
    my @oConnection;
    my @oResult;
    my @errconn;
    my @servers;
    my $s = 0;
    my $query;
    my $nterms = 0;

    my $marcflavour = C4::Context->preference('marcflavour');
    my $marc_type   = $marcflavour eq 'UNIMARC' ? 'UNIMARCAUTH' : $marcflavour;
    my $authid      = $pars->{authid};
    my ( $zquery, $squery ) = _auth_build_query($pars);
    foreach my $servid (@id) {
        my $sth = $dbh->prepare("select * from z3950servers where id=?");
        $sth->execute($servid);
        while ( my $server = $sth->fetchrow_hashref ) {
            $oConnection[$s] = _create_connection($server);

            if ( $server->{servertype} eq 'zed' ) {
                my $server_zquery = $zquery;
                if ( my $attributes = $server->{attributes} ) {
                    $server_zquery = "$attributes $zquery";
                }
                $oResult[$s] = $oConnection[$s]->search_pqf($server_zquery);
            } else {
                $oResult[$s] =
                    $oConnection[$s]->search( ZOOM::Query::CQL->new( _translate_query( $server, $squery ) ) );
            }
            $encoding[$s] = ( $server->{encoding} ? $server->{encoding} : "iso-5426" );
            $servers[$s]  = $server;
            $s++;
        }    ## while fetch
    }    # foreach
    my $nremaining = $s;

    while ( $nremaining-- ) {
        my $k;
        my $event;
        while ( ( $k = ZOOM::event( \@oConnection ) ) != 0 ) {
            $event = $oConnection[ $k - 1 ]->last_event();
            last if $event == ZOOM::Event::ZEND;
        }

        if ( $k != 0 ) {
            $k--;
            my ($error) = $oConnection[$k]->error_x();    #ignores errmsg, addinfo, diagset
            if ($error) {
                if ( $error =~ m/^(10000|10007)$/ ) {
                    push @errconn, { server => $servers[$k]->{host} };
                }
            } else {
                my $numresults = $oResult[$k]->size();
                my $i;
                my $result = '';
                if ( $numresults > 0 and $numresults >= ( ( $page - 1 ) * 20 ) ) {
                    $show_next   = 1                           if $numresults >= ( $page * 20 );
                    $total_pages = int( $numresults / 20 ) + 1 if $total_pages < ( $numresults / 20 );
                    for (
                        $i = ( $page - 1 ) * 20 ;
                        $i < ( ( $numresults < ( $page * 20 ) ) ? $numresults : ( $page * 20 ) ) ;
                        $i++
                        )
                    {
                        my $rec = $oResult[$k]->record($i);
                        if ($rec) {
                            my $marcdata = $rec->raw();
                            my $marcrecord;
                            if ( $servers[$k]->{servertype} eq 'sru' ) {
                                $marcrecord =
                                    eval { MARC::Record->new_from_xml( $marcdata, 'UTF-8', $servers[$k]->{syntax} ) };
                                if ( !$marcrecord || $@ ) {
                                    _dump_conversion_error( $servers[$k]->{servername}, $marcdata, $@ );
                                    next;    # skip this one
                                }
                            } else {
                                my ( $charset_result, $charset_errors );
                                ( $marcrecord, $charset_result, $charset_errors ) =
                                    MarcToUTF8Record( $marcdata, $marc_type, $encoding[$k] );
                                if ( !$marcrecord || @$charset_errors ) {
                                    _dump_conversion_error(
                                        $servers[$k]->{servername}, $marcdata, $charset_result,
                                        $charset_errors
                                    );
                                    next;    # skip this one
                                }
                            }
                            $marcrecord->encoding('UTF-8');
                            SetUTF8Flag($marcrecord);

                            my $heading_authtype_code = GuessAuthTypeCode($marcrecord) or next;
                            my $heading               = GetAuthorizedHeading( { record => $marcrecord } );
                            my $breedingid = ImportBreedingAuth( $marcrecord, $servers[$k]->{host}, 'UTF-8', $heading );
                            my %row_data;
                            $row_data{server}       = $servers[$k]->{'servername'};
                            $row_data{breedingid}   = $breedingid;
                            $row_data{heading}      = $heading;
                            $row_data{authid}       = $authid;
                            $row_data{heading_code} = $heading_authtype_code;
                            $row_data{row}          = _add_custom_field_rowdata(
                                {%row_data}, $marcrecord,
                                C4::Context->preference('AdditionalFieldsInZ3950ResultAuthSearch')
                            ) if C4::Context->preference('AdditionalFieldsInZ3950ResultAuthSearch');
                            push( @breeding_loop, \%row_data );
                        } else {
                            push(
                                @breeding_loop,
                                {
                                    'server' => $servers[$k]->{'servername'},
                                    'title'  => join( ': ', $oConnection[$k]->error_x() ), 'breedingid' => -1,
                                    'authid' => -1
                                }
                            );
                        }
                    }
                }    #if $numresults
            }
        }    # if $k !=0

        $template->param(
            numberpending   => $nremaining,
            current_page    => $page,
            total_pages     => $total_pages,
            show_nextbutton => $show_next ? 1 : 0,
            show_prevbutton => $page != 1,
        );
    }    # while nremaining

    #close result sets and connections
    foreach ( 0 .. $s - 1 ) {
        $oResult[$_]->destroy();
        $oConnection[$_]->destroy();
    }

    @servers = ();
    foreach my $id (@id) {
        push @servers, { id => $id };
    }
    $template->param(
        breeding_loop => \@breeding_loop,
        servers       => \@servers,
        errconn       => \@errconn
    );
}

sub _dump_conversion_error {
    require Data::Dumper;
    warn Data::Dumper->new( [ 'Z3950SearchAuth conversion error', @_ ] )->Indent(0)->Dump;
}

1;
__END__

