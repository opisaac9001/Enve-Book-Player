# Server Mirror Contract

Enve renders a persistent local mirror immediately, then reconciles it with each connected server. The server is authoritative for every concept it can represent. Local state is authoritative only for downloads, app preferences, reader presentation, server-unsupported concepts, and queued user mutations that have not reached the server yet.

## Identity invariants

- A mirror scope is connection UUID + opaque account key + optional library ID + domain.
- Book rows remain keyed by `uniqueId = "<providerId>_<provider book id>"`.
- Cross-install sync continues to use the source-specific `stableId` from `identity-contract.md`.
- Matching and deduplication keys never replace either identifier.
- Snapshots from different connections are reconciled independently and then displayed together.

## Domains

| Domain | Server-owned state | Ordinary refresh |
|---|---|---|
| Catalog | libraries, books, metadata, formats, server deletion | delta when trustworthy; otherwise a complete paginated snapshot when stale |
| Catalog additions | newest-first discovery window, independent freshness per selected library | small pages until a previously indexed page; never reconciles deletions |
| Activity | progress, locator, reading status, rating, current/finished/abandoned | lightweight activity endpoints or a server cursor |
| Collections | shelf/collection definitions, membership, ordering, magic rules | complete collection snapshot or a trustworthy server revision |
| Pending mutations | writes initiated in Enve but not acknowledged | flush before pulling the affected domain; overlay until acknowledged |

Each domain commits independently. A catalog failure must not roll back activity or collections, and a collection failure must not remove cached shelves.

## Snapshot rules

1. Render the last complete local snapshot before making network requests.
2. Build a replacement snapshot away from visible state.
3. Treat every expected page and membership request as required.
4. Commit atomically only after the complete snapshot succeeds.
5. Reconcile deletions only from a complete snapshot or explicit server tombstone.
6. Preserve the previous snapshot after cancellation, authentication failure, decoding failure, pagination inconsistency, or incomplete membership.
7. Fingerprint complete snapshots and skip database/UI churn when content is unchanged.
8. Record a checkpoint only after committing or confirming a complete snapshot.

A summary count is part of snapshot validation when the server supplies one. If membership endpoints disagree with it, Enve preserves the previous mirror and retries later instead of displaying a known-incomplete shelf.

## Sync levels

Enve chooses the strongest mechanism a released server supports, per provider and domain:

1. `nativeCursorDelta` — server cursor/change sequence. Enve only reconciles deletions when that cursor includes tombstones or after a complete cursor replay.
2. `revisionSnapshot` — lightweight revision probe followed by a complete snapshot when changed.
3. `fullSnapshot` — complete paginated snapshot with a local fingerprint.

Startup and Hearth pull-to-refresh use a recent-book window per selected library to discover additions without scanning an unchanged catalog. Grimmory requests 50 source books per page, newest first, and continues through additions until it reaches an already indexed source page. Derived companion audiobooks do not extend that boundary. Only newly discovered rows are merged from Grimmory pages; known books retain their detailed metadata. Pages are staged before merging a library, so a later-page failure preserves the cache and leaves freshness unchanged for retry. An empty local catalog receives only the first window; startup catalog import remains responsible for initial reconciliation. Other window-capable mirror providers retain their bounded recent-book fetch.

The additions window has its own `catalogAdditions` checkpoint and never advances full-catalog reconciliation or authorizes deletions. Grimmory resolves alternate formats through the batch endpoint or individual records; recent discovery never falls back to a full legacy catalog fetch. Servers without the paginated endpoint retain their cache and expose a retry notice on Hearth; manual Library refresh remains available.

Capability probing is behavioral. Enve does not infer support from a server version string.

Silo's complete-snapshot traversal follows its catalogue cursors in order, with 200 source items per page and up to six concurrent detail requests within a page. Detail responses retain complete searchable metadata; their in-memory cache is limited to 100 entries. Each mapped page preserves source order, and a failed request prevents that page from committing. A malformed item marks the traversal incomplete, so it cannot authorize deletion reconciliation. Rate-limited reads share a cancellation-aware cooldown, honor Silo's numeric `Retry-After`, and retry at most five times; writes are not replayed for HTTP 429. Ordinary refresh no longer runs this traversal; see remote catalog browsing below.

## Remote catalog browsing

A provider that conforms to `RemoteCatalogBrowsingProvider` is browsed and searched page by page on the server instead of from a complete local mirror. Silo conforms for every library.

