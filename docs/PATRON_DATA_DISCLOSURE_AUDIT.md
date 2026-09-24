# Patron data disclosure audit

## Purpose

This document defines the implementation contract for Bug 25673. The feature records which authenticated Koha principal caused Koha to disclose personal data attributable to which patron records, and identifies the OAuth API client when the request used client credentials.

The event is a server-side disclosure event. It does not prove that a human looked at the response, that the authorization policy was correct, that every response byte reached the client, why the authenticated principal or API client requested the data, or what an external recipient did with it downstream.

The existing action log does not provide this audit trail. Existing patron, circulation, authentication, and API-key modules primarily record mutations. The action-log viewer and API make existing rows easier to inspect, but do not create patron disclosure events. Report execution logging also does not identify the patrons returned by arbitrary SQL.

## Configuration and claim boundary

`StaffPatronDataDisclosureLog` is a `YesNo` system preference and defaults to off. `StaffPatronDataDisclosureMaxSubjects` is a positive integer and defaults to 1000. The latter bounds one response event; it does not enable or disable logging.

An invalid or non-positive subject limit fails covered responses closed. Page-bounded REST operations validate it at the authentication boundary and return a generic `503` before dispatch; other covered REST operations enforce it during response finalization, and buffered CGI responses enforce it at their output boundary. Values below four also make the covered biblio-items operation unavailable because its static baseline estimate reserves four subjects per item. Historical return claims can raise the real fan-out above that estimate, so the exact post-serialization subject limit remains authoritative. The preference text must make both constraints explicit.

When it is off, new disclosure events are not created, audit-only subject discovery is skipped, and audit failures cannot affect responses. An event created while the preference is on must still commit before its response is emitted if the preference changes during that request. Enabling it does not make all Koha channels auditable. The preference description, release notes, and manual must name the covered surface families and the deferred families below.

When it is on, every covered buffered response is fail-closed: Koha writes the complete disclosure event before emitting the response. If the write fails, Koha emits a generic `503` response without the patron representation. An event that exceeds `StaffPatronDataDisclosureMaxSubjects` is likewise not emitted. Mutation responses, streaming responses, file responses, and channels that cannot satisfy that boundary are not declared covered.

There is no count-only mode. Counts cannot answer which patron was disclosed.

## Event storage

Events use the existing `action_logs` table:

| Field | Value |
| --- | --- |
| `module` | `PATRON_DISCLOSURE` |
| `action` | `DISCLOSE` |
| `user` | authenticated staff borrowernumber |
| `object` | disclosed patron borrowernumber |
| `timestamp` | database insertion time |
| `interface` | existing Koha interface value, normally `intranet` or `api` |
| `info` | the closed JSON payload below |

One response event creates one row for every unique patron disclosed by that response. Rows from the response share a server-generated UUID. If the same patron appears more than once, its data classes are unioned and only one row is written. All rows are inserted directly by the dedicated writer in one database transaction. The writer does not call `C4::Log::logaction` once per patron: that would repeat trace and diff machinery, emit logger messages before the enclosing transaction is known to have committed, and make all-or-none behavior implicit. After commit, the writer emits one PII-free logger message for the event.

When a covered response displays a financial aggregate derived from a guarantor relationship graph, every patron whose balance contributed to that aggregate receives the `financial` class. Audit-aware callers explicitly request those exact patron IDs together with the amount; the default charge-limit result retains its existing public shape. The audit must not infer subjects from a narrower list of relatives rendered elsewhere on the page.

```json
{
  "v": 1,
  "event_id": "server-generated UUID",
  "surface": "patrons.search.results",
  "breadth": "list_page",
  "data_classes": ["contact", "identity", "profile"],
  "auth_source": "oauth",
  "api_client_id": "2bd80ec7-e0c2-41d4-b74e-cf4709a46172"
}
```

`auth_source` records only the mechanism that authenticated the request (`session`, `basic`, or `oauth`). For OAuth client-credentials requests, `api_client_id` records the exact validated `api_keys.client_id`; it is omitted for session and Basic authentication. The typed `user` column remains the Koha patron or service account that owns the key. The audit never copies the API secret or mutable key description. This identifies the technical recipient, not a downstream human or the recipient's later use of the data.

