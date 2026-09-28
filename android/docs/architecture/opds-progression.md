# OPDS Progression 1.0 (draft)

The app reads and writes reading/listening position against an **OPDS Progression 1.0 _draft_** service.

The specification is a community draft published at <https://drafts.opds.io/> and is not a ratified
standard. It can still change. Everything below describes what this app implements against the
draft as of the version dated in the draft's own repository; where the draft leaves behaviour
undefined, the choice this app made is called out explicitly.

## Discovery

A progression service is tied to a single publication and is found on that publication's links. A
link only counts when **both** of these match:

- `rel` contains `http://opds-spec.org/progression`
- `type` is `application/opds-progression+json` (media-type parameters such as `; charset=utf-8`
  are ignored, the comparison is case-insensitive)

Both catalog syntaxes are supported:

- **OPDS 1.x** — an Atom `<link>` inside the publication `<entry>`
- **OPDS 2.0** — an entry in the publication's `links` array, with `rel` as either a string or an
  array of strings

`OpdsFeedParser` resolves the `href` against the feed's base URL and records it on
`OpdsPublication.progressionUrl` and on `BookSummary.opdsProgressionUrl`.

The draft's optional `properties.authenticate` hint is resolved against the feed's base URL and kept
on `OpdsPublication.progressionAuthenticateUrl`. Atom links have no `properties`, so an OPDS 1.x
publication that carries a progression service takes its hint from the nearest
`rel="http://opds-spec.org/auth/document"` link — the entry's own if it has one, otherwise the
feed's. A publication with no progression service records no hint. It is persisted per book in
`opds_progression_state.authenticateUrl` as the feed is crawled, and it is what a `401` from the
progression service turns into a sign-in prompt: the service publishes
`OpdsProgressionAuthenticationPrompt` on `authenticationPrompt`, the catalog facade resolves the hint
into an OPDS Authentication Document, and the UI offers the flows described in
[opds-catalog.md](opds-catalog.md). Until the user signs in, the sync is still skipped.

## Persistence

`opdsProgressionUrl` is threaded through `BookSummary` → `Book` → `CachedBook` and stored in the
`book_cache` Room table. It is added by `MIGRATION_24_25`, alongside `opdsAcquisitionUrl`.

`MIGRATION_24_25` also creates `opds_progression_state`, the per-book table that carries references
this app cannot rebuild (see *References* below). It is deliberately **not** a `book_cache` column:
`BookCacheDao.upsert` uses `OnConflictStrategy.REPLACE`, so a library refresh rebuilds those rows
from the feed and would erase anything the feed does not carry. A separate table survives the
refresh.

`MIGRATION_24_25` had not shipped when the progression column and the state table were added, so
both were folded into that same migration rather than a new version. The `ALTER TABLE` statements
are guarded by a `PRAGMA table_info` check and the table goes through `ensureTable`, so the
migration is safe to re-run and safe on a database that only got part of it. A development device
that already ran an earlier form of v25 is at schema version 25 with the old shape and Room will not
re-run the migration for it — clear app data on those devices.

`MIGRATION_25_26` adds `opds_progression_state.authenticateUrl` and
`opds_progression_state.additionalMembers` with guarded `ALTER TABLE`s, and creates the
`opds_acquisition` side table. It touches no existing row.

Both OPDS migrations go through `ensureTableAdditive` rather than the older destructive `ensureTable`
(which drops a table whose columns do not match). A table that already exists keeps its rows and
gains only the columns it is missing, and the indices are re-declared with `CREATE INDEX IF NOT
EXISTS` on every run, so an index dropped or never created on a half-migrated database is restored
without losing a single acquisition or carried reference.

## Transport

`OpdsProgressionClient` is strict about the status codes the draft defines.

| Verb | Status | Payload | Result |
| --- | --- | --- | --- |
| `GET` | `200` | Progression Document | `Document` |
| `GET` | `200` | empty | `Empty` (nothing recorded yet) |
| `GET` | `200` | unparseable | `Failure(200, null)` |
| `GET` | `401` | OPDS Authentication Document | `Unauthorized` |
| `GET` | other | Problem Details (RFC 7807) | `Failure(status, problem?)` |
| `PUT` | `200` / `201` | Progression Document | `Document` |
| `PUT` | `200` / `201` | empty or unparseable | `Failure(status, null)` |
| `PUT` | `409` | Problem Details | `Conflict(problem?)` |
| `PUT` | `401` | OPDS Authentication Document | `Unauthorized` |
| `PUT` | other | Problem Details | `Failure(status, problem?)` |

Requests send `Accept: application/opds-progression+json`; `PUT` bodies are sent with that media
type as `Content-Type`.

A Problem Details object is only accepted when it carries both `type` and `title`, as the draft
requires; anything else is reported as a failure with no problem attached.