- A page is assembled from independent lanes: one per selected, non-excluded server library in scope and, for All Sources, one stored lane for every other source. Each open lane fetches 50 rows per page concurrently and keeps its own cursor or offset, so local rows and every server progress independently. A page that combines lanes is ordered by the request sort within that page; global order across lanes is approximate. Library IDs come from the current profile's connection and its selected libraries.
- The stored lane filters media, search text, and sort in the store query and excludes every remote-catalog provider's cached rows before the page limit. All Sources searches also run the existing Grimmory remote search once per search, concurrently with the other lanes.
- Server lanes send `skip_total=true` and follow the opaque cursor. Search sends `q`; the Audiobooks and Ebooks media filters send `type`; both apply before the limit. Sort sends `title` or `-added_at`; other Enve sorts fall back to title order with a visible notice. A lane that repeats a cursor stops and reports the error. Up to three rounds run while a page has no rows; after that an empty page with more results shows Load More instead of an empty state.
- Silo cards are mapped without detail requests. Authors, narrators, series, files, and chapters may stay unavailable until playback, reading, download, or the detail screen resolves the item by identity. A stored row for the same `uniqueId` keeps its local progress, links, and resolved details; the fresh card supplies title, cover, and overview after stored metadata overrides. An unstored audiobook card takes its local listening position when one exists. Card language survives cached records and sparse detail responses so a later download remains searchable by language offline.
- Results appear as each source responds, including while another source is still loading. Enve does not show server totals for these pages. The summary reads “N loaded” while more pages exist.
- Pages never authorize reconciliation, deletion, or a full-catalog checkpoint. Connection, startup, and manual refresh stage only recent summaries and leave the existing mirror, reading data, and checkpoints untouched. Periodic full reconciliation is skipped for these providers.
- A lane that fails because the network is unavailable (offline, timeout, lost connection, unreachable host) contributes that server's downloaded books whose files exist on this device, narrowed by scope, media, and search before matching. Other lanes still show their results, and the unavailable server is named with Retry. When no lane reaches a source and none was unreachable, the authentication, decoding, or server error is shown with Retry instead of an empty catalog. Retry and pull-to-refresh request every server again.
- Typing, or changing source, media, sort, status, or filters, cancels the in-flight request immediately; a superseded response is discarded.
- Catalog requests use an eight-second network timeout. When the device has no connection, browsing and search use actual downloads from the selected scope without contacting a server. Downloaded searches filter those files directly, before any result limit.
- Genre and language advanced filters use Silo’s structured `POST /catalog/query`: selections within a category are OR’d, and categories are AND’d before pagination. Search text, media, scope, and cursor travel in the same request. Filter changes reset the cursor. Local lanes advance by the raw page size before applying these filters, so sparse matches remain reachable. Offline matching uses the same selections against actual downloaded files.
- The genre/language picker checks `facet_value_search`, then searches `/catalog/filters/search` with a 24-value window per facet and library. It does not treat the capped `/catalog/filters` response as complete. Selected values remain available while searching; stale responses are discarded. All Sources adds a bounded sample of non-Silo cached options.
- Rating and any-series/standalone advanced filters, status filters, the Series, Authors, Narrators, and Genres facets, comics, and podcasts have no server query here. They use Enve's cached listings with a notice that they may be incomplete. While a server is unreachable, its cached rows in those views are limited to files on this device. On Device and Downloaded are always local.

## Provider envelope

| Provider | Catalog | Activity | Collections | Known boundary |
|---|---|---|---|---|
| Grimmory | full paginated snapshot + bounded recent window | focused per-book/list endpoints | complete shelves + magic shelves snapshot | no general change cursor or tombstones |
| Silo | remote catalog browsing + bounded recent window; existing mirror rows are retained, not reconciled | generic progress cursor; ebook locator remains per book | complete personal, smart, and library collection snapshots | no server representation for Abandoned; keep it Enve-local; catalog cards omit authors, narrators, and series |
| BookOrbit | full paginated snapshot + bounded last-page window | complete read-status snapshot when filtered queries are supported; bounded dashboard fallback | complete collection snapshot | older releases reject filtered queries; server pagination cannot expose books beyond roughly 50,200 |
| Storyteller | complete unpaged book snapshot, fingerprinted before catalog reconciliation | user status and position embedded in the complete book snapshot | complete collection snapshot | no paging, cursor, bounded recent window, lightweight activity endpoint, or server Abandoned status |

## Startup and refresh

Startup must remain cache-first and bounded:

1. Open the local mirror and render.
2. Flush ready pending mutations.
3. Pull lightweight activity state.
4. Refresh only stale domains.
5. Schedule periodic complete reconciliation rather than refreshing the entire library on every launch.

Hearth renders cached shelves immediately and observes local library changes. Opening Hearth or returning to it does not start a catalog check. Pull-to-refresh checks recent additions immediately and shares any provider refresh already running. The existing startup path retains its 15-minute additions freshness interval. Progress sync remains separate, and Hearth labels its timestamp “Progress synced.” Full catalog reconciliation retains its seven-day schedule. Failed additions requests do not clear cached books or advance freshness.

Pull-to-refresh on Collections requests the collections domain for every active capable connection. It does not require a catalog refresh. Manual full-library refresh remains a repair and reconciliation action.

## Mutation conflicts

User actions update the local presentation optimistically and enter a typed persistent outbox. Until acknowledgment, the pending mutation overlays the last server snapshot for that field. A successful write is followed by an authoritative response or read-back, then the pending entry is removed. Failed writes remain queued with bounded retry and never become a permanent competing source of truth.

Provider limitations remain explicit. For example, Silo cannot make Abandoned server-authoritative until its existing API represents that status; Enve must not pretend a local-only value came from Silo.