The payload must not contain names, card numbers, addresses, contact values, search terms, raw URLs, request parameters, IP addresses, result rows, actor IDs, target IDs, timestamps, counts, API secrets, mutable API-client descriptions, or client-supplied request IDs. Actor, target, time, and interface already have typed action-log columns. Repeated requests are separate evidence and are never deduplicated across requests.

## Stable vocabulary

`breadth` is one of:

- `record`: one focused patron representation;
- `list_page`: one bounded page of results;
- `workflow_batch`: several patrons assembled by one staff workflow;
- `document`: a generated response intended for printing or download.

`data_classes` is a sorted subset of:

- `identity`: internal and library identifiers, names, titles, relationships;
- `contact`: postal addresses, email addresses, phone numbers, contact preferences;
- `profile`: demographics, membership, home library, category, enrolment, expiry, local statistics, and privacy settings;
- `notes_restrictions`: staff or patron notes, restrictions, lost-card and address flags;
- `circulation_current`: current loans, holds, recalls, overdue state, and current eligibility;
- `circulation_history`: historical circulation activity;
- `financial`: charges, credits, balances, and payment activity;
- `communications`: notices, messages, preferred language, delivery preferences, and correspondence;
- `service_activity`: patron-attributable service state not represented by a patron object;
- `security_administration`: login identifiers, authentication state, failed-login state, API credentials, or tokens;
- `documents_media`: patron images, files, cards, slips, and generated documents;
- `extended_attributes`: locally defined patron attributes whose semantics Koha cannot classify more narrowly.

The checked-in field map is exhaustive for the Patron REST schema. A test must fail when a schema property is added without a class decision.

Accessible null fields count because the API representation exposes that field family for the patron. Nulls produced only by access redaction do not count. The classifier must carry a positive accessibility decision from serialization; nullness is never used as its proxy. For an inaccessible patron it maps `unredact_list` from database-column names through `to_api_mapping`, then adds calculated and embedded fields that are actually appended after generic redaction. For a response without requested embeds, the current inaccessible-patron class floor is `profile` for `library_id` and `expired`, `notes_restrictions` for `restricted`, and `circulation_current` for `self_renewal_available`.

The audit is not a second authorization filter. It classifies the final representation produced by Koha after the existing accessibility and redaction decisions, including calculated fields. Authorization corrections belong in separate security work and must not make this audit silently omit what the response actually contained.

## REST boundary

Covered operations carry an `x-koha-patron-disclosure` OpenAPI extension containing a stable `surface`, successful representation statuses, and one or more subject strategies. The closed surface registry supplies the matching breadth.

The subject strategies are:

- `serialized_patrons`: collect each `Koha::Patron` serialized in the response, including nested embeds and staff-account patrons;
- `patron_references`: collect mapped patron-owner IDs from final non-Patron representations; the initial closed map covers current and historical checkouts, holds, recalls, return claims, and bookings;
- `path_patron`: add the validated patron path parameter for a patron-scoped non-Patron representation;
- `explicit`: require the controller to add at least one exact subject before a successful response can be finalized;
- combinations of the above when a response has more than one source of patron attribution.

For an enabled covered operation, `Koha::REST::Plugin::Objects` passes each request-local collector only when its strategy is declared. `Koha::Patron->to_api` adds the patron and the classes represented by its final API hash. A serialized staff account is personal data and remains a subject; for example, an explicitly embedded checkout `issuer` is logged. For a `patron_references` operation, `Koha::Object->to_api` inspects only the final mapped and redacted hash and adds declared patron-owner fields. Bare staff provenance fields such as `issuer_id`, `created_by`, `updated_by`, and `resolved_by` are deliberately excluded: an ID reference alone describes staff activity rather than a represented Patron record. The callbacks only collect; they never write an action log.

