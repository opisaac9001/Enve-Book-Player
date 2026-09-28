# Provider Capability Matrix

**Source of truth:** each provider's protocol conformances plus its `var capabilities: ProviderCapabilities` override under `Networking/Providers/`.

This document must match those overrides exactly. Update the table whenever a provider's capabilities change.

`LibraryProvider` is the catalog identity. Optional behavior is exposed through narrow protocols such as
`PlaybackSessionProvider`, `AudiobookProgressPulling`, `AudiobookProgressPushing`, `EbookProgressPulling`,
`EbookProgressPushing`, `EbookDownloadProvider`, `ServerPageProvider`, and `PersonalRatingProvider`. Feature code
must resolve the protocol it needs. The flags describe runtime support within that typed capability; they do not
make an unsupported provider conform.

## Support envelope

The app **supports libraries up to hundreds of thousands of books per provider** — it does not impose an artificial library-size cap.

- **Performance SLOs** (cold launch < 3 s, first page < 1 s, search < 300 ms, browse warm < 1 s, import incremental memory < 350 MB) are **calibrated at 50,000 books per library**. Beyond 50k the app should still function correctly, but those numbers aren't promised.
- **Structural ceilings** on the import path are deliberately set far above any realistic library so they act as *runaway-detection guards*, not truncation caps:

  | Provider | Ceiling | At default page size |
  |---|---|---|
  | Komga          | 5,000 page iterations  | 500,000 books (also tightened to server-reported `totalPages` after first page) |
  | Kavita         | 5,000 page iterations  | 500,000 books |
  | Jellyfin       | 5,000 page iterations  | 2,500,000 items (also tightened to server-reported `TotalRecordCount`) |
  | Emby           | 5,000 page iterations  | 2,500,000 items |
  | Plex (albums)  | 2,000 page iterations  | 1,000,000 albums |
  | Plex (track fallback) | 10,000 page iterations | 2,000,000 tracks (~200k books at 10 tracks each) |
  | Audiobookshelf | 2,000 page iterations  | 1,000,000 books (`fetchBookBatches` bypasses this path) |
  | OPDS           | 2,000 `next` pages per feed, 5,000 feed requests per import, 200 navigation links per feed, 10 levels of navigation depth | Pagination and navigation are separate budgets, so a long paginated feed never exhausts traversal depth. Hitting any of them marks the catalog snapshot **incomplete**, which stops reconciliation from deleting the books it did not reach. |
  | BookOrbit      | 251 server-imposed     | **~50,200 books** (server-side hard cap: `page ≤ 250`, `size ≤ 200`). Books past this are unreachable in the current BookOrbit API; sort and filter are also unavailable so there is no workaround. Surfaced as an error log when hit. |

  If a ceiling is hit, the provider logs an error explicitly mentioning the *runaway guard* — not silent truncation. If you see such a log at a real library size below the table value, the server is reporting an inconsistent total / last-page signal — that's the bug to chase, not the ceiling.

## Flags

