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
| Audiobookshelf | ✓ | ⚠¹ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ |
| Plex            | ✓ | ✓ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✓ |
| Jellyfin        | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Emby            | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Komga           | ✓ | ⚠¹ | ✗ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ |
| Kavita          | ✓ | ⚠¹ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Booklore        | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| BookOrbit       | ✓ | ✓ | ✗ | ✗ | ✗³ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| Silo            | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✓ |
| OPDS            | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |
| Storyteller     | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ | ✓ |
| WebDAV          | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |
| Premiumize      | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |
| RealDebrid      | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | ✓ |

Columns: **full** = fullImport, **paged** = pagedImport, **stream** = streamingImport, **delta** = deltaImport, **recent** = recentBooks, **series** = series, **coll.** = collections, **absPull/Push** = audiobookProgressPull/Push, **epubPull/Push** = ebookProgressPull/Push, **dl** = downloads, **covH** = coverAuthHeader, **covQ** = coverAuthQuery, **pgStream** = serverPageStreaming, **bg** = backgroundOperation.

## Footnotes

**¹ Paged with a runaway guard.** These providers stop when they reach their configured maximum page count and log the condition instead of silently truncating.

**³ No recent-books endpoint.** BookOrbit's API silently ignores every `sort` variant on `POST /libraries/{id}/books` and has no dedicated "recently added" endpoint. `fetchRecentBooks` is implemented as a best-effort "last page" fallback (highest IDs = most recently imported) and the capability flag is honestly ✗.

## Per-provider notes

- **Audiobookshelf** — reference provider for streaming through `fetchBookBatches`. Cover auth uses a `?token=` query item. No ebook progress push today.
- **Plex** — paged via `X-Plex-Container-Start/Size`. Series and collections are inferred from paths. Progress push uses `:/scrobble`; progress pull is unavailable.
- **Jellyfin** / **Emby** — server-paged via `StartIndex` / `Limit`. Cover URLs require `X-Emby-Token` headers and must use the authenticated cover loader.
- **Komga** — comic-server: only provider with `serverPageStreaming` today. Delta uses `sort=created,desc`. Cover URL uses HTTP Basic — fine for the iOS `URLSession` cover loader but not for `AsyncImage` without a header rewrite.
- **Kavita** — POST-paginated (body, not query). JWT cover auth via Bearer header. No series exposed (returns `[]`).
- **Booklore** — three-tier (app-tier `/api/v1/app/*`, legacy REST `/api/v1/rest/*`, Komga fallback). Carries both header and query auth for covers. Full progress matrix.
- **BookOrbit** — JWT (15-min access / 7-day refresh httpOnly cookie). Header-only auth. Catalog import stays pagination-only for compatibility with releases that reject `filter`/`sort`; activity sync behaviorally probes the newer paginated `readStatus` filter and falls back to the bounded dashboard endpoint when unavailable. Collections support complete definition and membership snapshots. No universally available sort or recent-books endpoint exists across supported releases.
- **Silo** — profile-scoped API with snapshot-fenced catalog pagination and cursor-based progress sync. Collections include complete personal/manual/smart definitions and memberships plus visible server library collections.
- **OPDS** — read-only feed (Atom 1.x + OPDS 2.0 JSON); depth-bounded traversal. Auth via challenge-response delegate (Basic/Digest/Bearer). No structured series/collections — OPDS spec doesn't expose them.
- **Storyteller** — covers carry both Bearer header AND a `?w=` query sizing token. Full progress matrix incl. read-aloud (EPUB3 SMIL).
- **WebDAV** — file-system enumeration via PROPFIND. No progress, covers, series, or collections. Directory traversal is not currently depth-bounded.
- **Premiumize** / **RealDebrid** — premium-link / debrid services. Aggregates account file listings; identifies audiobooks by extension. No progress, series, collections, or covers.

## Maintenance

1. Add or remove the matching provider protocol conformance and edit `var capabilities: ProviderCapabilities { ... }` in the provider's `.swift` file.
2. Update the row in §"Matrix" above in the **same commit**.
3. If a footnote (¹ ² etc.) is no longer accurate, remove it from the table and §"Footnotes".
4. Cross-check against the per-provider notes in §"Per-provider notes" — those describe *why* the flags are what they are; if your change invalidates a note, edit it.

The capability surface is intentionally honest: a missing flag (✗) signals real work to do, not a TODO to be silenced by adding it.
