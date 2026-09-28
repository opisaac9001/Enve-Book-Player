# OPDS Progression

Enve implements **OPDS Progression 1.0, which is a draft specification** published by the OPDS community at
<https://drafts.opds.io/>. It is not a ratified standard, its registry error identifiers are provisional, and
the wire format may change before it is finalised. Everything in this document describes Enve's behaviour
against that draft as of 2026-09-19.

The feature is additive: an OPDS catalog that does not advertise a progression service behaves exactly as it
did before, with local-only progress.

## Auto-discovery

A progression service is announced per publication, in the publication's own links. Enve adopts a link only
when **all** of the following hold:

| Requirement | Reason |
|---|---|
| `rel` contains `http://opds-spec.org/progression` | The draft names one relation, compared case-insensitively as a URI. |
| `type` is `application/opds-progression+json` | The draft names one media type. Parameters such as `; charset=utf-8` are ignored; anything else, including an absent type, is refused. |
| The link is not templated | Enve has no variables to expand into a URI template. |
| The resolved URL is requestable | `http` or `https`, with a host, and never carrying its own `user:password@` userinfo. |

The service may sit on **another origin**. A catalog is entitled to delegate reading positions elsewhere, so
a cross-origin service is adopted rather than refused — and then talked to anonymously: `applyCredentials`
attaches the connection's bearer token and custom headers only on the feed's own origin, and the session
delegate answers a Basic or Digest challenge only there. A redirect is not followed at all when it leaves
`https` for `http`, names a scheme Enve does not speak, or carries userinfo.

`properties.authenticate` is resolved against the document that carried the link, kept alongside the adopted
service, and used to name the OPDS Authentication Document if the service later answers `401`. Enve does not
yet perform the authentication flow that document describes; it signs in with the credentials already
configured on the connection, which means a cross-origin service is reachable only if it is open or later
authenticated separately.

Both feed dialects are covered: OPDS 2.0 reads the link from `publications[].links`, OPDS 1.x from the
Atom `<entry>`'s `<link>` elements. The `authenticate` hint exists only in the OPDS 2.0 `properties` object,
which is the only form the draft defines.

Discovery happens during catalog import and is persisted by `OPDSProgressionEndpointStore`, keyed by book
stable ID, because progress sync runs long after the snapshot has been reduced to `Book` records. A
**complete** catalog snapshot also retires services it no longer sees; a partial one may only add, matching
the rule that a partial snapshot never deletes.

## Transport

`OPDSProgressionTransport` holds the wire rules as pure functions so the status and payload contract is
testable without a network. `OPDSProvider` performs the request through the same origin-scoped credential
path as every other OPDS call, and drops every credential header on a cross-origin redirect.

| Interaction | Status | Meaning |
|---|---|---|
| `GET` | `200` with a Progression Document | The service's last-known point. |
| `GET` | `200` with an empty payload | No position has ever been recorded for this publication. |
| `GET` / `PUT` | `200` with anything else | A protocol violation. Enve reports a malformed payload rather than reading it as "no position", which would be indistinguishable from a reader who has not started the book. |
| `PUT` | `200` or `201` | The document the service settled on. The draft requires a body on both, so an empty one is a protocol violation. |
| any | `401` | Unauthorized. The payload is an OPDS Authentication Document, which Enve does not consume; the `authenticate` hint, if the feed gave one, names it in the error. |
| `PUT` | `409` | `https://registry.opds.io/error#progression-date` — the service already holds a more recent point. |
| `PUT` | `400` / `403` | `progression-invalid-payload`, `progression-incorrect-user` or `progression-locked`. |
| any | anything else | Reported with its RFC 7807 `type` and `title` when the payload carries them, and by status code when it does not. |

Only the codes the draft lists as success are treated as success. A `204`, for example, is reported as an
unexpected status rather than silently read as an empty `GET`.

A successful response with a body must also *declare* itself correctly when it declares anything at all:
`application/opds-progression+json`, with parameters such as `; charset=utf-8` ignored. Any other declared
type is a malformed payload, because a body that happens to parse is still not a progression when the
service said it was a generic error object. A response that declares no type is judged by its payload alone,
and an empty `200` on `GET` stays "no position recorded" whatever it declares.

Decoding holds to exactly what `progression.schema.json` requires — `modified`, `device` and `progression`,
a non-empty device name, and a progression inside `0...1` — plus the two members the schema types as URIs:
`device.id` must be an RFC 3986 URI with a scheme, and every entry of `references` a URI reference. A
relative path (`chapter1.html`) and a fragment-only reference (`#par36`) are both valid; whitespace, control
characters, malformed percent escapes and the ASCII characters outside the grammar are not. Non-ASCII
characters are accepted as RFC 3987 allows, because catalogs write an accented path far more often than they
percent-encode one. Members the draft does not define are ignored.

## Device identity

`OPDSProgressionDeviceIdentity` sends `urn:uuid:<uuid>` built from the installation's own persisted device
UUID rather than `identifierForVendor`, which changes when the last Enve app is removed from the device. A
progression service uses the identifier to tell this reader apart from the user's others, so it has to
survive as long as the library does. The display name is `Enve (<device name>)`.

## References

The draft defines `references` as an ordered array of URI references that *refine* `progression`, and gives
clients one rule: prefer a specific reference over a generic one, and always fall back to `progression` when
none of them resolve. Enve's mapping is:

| Reference | Enve position |
|---|---|
| `#t=<seconds>` (Media Fragment URI 1.0 temporal) | Audiobook playback time. `npt:` and `hh:mm:ss.ms` are resolved; `smpte` and `clock` are not. |
| `<path>#:~:text=<directive>` (Scroll to Text Fragment) | Readium locator `text.highlight`, from the directive's start term. |
| `<path>#<id>` (HTML) | Readium locator `locations.fragments`. |
| `<path>` | Readium locator `href`. |
| `#page=<n>` (RFC 8118) | PDF page, one-based on the wire and zero-based in Enve's locator. Applied only when the book really is a PDF. |
| `#epubcfi(<cfi>)` | Readium locator `locations.cfi`. The draft does not define this fragment, so Enve carries it as an opaque additional reference. |
| anything else | Preserved verbatim and ignored for positioning. |

Enve writes them most specific first:

```
#t=40.274
chapter1.html#:~:text=It%20was%20expected
chapter1.html#par36
#page=6
#epubcfi(/6/4[chap01]!/4/2/2)
<references Enve did not produce, in the order the service wrote them>
```

A locator href that is not already a URI reference — a filename with a space in it — is percent-encoded
before it is written, because a reference Enve's own decoding would refuse is not one to send.

Nothing is discarded on either side. A `Progression Document` holds `references` exactly as the service wrote
it, so a document that is decoded and re-encoded is unchanged; `OPDSProgressionPoint` is the resolved view of
that array, and every reference it could not resolve — an unknown fragment, a second reference of a kind it
already has, a fragment with no resource to apply it to — is kept and written back at the tail.

Those unresolved references outlive the request. `OPDSProgressionEndpointStore` holds them per book stable
ID, taken from the newest document the service produced — a `GET`, or the document a `PUT` settled on, which
is authoritative — and persists them, so an app restart does not strip them. Every push composes its
document through `OPDSProvider.progressionDocument(for:title:point:progression:)`, which merges them back in
after the references Enve regenerated, for an audiobook exactly as for an ebook. A held reference is dropped
from that merge when the new point already expresses its kind: a `#t=` from an earlier document must not
ride alongside the current position, and an identical reference is never written twice. They are pruned with
the endpoints — a complete snapshot that retires a service, a connection that goes away, and a library reset
all take the references with them.

A server-supplied CFI never carries Enve's `enveSourceEngine` marker, so conflict resolution does not treat
it as authoritative. It still travels with the locator for the reader to use.

## Conflict handling

The draft describes one server-side rule (`409`) and leaves the rest to the client, so
`OPDSProgressionSyncStrategy` resolves direction the way every other Enve backend does, through
`ProgressConflictResolver`:

- The newer `modified` timestamp wins. Enve stamps a push with the time the position was observed locally,
  not the time of the request, so "newer" means something across devices.
- A `409` on push is the service saying it already holds a newer point. Enve re-fetches and adopts it rather
  than losing the round.
- A newer server point that would move the reader **backwards** is not applied. It is recorded in
  `EbookConflictStore` and the reader asks before jumping, which is the draft's own advice for a `GET` that
  returns something more recent than the client has.
- The book currently playing is skipped entirely, as are books with a queued local write and books that
  already have an unanswered conflict. No active session is ever moved underneath the user.

## What does not map

- **Comics.** The draft's example for a CBZ is a resource path (`page78.jxl`), and Enve's comic locator is a
  page index with no entry name to write. Comic progress therefore travels as `progression` alone.
- **Read-aloud.** A read-aloud locator addresses an audio timeline rather than a resource inside the
  publication, so it produces no reference and falls back to `progression`.
- **Finished state.** The draft models a position, not a read state. Enve treats a progression of `0.99` or
  more as finished on read, and writes a finished audiobook as `progression: 1` with no refining reference.
- **Audiobooks with no known duration.** There is no way to express a valid `0...1` progression, so nothing
  is pushed and `pushPlaybackProgression` returns `false`. The sync strategy has to be told: counting a
  skipped push as a completed one records an outbound write the service never saw, and the next pull would
  read another device's move as Enve's own echo.
- **OPDS Authentication Documents.** Enve reads the `authenticate` hint but does not run the flow.

## Where the code lives

| Path | Responsibility |
|---|---|
| `enve/Services/OPDS/OPDSProgressionDocument.swift` | Progression Document, Device Object, RFC 7807 payload |
| `enve/Services/OPDS/OPDSProgressionReference.swift` | RFC 3986 validation, reference classification, ordered lossless generation |
| `enve/Services/OPDS/OPDSProgressionTransport.swift` | Auto-discovery and the status/payload contract |
| `enve/Services/OPDS/OPDSProgressionMapping.swift` | Enve locator and playback time to and from a point |
| `enve/Services/OPDS/OPDSProgressionDeviceIdentity.swift` | Stable device identity |
| `enve/Services/OPDS/OPDSProgressionEndpointStore.swift` | Which publications advertise a service, and the references held for each |
| `enve/Services/Sync/OPDSProgressionSyncStrategy.swift` | Batch reconciliation |
| `enve/Networking/Providers/OPDSProvider.swift` | Discovery during import and the progress capabilities |