The `explicit` helper marks its strategy complete only after a validated subject is added. If a controller forgets the call, finalization fails closed. Operations that can legitimately produce no attributable subject cannot use this strategy until they gain a separate explicit completion marker.

In a covered operation, direct `find_rs` or `search_rs` followed by `->to_api` without the request collector is a test/build failure. As a second line of defence, serializing any `Koha::Patron` while a covered event is active but `serialized_patrons` is undeclared fails the response closed at runtime. Classification without collection is allowed only for operations that are explicitly deferred or out of scope.

For covered list operations with bounded subject fan-out per result row, OpenAPI metadata declares that bound and any fixed subjects. Explicit `_per_page = -1` and values above the lower of the operation cap and the limit-derived safe ceiling are rejected with `400` and a distinct error code before the result query runs. An oversized implicit `RESTdefaultPageSize` is replaced with that safe ceiling. Core DataTables for these operations remove `All`, values above the ceiling, and unsafe saved page lengths while auditing is enabled. Patron-scoped lists with one fixed subject and no per-row patron attribution need no audit-only page cap. Results are never silently truncated.

The biblio-items response has up to three single-valued patron relations plus return claims. Its fixed estimate is therefore four subjects per item, but historical `return_claims` is a `has_many` relation and has no schema-level finite maximum. The exact shared subject limit remains the final fail-closed guard after serialization and before disclosure; it covers additional historical claims, nested subjects, and explicitly collected subjects. This may replace an unusually broad successful response with `503`, but never emits an unlogged patron ID.

The existing early-registered `after_dispatch` callback finalizes the event after JSON-to-XML conversion and after later plugin callbacks. The DB-dependent REST integration test registers a later callback that contributes another subject and requires both subjects to be committed in one event, proving the runtime ordering on the supported Koha Mojolicious stack. The finalizer writes only when the response matches a declared personal-data representation. Covered error responses are tested to be PII-free.

If the write fails, the finalizer replaces status, body, content type, content length, redirect, attachment, pagination, entity, and request-correlation headers with a generic `503` response. It must not call `render` recursively.

Cookie sessions, Basic authentication, and OAuth are all covered for the same core operation. Authentication source is evidence, not a scope switch.

## CGI and Plack boundary

Buffered staff CGI scripts attach a disclosure descriptor to their final `output_html_with_http_headers` or `output_with_http_headers` call. The descriptor contains the stable surface and exact patron subjects. The surface registry supplies or validates breadth and classes.

The shared output helper writes the complete event immediately before its single header/body print. On failure it prints a generic `503` response instead. Template Toolkit is not an audit boundary and contains no logging calls.

The read-only `svc/checkouts`, `svc/holds`, and `svc/return_claims` endpoints use the same buffered boundary. When auditing is enabled, they validate and resolve all requested patron IDs before querying activity: the raw input list is bounded at four times the subject limit before deduplication, each ID must be a positive signed-INT value, and the unique set must fit the subject limit. A nonexistent target invalidates the whole request rather than creating an audit subject or silently accepting a partial set. Invalid input returns generic JSON `400` with `patron_disclosure_invalid_subjects`; configuration or patron-lookup failure returns generic JSON `503` with `patron_disclosure_subject_resolution_unavailable`. Neither response includes input values or exception details.

Resolved existing patrons remain subjects even when their activity result is empty, because the absence of current loans, holds, or return claims is itself patron information. A single-patron checkout request uses `patrons.checkouts.current`; a multi-patron request uses `patrons.checkouts.current_batch` with `workflow_batch` breadth and unions duplicate subjects in the event. Return-claim resolver data is restricted to the identifier and two name fields used by the staff client; every represented resolver is also an exact audit subject.

The single-patron holds and return-claims services require exactly one raw `borrowernumber` parameter while auditing is enabled, rejecting repeated parameters before any patron lookup. The checkout service accepts a bounded batch; a request with no patron parameters retains its empty successful result, performs no checkout activity query, and creates no disclosure event. This differs from a request naming a nonexistent patron, which is rejected.