The draft requires a Progression Document in a `200`/`201` `PUT` response, so that is enforced: a
server that answers a write with an empty or unparseable body is a `Failure`, never a successful
write. `Empty` is a `GET`-only outcome and means "nothing recorded yet". The returned document is
authoritative — the references it carries replace what was stored for that book.

When a successful response carries a payload and declares a `Content-Type`, that type must be
`application/opds-progression+json`; media-type parameters (`; charset=utf-8`) are ignored and the
comparison is case-insensitive. A conflicting declared type is a `Failure` even when the body would
parse. A response with no `Content-Type` is accepted on its body alone, and an empty `200` `GET`
stays valid whatever it declares.

Documents are validated against the draft's JSON Schema before they are accepted: `modified` must
be an ISO 8601 instant with an offset, `device.name` must be present and non-empty, `device.id`
must be an RFC 3986 URI (scheme included), `progression` must be a JSON number between 0 and 1
inclusive, and `references` — when present — must be an array of RFC 3986 URI-references. Relative
paths and fragment-only references are URI-references and are accepted; whitespace, control
characters, non-ASCII and malformed percent escapes (`%zz`, a truncated `%4`) are not. Anything else
is rejected rather than partially applied.

## Credentials and origin

The progression service URL must be `http`/`https`, must parse, must carry no userinfo
(`https://user:pass@host/…` is rejected) and must pass the same URI-reference character rules as a
reference. A cross-origin service — a different scheme, host or port from the connection's server
URL — is **not** rejected; the draft allows one, and a catalog that hosts its progression service on
a sibling host is legitimate.

What changes cross-origin is the client. `opdsProgressionEndpoint` classifies every service URL into
one of three transports, and `OpdsProgressionClient` picks the matching Retrofit API:

| Transport | When | Client |
| --- | --- | --- |
| `SCOPED` | same origin as the connection's server URL | the shared `OkHttpClient`, inside `ConnectionScope.asContextElement(connectionId)`, so `AuthInterceptor` signs the request |
| `PRIVATE_NETWORK` | a different origin whose host is loopback, RFC 1918, CGNAT, link-local, IPv6 ULA, a single label, or a `.local` / `.lan` / `.home` / `.internal` / `.localdomain` name | `privateNetworkProgressionClient(shared)` |
| `PUBLIC_NETWORK` | anything else | `publicNetworkProgressionClient()` |

`privateNetworkProgressionClient(shared)` is derived from the shared client with `newBuilder()` —
every application and network interceptor cleared, `Authenticator.NONE` installed, the shared
response cache dropped and `CookieJar.NO_COOKIES` set — so no bearer token, custom header,
Cloudflare Access secret, cookie or `401` re-auth can follow a link into a host the user never
configured. Deriving from the shared client rather than building a fresh one is what keeps the TLS
stack: `PrivateNetworkTrust`'s trust manager and hostname verifier and the `MtlsManager` key manager
all carry over, so a LAN service with a self-signed certificate or a client certificate still works.

`publicNetworkProgressionClient()` is built from scratch instead, so a public host on the far side of
a progression link gets the platform's own TLS: **no relaxed trust manager, no relaxed hostname
verifier, and no chance to ask the user's mTLS client certificate for a handshake.** A permissive
trust stack exists for the LAN the user configured; handing it — or the client certificate that
identifies them — to `progression.attacker.example` because a feed said so is not something a link
in a catalog gets to do. Host classification fails closed: a host this app cannot prove is private
is treated as public.

A cross-origin service will therefore usually answer `401`. That is reported as `Unauthorized` and
the sync is skipped; the authenticate hint recorded at parse time is what the sign-in prompt
described in [opds-catalog.md](opds-catalog.md) resolves.

## Device identity

`DeviceIdentity.deviceUri` is a stable, per-install `urn:uuid:` URI, generated once and kept in the
app's private `enve_device` preferences. `DeviceIdentity.deviceName` supplies the human-readable
name and can never be blank, which is what the schema's `minLength: 1` requires. The URI is separate
from the existing `deviceId` because the KOReader sinks depend on that value's exact format.

## References

`references` is an ordered list of URI references that refines the numeric `progression`. Each one
is parsed into an `OpdsProgressionReference` that keeps the original string in `raw`, so an
unrecognised reference survives a parse/encode round trip in its original position. Unknown
top-level members of the document round-trip the same way, and — like the unknown references — they
are stored per book in `opds_progression_state.additionalMembers` and re-emitted on the next push,
because this app writes a new document every time rather than editing the server's.

A parse/encode round trip is not enough on its own: this app writes a *new* document on every push,
built from the local anchor, so anything it cannot rebuild would be dropped. Every reference whose
fragment this app does not recognise (`OpdsProgressionTarget.Unknown` — `#xywh=…`, a vendor
fragment) is therefore stored per book in `opds_progression_state` on every fetch and on every
authoritative `PUT` response, in the order the server sent it. The next push emits the references it
generates and then appends the stored ones, skipping any the generated set already contains. A
document with no unknown references clears the row, so a server that drops one does not have it
pushed back.

