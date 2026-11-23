# OPAC browser proof of work

The optional Apache challenge uses a server-issued SHA-256 proof of work
and a server-authenticated `KOHA_INIT` cookie. It does not authenticate a
patron or prove that a client is human. Automated clients can perform the
same work. This is an admission cost for selected browser routes, not a
replacement for capacity limits, authentication or network protection.

## Request flow and trust boundaries

1. Apache selects the protected route. Static challenge resources and
   explicitly public machine interfaces are outside this gate.
2. The public cookie shape and current date are checked in Apache without
   cryptography. Missing, malformed, duplicate, oversized and old-date
   clearance cookies do not invoke the verifier.
3. A correctly shaped cookie goes to the persistent verifier. Its HMAC,
   expiry, client address and configured instance identifier must all be valid before
   the original request can reach Koha. `CGISESSID` and `KOHA_INIT=1` do
   not bypass this check.
4. A browser without clearance receives the static challenge document at
   its original URL. The document requests a signed random challenge,
   computes its work in a Web Worker, and submits the counter to Apache.
5. The server authenticates the challenge and calculates the work hash
   itself. Only success sets the `Secure; HttpOnly; SameSite=Lax; Path=/`
   clearance cookie. The browser then reloads the original URL.

Unverified methods other than GET/HEAD return 429. Submitted forms are
not redirected to a challenge and are never replayed automatically.
The user can obtain clearance in a separate tab before retrying a form.
Clients without JavaScript receive an explanation. A computation or
network failure exposes an explicit retry button; there is no automatic
endless retry loop.