Booking tables use bounded server-side pages. The booking availability modal and the record timeline require complete result sets for conflict calculations, so their client code retrieves pages in ascending unique resource-ID order instead of requesting `_per_page=-1` or silently truncating the calculation. Each response page is independently finalized and audited before the next page is consumed. The complete-set calculation has separate limits of 10,000 records and 1,000 page requests; these do not change the per-response subject limit.

The client requires a valid, unchanged `X-Total-Count`, strictly advancing resource IDs, and exactly the advertised number of rows. Missing, duplicate, overlapping, out-of-order, excessive, or prematurely empty pages fail the calculation without returning partial availability. Failure leaves booking submission disabled and shows an error; the timeline likewise shows an error instead of a partial schedule. Offset pagination is not a database snapshot: concurrent changes that preserve both the count and ordering can still escape these checks, and server-side booking conflict validation remains authoritative.

Legacy scripts that print headers before they know their subjects cannot be marked covered until they are buffered. Scripts that mutate circulation or financial state before response finalization additionally need an audit transaction that cannot turn a logging failure into a duplicate mutation on retry. A request that has already changed state remains outside this first slice even if later form validation fails and redisplays patron data; attempted, invalid, and no-op operations are not evidence that such a mutation happened.

## Initial coverage manifest

The first upstream series is a staged core slice, not a claim of complete staff-interface coverage.

### Covered by the first series

- `GET /api/v1/patrons` and `GET /api/v1/patrons/{patron_id}` for session, Basic, and OAuth authentication;
- nested Patron representations and bare patron-owner IDs in `checkout`, `first_hold`, `recall`, and `return_claims` from `GET /api/v1/biblios/{biblio_id}/items`;
- current patron-scoped checkouts, holds, and recalls REST endpoints;
- booking list, record-booking, record-checkout, and patron-specific biblio/item pickup-location REST responses used by the staff booking tables, timeline, and availability modal, including nested represented patrons;
- read-only `svc/checkouts`, `svc/holds`, and `svc/return_claims` JSON responses used by the staff circulation and patron-details pages, including direct requests, related-patron checkout batches, and represented return-claim resolvers;
- `members/moremember.pl` patron details;
- the create form's represented guarantors and the `edit_form`, failed-edit, `duplicate`, and duplicate-match existing-patron representations in `members/memberentry.pl`, never a successful mutation response;
- read-only and confirmation responses from `circ/circulation.pl` when the request has not performed a circulation mutation;
- read-only patron notices, outstanding-account, account-transaction, and account-line-detail representations, including manager patrons actually identified on an account-line detail; notice sending, resending, payments, credits, refunds, payouts, discounts, voids, and write-offs remain excluded mutation responses;
- server-rendered circulation and recall history, the holds-history page shell plus its audited REST data, and read-only alert subscriptions; barcode export and unsubscribe mutation responses remain excluded;
- patron purchase suggestions, including each manager patron whose identity is rendered, subscription routing lists, and circulation statistics;
- action-log viewer labels, reviewed auditor SQL, tests, and operational guidance.

### Blocking or immediate dependent work

- redesign successful mutation responses from `circ/circulation.pl` so a failed audit cannot invite a duplicate checkout, return, hold, or claim-resolution retry;
- redesign `svc/renew` and `svc/checkin` so a failed audit cannot follow an already committed mutation;
- cover `circ/returns.pl`, `circ/pendingreserves.pl`, and `circ/waitingreserves.pl` after their exact rendered patron sets are proven by tests;
- separate generic action-log access from ordinary staff access and design its meta-audit or redaction boundary. Since Bug 40136, `MEMBERS` create, modify, and delete rows can carry patron values in `info` and `diff`, while other modules retain free-form payloads that do not always expose a trustworthy typed patron subject. Merely annotating `GET /api/v1/action_logs` would therefore create a false completeness claim;
- fix known patron-visibility gate defects independently; successful disclosures through a defective gate must still be audited.

### Deferred families