Recognised-but-not-generated references are *not* carried: a stale `#t=` or a stale resource path
describes the previous position, and re-sending it alongside the new one would be wrong.

Recognised fragment forms:

| Form | Example | Target |
| --- | --- | --- |
| Media Fragments time | `#t=849.250`, `#t=npt:00:01:30`, `#t=10,20` | `Time(seconds)` |
| PDF page (RFC 8118) | `#page=87` | `Page(page)` |
| Scroll to Text Fragment | `chapter1.html#:~:text=It%20was%20expected` | `Text(directive)` |
| EPUB CFI | `chapter1.html#epubcfi(...)` | `Cfi(cfi)` |
| HTML id | `chapter1.html#par36` | `Id(id)` |
| no fragment | `chapter5.html` | `Resource` |
| anything else | `cover.jpg#xywh=160,120,320,240` | `Unknown(fragment)` |

EPUB CFI is not one of the fragment syntaxes the draft lists. It is carried as an **additional**,
opaque reference: the CFI body is percent-encoded inside `epubcfi(...)` and decoded back verbatim on
read, so a client that does not understand it can ignore it while still resolving the other
references.

When writing, references are emitted in this order:

1. the audio media fragment (`#t=`), for non-ebook media with a known position
2. one resource-scoped reference — the scroll-to-text fragment if the reader gave a text quote,
   otherwise the HTML id, otherwise the bare resource path
3. the PDF/comic page (`#page=`), from the reader's page argument or from a saved `{"page":N}` locator
4. the EPUB CFI
5. the stored unknown references, in the order the server last sent them

When reading, each kind is looked up by kind rather than by position, and **anything that cannot be
resolved falls back to the numeric `progression`** — that is the draft's own recommendation.
For audio the fallback is `progression × duration`.

## Merge policy

`OpdsProviderAdapter` declares `SyncCapability.READ_WRITE`, so the shared machinery drives the
per-book path: `SyncCoordinator` pulls on open and pushes on a debounce, and a pull that disagrees
with local state goes through the existing conflict prompt.

`OpdsProgressionSyncStrategy` is the batch path registered with `RecentlyPlayedSyncService`. It
walks the in-progress books of every enabled OPDS connection that has a progression service, and
for each one:

- **newer wins** — `ProgressResolutionPolicy` compares timestamps with a 1s skew allowance; a
  genuine disagreement between two recent writes resolves to nothing here and is left for the
  open-time prompt
- **the book that is playing is never moved** — a pull is suppressed while
  `AudioPlaybackManager.currentBookId` is the book being reconciled. This is the real session, not a
  guess from timestamps: a cache write during playback would be picked up the next time the player
  resolves its start position and would move a listener mid-chapter. The newer remote point is
  applied on the next sweep once playback moves on
- **an open ebook reader needs no gate** — `EbookReaderActivity` takes its locator from the launch
  intent and never observes `book_cache`, so writing progress there cannot move a reader that is
  already open; the row is simply overwritten by the reader's own next save. There is no reader
  session hook to consult, so the compare-before-apply in `ProgressResolutionPolicy` is the only
  guard an ebook needs
- a `409` on push means the server already has a more recent point, so the strategy re-fetches and
  applies it under the same rules instead of retrying the write

The strategy asks for candidates **per connection**, through
`BookCacheDao.getInProgressWithProgressionService`, which filters on source, connection and a
non-empty progression URL inside the query. Reading a shared in-progress list and filtering it
afterwards would let a user's other libraries consume the row budget and starve OPDS books that are
genuinely in progress.

On the per-book path a `409` is **not** a successful write. `OpdsProviderAdapter` raises
`OpdsProgressionSupersededException`, so `SyncCoordinator` leaves `remoteWritten` false and records
no outbound write. Swallowing it would make the rewind tracker treat the server's newer point as this
device's own echo and ignore it on the next pull.

## Files

- `engine/src/main/java/com/enve/app/data/opds/OpdsProgression.kt` — document, references, codec,
  URI validation, reference merge
- `engine/src/main/java/com/enve/app/data/opds/OpdsProgressionClient.kt` — Retrofit API, transport,
  the credential-free cross-origin clients
- `engine/src/main/java/com/enve/app/data/opds/OpdsProgressionService.kt` — endpoint resolution,
  origin classification, snapshot/locator mapping
- `engine/src/main/java/com/enve/app/data/opds/OpdsProgressionState.kt` — per-book store for the
  references this app cannot rebuild
- `engine/src/main/java/com/enve/app/data/opds/OpdsProgressionSyncStrategy.kt` — batch sweep
- `engine/src/main/java/com/enve/app/data/repository/OpdsFeedParser.kt` — discovery

Everything else the app does with an OPDS catalog — crawl, search, acquisition and OPDS
Authentication 1.0 — is in [opds-catalog.md](opds-catalog.md).