The Apache `RewriteMap prg` helper runs verification in a local worker
using Perl modules already required by Koha. It loads neither the Koha application nor its
database configuration. Each check performs bounded parsing and one
HMAC; solving adds one SHA-256 check, never a server-side search. Apache
serializes access to an external map using its rewrite-map mutex, so
capacity must be tested for the intended traffic before deployment.
See [Apache's RewriteMap documentation](https://httpd.apache.org/docs/2.4/rewrite/rewritemap.html#prg).

## Configuration and keys

Enable the challenge exactly as before, in the shared antibot configuration
or the OPAC virtual host:

```apache
SetEnvIf Request_URI ^ ANTIBOT_ENABLED=1
```

Check the Apache configuration and reload Apache to apply changes. There
is no System Preference, database lookup or policy synchronization service.
Without the flag, requests do not use the verifier. The default scope
covers selected OPAC scripts and their search, home and
`/bib/`, `/isbn/`, `/issn/` aliases. The optional
`ANTIBOT_ALL=1` also protects other browser routes. It does not enable
protection on the staff virtual host.
The REST API (`/api/`) and OPAC services (`/cgi-bin/koha/svc/`) are exempt
in both modes. Koha still handles their authentication and permissions.

The packaged verifier is `/usr/sbin/koha-opac-pow`. The package prepares a
missing signing key during configuration, without printing its contents or
replacing an existing key ring. Its default key file is
`/etc/koha/antibot.keys`: one or two independently generated 32-byte
keys, written as lowercase hexadecimal, each followed by a newline.
The first key issues new tokens; the second only verifies previous
tokens during rotation. Provision the file as a regular file owned by
root, group `www-data`, mode 0640, and protect its containing directory.
Source installations can prepare it once with `koha-opac-pow --init-key`,
run as root; this is installation preparation, not another enable flag.
Do not store keys in version control, pass them as command arguments, or
print them in diagnostics. A missing, unsafe or invalid key file leaves
the verifier unavailable; protected requests must not reach Koha.

The map runs as `www-data:www-data`. Other Apache users require adapting
the map identity and key-file group together (`--key-group` controls initial
key preparation). Optional policy parameters are ordinary helper arguments
in the existing Apache configuration:

```apache
RewriteMap koha_antibot "prg:/usr/sbin/koha-opac-pow --difficulty 16 --challenge-ttl 120 --clearance-ttl 3600" www-data:www-data
```

For a per-instance policy, put an overriding `RewriteMap` with the same name
after the shared antibot include in that OPAC virtual host. Difficulty is
in leading zero bits (1–24); challenge lifetime is 1–600 seconds and clearance
lifetime is 1–86400 seconds. The defaults above also apply when arguments are
omitted. `--key-file` selects a different protected key ring. Invalid policy
leaves the verifier unavailable. Reload Apache after changing policy or the key ring.
Retain the previous key only for the desired rotation window, then
remove it and reload again. Removing it invalidates its remaining tokens.

Use HTTPS. Trust the client address Apache exposes as `REMOTE_ADDR`;
behind a proxy, configure `mod_remoteip` with the actual trusted proxies.
Never make arbitrary forwarded headers authoritative. The verifier
does not consume `X-Forwarded-For`. Tokens bind the complete client IP
address and the configured Koha instance. Apache expands its existing
`${instance}` configuration variable; the client cannot select the
instance identifier through a Host or forwarded header. Changing IP requires new work,
including mobile/VPN address changes. User-Agent is not a binding.

The date prefix is the Apache server's local calendar date, matching the
verifier's inherited timezone. Servers must have synchronized clocks
and matching Apache/helper timezones. Clearances stop working at their
signed expiry or local midnight, whichever comes first. A challenge
that crosses midnight must be requested again. Keep this behavior in
mind when choosing a TTL.

Default policy is 16 leading zero bits, 120 seconds to solve and a
3600-second clearance. These are configurable starting values: validate
the intended difficulty on weaker clients and under representative
server load. Difficulty is authenticated and checked against the
server's current policy; a client-supplied smaller number is not trusted.

## Token protocol

The challenge has the form
`q1.DATE.EXPIRY.DIFFICULTY.SEED.KEYID.HMAC`. Clearance has the form
`c1.DATE.EXPIRY.DIFFICULTY.NONCE.KEYID.HMAC`. DATE has eight decimal digits, EXPIRY
ten decimal digits, DIFFICULTY two decimal digits, SEED/NONCE 32 lowercase
hexadecimal digits, KEYID 16 and HMAC 64. The key identifier is the first
16 digits of SHA-256 of the key; it selects one of at most two keys.

The HMAC is HMAC-SHA-256 of the ASCII prefix `koha-antibot`, a NUL, all
token fields before HMAC joined by dots, a NUL, the hexadecimal packed
client address, a NUL, and the lowercase instance identifier. The kind, version,
date, expiry, difficulty, random seed/nonce, key identifier and context
are therefore authenticated. Signature comparison uses the standard
`Mojo::Util::secure_compare` function with the expected value second.

The proof hashes the ASCII seed, a colon and a canonical unsigned
decimal counter between 0 and 4294967295. The server requires the
configured number of leading zero bits. It does not trust a hash sent
by the client. Clearance may be reused on the same address/site during
its validity. A solved challenge may also be submitted again while
valid; this stateless protocol does not claim one-time proof redemption.

After a successful solve the page sends `GET check`. Apache applies the
same duplicate, date, shape and verifier checks as a protected page and
answers 204 with `X-Koha-Clearance: ok` only when the browser returned a
valid cookie. Without it the page explains that cookies are required and
does not reload, so a browser that refuses the cookie cannot loop. The
readback stores nothing in the browser and never reaches Koha.

## Machine clients, caches and logs

API, ILS-DI, unAPI, sitemap, robots and well-known interfaces remain
outside the browser gate. GET/HEAD search requests with a single unambiguous
`format=rss` or `format=rss2` parameter are also excluded. A format parameter
on another page, duplicated format, encoded parameter name, semicolon query
separator or POST does not gain that exception. These interfaces can still consume resources and need
their own policy. Their exclusions are not a claim that their clients
are trustworthy. Keep existing emergency or application restrictions
separate when enabling this challenge.

Challenge issuance and solution responses are private and not cacheable.
Do not allow a shared cache to store the challenge document or a response
setting clearance. The helper logs event counts, never raw tokens,
cookies, keys, addresses, authorization, request URLs or query strings.
Counters are periodic and per helper; they are not a complete traffic
census. Apache rewrite trace logging can expose map keys, so do not
enable rewrite tracing in a live configuration carrying real tokens.

## Verifier deadline

The map helper gives its worker one second to return a complete answer.
If the worker misses the deadline or its connection fails, the helper
retires it and returns `NULL`. Lookups during the next five seconds fail
immediately. The next lookup after that pause can start a replacement
without an Apache reload. A worker that is still being reaped delays
replacement without delaying lookups. Challenge issuance returns 503
while verification is unavailable, and protected requests require valid
clearance throughout.

Apache itself has no timeout for a `prg` map. This deadline covers the
verification worker, including key loading and diagnostics. It bounds
the time the map mutex can be held waiting on that worker. Apache and its
map helper still need to be running, and other traffic shares the Apache
worker pool.

## Acceptance

### Threat model and limits

The untrusted party controls requests, cookies, proof counters and browser code.
The trusted boundary is Apache configuration, its resolved client address,
the verifier executable and the protected signing key. Forged metadata and
proofs must not reach Koha; modifying every token field and moving a token
between client/site contexts have negative controls. Input sizes are bounded
in both Apache and the line protocol. Installation publishes a complete key
file without replacing a concurrent or existing ring; unsafe files are refused.

This does not stop a bot that performs the work and then reuses its clearance.
Exempt machine interfaces need separate capacity controls. Access to the
Apache account or signing key compromises this gate; it is not a boundary
against a compromised web server. Each map starts at most one verification
worker. Disabled requests make no lookups. No throughput or weak-device
guarantee follows from the functional fixture tests.

### Verification

Run `prove -v t/Antibot.t t/AntibotHelper.t` for protocol, actual helper,
key preparation and unsafe-file behavior. Run `prove -v t/AntibotApache.t`
for an isolated loopback Apache with a synthetic backend and public fixture
key; it does not use an installed Koha or its database. Integration acceptance
must also use real Apache: instrument both verifier invocations and
backend requests, prove that cheap rejects touch neither, and show that
a valid-looking bad signature touches only the verifier. Then complete
a real browser challenge, reload with the issued cookie, and exercise
POST, aliases, adjacent public interfaces and helper failures. Repeat
the unchanged regression against the original implementation to show
that a fabricated cookie no longer opens the protected route.

Record the exact candidate revision, key rotation/rollover cases,
client difficulty measurements and reject/verify/issue capacity. A pure
protocol test alone does not establish deployment or upstream readiness.