- arbitrary SQL reports and report exports;
- plugin and contrib REST routes;
- finance, payment, credit, and debit representations other than the three declared read-only account views;
- notice mutations, correspondence outside the declared notice-history page, slips, and asynchronous email or SMS delivery;
- circulation and hold history beyond the declared core pages and endpoints;
- direct patron-image and patron-file responses, cards, and bulk exports, including the direct barcode/CSV export in `members/readingrec.pl`; image and file metadata already integrated into the covered patron-details response is classified as `documents_media`;
- permissions, password, two-factor, and API-key administration;
- clubs, housebound, curbside, ILL, suggestion and routing workflows outside their declared patron-list pages, batch tools, and cleanup tools;
- generic action-log viewing and export meta-audit;
- OPAC, SIP2, ILS-DI, background jobs, streaming, WebSocket, and send-file responses.

Every deferred family needs its own reviewable dependent bug or series. A static source scan is a drift alarm, not evidence that the inventory is complete.

## Auditor access and SQL

The first series reuses `tools.view_system_logs` for the existing action-log viewer and API. It does not create a new auditor role or UI. This granular permission can be granted without superlibrarian and must be treated as a trusted-auditor personal-data permission, not as an ordinary staff permission, while relying on the first-series threat boundary.

The existing action-log API can embed patron and librarian representations for that privileged reader. `MEMBERS` rows created by current Koha can also expose patron values directly through `info` and `diff`, and the CSV path exports raw rows. Reading or exporting these representations is itself an explicitly deferred meta-audit surface. A non-superlibrarian with `tools.view_system_logs` is outside the first-series protection claim and can access such data without creating a `PATRON_DISCLOSURE` event. Closing that gap requires a separate permission and response design, or typed subject attribution and redaction for every PII-bearing action-log payload; it is not safely solved by adding a partial route annotation.

Reviewed SQL is supplied as documentation and is never auto-installed as a saved report. Guided Reports uses `reports.execute_reports`, which is a different confidentiality boundary from `tools.view_system_logs`.

The subject-first auditor query filters `module = 'PATRON_DISCLOSURE'`, `action = 'DISCLOSE'`, `object`, and a time range:

```sql
SELECT action_id,
       timestamp,
       user AS librarian_borrowernumber,
       object AS disclosed_borrowernumber,
       interface,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.event_id')) AS event_id,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.surface')) AS surface,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.breadth')) AS breadth,
       JSON_EXTRACT(info, '$.data_classes') AS data_classes,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.auth_source')) AS auth_source,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.api_client_id')) AS api_client_id
FROM action_logs
WHERE module = 'PATRON_DISCLOSURE'
  AND action = 'DISCLOSE'
  AND object = <<Patron borrowernumber>>
  AND timestamp >= <<From date|date>>
  AND timestamp < DATE_ADD(<<Through date|date>>, INTERVAL 1 DAY)
ORDER BY timestamp, action_id;
```

To reconstruct one response event without concatenating or truncating subject IDs, return its rows in subject order:

```sql
SELECT action_id,
       timestamp,
       user AS librarian_borrowernumber,
       object AS disclosed_borrowernumber,
       interface,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.surface')) AS surface,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.breadth')) AS breadth,
       JSON_EXTRACT(info, '$.data_classes') AS data_classes,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.auth_source')) AS auth_source,
       JSON_UNQUOTE(JSON_EXTRACT(info, '$.api_client_id')) AS api_client_id
FROM action_logs
WHERE module = 'PATRON_DISCLOSURE'
  AND action = 'DISCLOSE'
  AND JSON_UNQUOTE(JSON_EXTRACT(info, '$.event_id')) = <<Disclosure event UUID>>
ORDER BY object, action_id;
```

Current and deleted patron joins are annotations only: mutable directory data must not be presented as proof of historical identity. These queries intentionally report the immutable numeric IDs stored with the event.

The audit owner must set and document a retention period. Before purge, review the affected row count with the same module, action, and age boundary:

```sql
SELECT COUNT(*) AS disclosure_rows_to_purge
FROM action_logs
WHERE module = 'PATRON_DISCLOSURE'
  AND action = 'DISCLOSE'
  AND timestamp < DATE_SUB(CURDATE(), INTERVAL 730 DAY);
```