| Flag | Meaning |
|---|---|
| `fullImport` | `fetchBooks(libraryId:)` returns the entire library (possibly via internal paging). |
| `pagedImport` | `fetchBooks` uses server-side pagination (StartIndex/Limit, page+size, cursor). Required for 50k+ libraries. |
| `streamingImport` | Provider yields pages incrementally so the importer never holds the whole library. |
| `deltaImport` | Overrides `fetchBooksDelta(libraryId:since:)` for incremental sync since a cursor. |
| `recentBooks` | `fetchRecentBooks` hits a real "recently added" endpoint (not just a slice of `fetchBooks`). |
| `series` | `fetchSeries` returns server-defined series. |
| `collections` | `fetchCollections` returns server-defined collections. |
| `audiobookProgressPull` / `Push` | `fetchAudiobookProgress` / `updatePlaybackProgress` round-trip with the server. |
| `ebookProgressPull` / `Push` | `fetchEbookProgress` / `updateEbookProgress` round-trip with the server. |
| `downloads` | Provider can deliver a downloadable file or playable stream for offline use (`downloadEbook` and/or `getAudioURL`). |
| `coverAuthHeader` | Cover URLs require `Authorization` / custom-header auth. |
| `coverAuthQuery` | Cover URLs carry the auth token in the query string (necessary for `AsyncImage` / AVPlayer, which don't reliably forward custom headers). |
| `serverPageStreaming` | Provider exposes `fetchPageCount` + `fetchPage` for per-page comic streaming. Replaces the legacy `supportsServerPageStreaming` bool. |
| `backgroundOperation` | Provider's downloads / sync are safe under app suspension (background `URLSession`, server-friendly retry). |

## Matrix

Legend: ✓ supported, ✗ not supported, ⚠ partial / capped (note in §3 below).

| Provider | full | paged | stream | delta | recent | series | coll. | absPull | absPush | epubPull | epubPush | dl | covH | covQ | pgStream | bg |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Audiobookshelf | ✓ | ⚠¹ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✓ |
| Plex            | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ |
| Jellyfin        | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Emby            | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Komga           | ✓ | ⚠¹ | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ |
| Kavita          | ✓ | ⚠¹ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Booklore        | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| BookOrbit       | ✓ | ✓ | ✗ | ✗ | ✗³ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Silo            | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| OPDS            | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ⚠⁴ | ⚠⁴ | ⚠⁴ | ⚠⁴ | ✓ | ✗ | ✗ | ✗ | ✓ |
| Storyteller     | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| WebDAV          | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |
| OneDrive        | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ |
| Premiumize      | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |
| RealDebrid      | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |

Columns: **full** = fullImport, **paged** = pagedImport, **stream** = streamingImport, **delta** = deltaImport, **recent** = recentBooks, **series** = series, **coll.** = collections, **absPull/Push** = audiobookProgressPull/Push, **epubPull/Push** = ebookProgressPull/Push, **dl** = downloads, **covH** = coverAuthHeader, **covQ** = coverAuthQuery, **pgStream** = serverPageStreaming, **bg** = backgroundOperation.

## Footnotes

**¹ Paged with a runaway guard.** These providers stop when they reach their configured maximum page count and log the condition instead of silently truncating.

**³ No recent-books endpoint.** BookOrbit's API silently ignores every `sort` variant on `POST /libraries/{id}/books` and has no dedicated "recently added" endpoint. `fetchRecentBooks` is implemented as a best-effort "last page" fallback (highest IDs = most recently imported) and the capability flag is honestly ✗.

**⁴ Per-publication, and against a draft.** OPDS progress sync exists only for publications whose feed entry advertises an [OPDS Progression 1.0 **draft**](opds-progression.md) service on the connection's own origin; every other publication stays local-only and the provider answers `nil` without a request. The draft has no mark-finished operation, so `SyncCapability` for OPDS is `[.pullProgress, .pushProgress]` and a progression of 0.99 or more is what "finished" means.

## Per-provider notes

- **Audiobookshelf** — reference provider for streaming through `fetchBookBatches`. Cover auth uses a `?token=` query item. Ebook updates submit `ebookProgress` without audio time or duration fields. Audio updates include the full book duration and omit `isFinished: false` for nonzero playback positions because ABS otherwise resets the position when reopening a finished item. ABS creates one record per item and defaults an untouched side to zero, so for an item with both audio and an ebook a record without `ebookLocation` or a positive `ebookProgress` has no ebook position, and one without `currentTime`, `progress`, or `isFinished` has no audio position; neither side is ever pulled from an empty record.
- **Plex** — paged via `X-Plex-Container-Start/Size`. Series and collections are inferred from paths. Progress pushes use `:/timeline`; progress pulls combine track offsets into the book timeline.
- **Jellyfin** / **Emby** — server-paged via `StartIndex` / `Limit`. Cover URLs require `X-Emby-Token` headers and must use the authenticated cover loader. Audio positions are saved through user-data updates. Neither provider advertises native ebook-position sync: Jellyfin accepts but does not persist `PlayedPercentage` for ebooks. Ebook download/reading remains available.
- **Komga** — comic-server: only provider with `serverPageStreaming` today. Delta uses `sort=created,desc`. Cover URL uses HTTP Basic — fine for the iOS `URLSession` cover loader but not for `AsyncImage` without a header rewrite.
- **Kavita** — POST requests use one-based query pagination and a library-filter statement in the JSON body. JWT cover auth via Bearer header. No series exposed (returns `[]`). Ebook progress uses the same first chapter as the downloaded ebook and the native Reader progress endpoints.
- **Booklore** — three-tier (app-tier `/api/v1/app/*`, legacy REST `/api/v1/rest/*`, Komga fallback). Carries both header and query auth for covers. Full progress matrix.
- **BookOrbit** — JWT (15-min access / 7-day refresh httpOnly cookie). Header-only auth. Catalog import stays pagination-only for compatibility with releases that reject `filter`/`sort`; activity sync behaviorally probes the newer paginated `readStatus` filter and falls back to the bounded dashboard endpoint when unavailable. Collections support complete definition and membership snapshots. No universally available sort or recent-books endpoint exists across supported releases.
- **Silo** — profile-scoped API with snapshot-fenced catalog pagination and cursor-based progress sync. Ebook resets and rereads clear the server’s latched watched state before applying a new position. Collections include complete personal/manual/smart definitions and memberships plus visible server library collections.
- **OPDS** — read-only feed (Atom 1.x + OPDS 2.0 JSON); see [OPDS catalog](opds-catalog.md) for the browsable surface and [OPDS Authentication](opds-authentication.md) for sign-in. Pagination (`next`) and navigation depth are separate budgets sharing one cycle-detection set; any truncation, undecodable entry, or dead sub-feed marks the snapshot incomplete instead of shrinking it. Every fetched document is validated before it counts: a non-feed content type, a body that is not well-formed XML rooted at `<feed>`/`<entry>`, or JSON that is not a recognizable OPDS 2 document is an error, so a 200 carrying a login page or an API error object can never reconcile the library down to nothing. A bad root fails the import; a bad page or branch only marks the snapshot partial. Acquisition selection honours OPDS 2 short relations: only `open-access` and plain `acquisition` are treated as downloads, while `preview`/`sample`, `buy`, `borrow` and `subscribe` are recorded as rejected content with the price, copy and hold counts the feed reported. LCP and Adobe-protected links, and webpub/DiViNa/Readium-audiobook packages, are recognised and refused rather than downloaded. Auth via challenge-response delegate (Basic/Digest/Bearer) plus custom headers and OPDS Authentication 1.0 bearer tokens, all scoped to the configured feed origin and stripped on cross-origin redirects; a redirect that downgrades `https`, changes scheme or carries userinfo is refused outright. An acquisition that answers with an OPDS entry or publication document is followed as an indirect-acquisition hop rather than written to disk. Imported books are stamped with the catalog's own `metadata.modified`/`<updated>`, or `distantPast` when the entry dates nothing, so a catalog refresh never overwrites the reader's progress. Publication identity prefers `metadata.identifier`, then the `self` link, so expiring acquisition URLs do not churn book IDs. Series and collection membership *is* read per publication — `metadata.belongsTo.series`/`collection` in OPDS 2, `schema:Series` in Atom — and stored on the book; what OPDS has no resource for is a standalone series or collection listing, so `fetchSeries`/`fetchCollections` return `[]` and the **series**/**coll.** flags stay ✗. An audio acquisition becomes an audiobook: a single direct audio file on the feed origin streams and downloads, while Readium audiobook packages and manifests remain refused rather than faked. Progress sync is per publication and follows the [OPDS Progression 1.0 draft](opds-progression.md): a publication whose entry advertises `http://opds-spec.org/progression` with type `application/opds-progression+json`, not templated, on the connection's own origin, gets a `GET`/`PUT` progression service; every other publication stays local-only.
- **OneDrive** — read-only Microsoft Graph integration using delegated `Files.Read`. Users select one or more folders as Enve libraries; Enve recursively imports supported audiobook and ebook files, refreshes short-lived download URLs when playback or download begins, and keeps progress locally (with the app's normal iCloud sync when enabled). Graph has no Enve progress endpoint, so OneDrive intentionally advertises no progress capability. See [OneDrive setup and behavior](../reference/onedrive.md).
- **Storyteller** — covers carry both Bearer header AND a `?w=` query sizing token. Full progress matrix incl. read-aloud (EPUB3 SMIL).
- **WebDAV** — file-system enumeration via PROPFIND. No progress, covers, series, or collections. Directory traversal is not currently depth-bounded.
- **Premiumize** / **RealDebrid** — premium-link / debrid services. Aggregates account file listings; identifies audiobooks by extension. No progress, series, collections, or covers.

## Maintenance

1. Add or remove the matching provider protocol conformance and edit `var capabilities: ProviderCapabilities { ... }` in the provider's `.swift` file.
2. Update the row in §"Matrix" above in the **same commit**.
3. If a footnote (¹ ² etc.) is no longer accurate, remove it from the table and §"Footnotes".
4. Cross-check against the per-provider notes in §"Per-provider notes" — those describe *why* the flags are what they are; if your change invalidates a note, edit it.

The capability surface is intentionally honest: a missing flag (✗) signals real work to do, not a TODO to be silenced by adding it.

## Progress refresh

Audiobookshelf reconciliation is scoped to its connection and processes the returned progress records, including completed and reset items. Jellyfin, Emby, Plex and Kavita use their native provider progress capabilities; they never receive Audiobookshelf requests. Manual refresh visits all indexed books for those connections, while startup limits per-book requests to 40 recent local books. Providers without a batch progress endpoint require per-book requests, so manual reconciliation can take longer on large libraries.

Booklore, BookOrbit, Komga, Silo and Storyteller retain their dedicated strategies. Manual Booklore and Silo ebook refresh is no longer limited to a recent window or a cross-connection candidate cap. Provider strategy failures propagate to the refresh result. Pending local writes are protected during reconciliation.

Emby ebooks and file-only sources do not advertise service progress sync. Emby audiobook progress is supported. WebDAV, debrid and local files have no native service progress endpoint; their Enve/iCloud progress is separate. OPDS has one only where the feed advertises a progression service per publication, reconciled by `OPDSProgressionSyncStrategy` against the newer timestamp; a `409` is answered by adopting the service's point, and a point that would move a reader backwards is surfaced to the reader instead of applied. Booklore legacy REST and Komga fallback tiers report unsupported ebook uploads instead of reporting a successful write.

Komga resets use its documented [mark book as unread](https://komga.org/docs/openapi/delete-book-read-progress/) endpoint rather than writing page one.