Existing cleanup support can then target only those rows:

```console
misc/cronjobs/cleanup_database.pl --logs 730 --log-module PATRON_DISCLOSURE --log-action DISCLOSE --confirm
```

Running this command without `--confirm` does not delete rows, but it also does not enumerate or count them and is not a sufficient review oracle.

The example retains two years only as an illustration, not as a legal recommendation. Export to a separately administered store before purge when the organization's audit policy requires longer retention or stronger tamper resistance.

Before proposing new indexes, benchmark insertion, subject-history queries, time-range queries, purge, replication, and backup impact with realistic 1 million and 10 million row datasets. A composite index or dedicated audit table is a measured follow-up, not an assumption.

## Threat model

The stated attacker is an authenticated librarian who can access ordinary patron or circulation functions but does not have superlibrarian, system-administration, system-log, command-line, database, or server access. The system-log exclusion is material rather than shorthand for superlibrarian: `tools.view_system_logs` is independently assignable and currently exposes the deferred action-log channel described above.

For covered responses, this attacker must not bypass logging by switching among session, Basic, and OAuth authentication, calling the legacy checkout or hold services directly, requesting XML, using nested REST embeds, refreshing requests, requesting an empty patron activity result, or causing an audit insert failure.

Within normal Koha permissions the attacker cannot delete `action_logs` through the staff interface or REST API. Guided Reports is SELECT-only and cannot delete rows, but arbitrary report execution can disclose patron data and remains a separate audit gap.

A user who can manage system preferences can disable the feature through Koha; that preference change is itself action-logged. A database or server administrator can disable the preference directly, alter code, forge or delete rows, or change retention. The feature therefore does not claim tamper evidence against privileged operators. That requires append-only collection in a separately administered trust domain.

## Required oracles

- preference off: no rows and unchanged responses;
- preference on: one row per unique patron, one server UUID per response, class union, transactional rollback on any insert failure, and one post-commit event logger message;
- two sequential requests in one persistent worker produce distinct events;
- a later-registered REST `after_dispatch` hook contributes to the event before the audit finalizer commits it;
- a forged `x-koha-request-id` never becomes the stored event ID;
- session, Basic, and OAuth calls to the same covered operation all log equivalent disclosures; only OAuth records the exact validated API client ID, while the secret and mutable key description remain absent;
- nested item embeds log every distinct Patron represented plus mapped bare patron-owner IDs, exclude staff provenance IDs, and ignore server-side relationships that were not serialized;
- redacted Patron output uses the mapped positive unredact set, excludes redaction-created null classes, and includes calculated or embedded fields that remain in the final response;
- explicit `_per_page = -1`, oversized covered pages, and over-limit nested subject sets fail without truncation or patron disclosure; oversized implicit defaults and core DataTable choices are constrained to the safe ceiling;
- schema drift fails until every new Patron property is classified;
- a successful empty patron-scoped activity response still logs its path patron and declared activity class;
- direct and page-driven `svc/checkouts`, `svc/holds`, and `svc/return_claims` calls log every resolved existing patron before emitting JSON, including empty activity results, related-patron batches, and represented return-claim resolvers; nonexistent or mixed-invalid targets produce no event, raw and unique limits are checked before activity queries, and operational errors are distinct from invalid input;
- booking tables and complete-set booking calculations use bounded pages, log booking and checkout patron references plus embedded patrons, audit the exact patron whose pickup eligibility is calculated, and never restore `_per_page=-1` while auditing is enabled;
- complete-set booking calculations preserve unique resource ordering, reject inconsistent counts or repeated/overlapping pages, enforce record/request limits, and never enable submission with partial availability;
- covered generic errors create no rows and contain no patron sentinel;
- forced write failure yields a PII-free `503` under JSON, XML, plain CGI, and Plack CGI, with correct headers and no partial rows;
- mutation, streaming, file, plugin, public, and deferred operations cannot accidentally acquire a false covered status;
- the auditor SQL returns the expected actor, target, event grouping, surface, breadth, classes, and authentication source without exposing copied PII.
