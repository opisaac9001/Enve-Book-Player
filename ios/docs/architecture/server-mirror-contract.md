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

Startup may also use a small, bounded recent-book window per selected library to discover and index additions without scanning a large catalog. It is only a refresh hint: it can upsert returned books, but it never authorizes deletion reconciliation.

Capability probing is behavioral. Enve does not infer support from a server version string.

## Provider envelope

| Provider | Catalog | Activity | Collections | Known boundary |
|---|---|---|---|---|
| Grimmory | full paginated snapshot + bounded recent window | focused per-book/list endpoints | complete shelves + magic shelves snapshot | no general change cursor or tombstones |
| Silo | stable paginated snapshot fence + bounded recent window | generic progress cursor; ebook locator remains per book | complete personal, smart, and library collection snapshots | no server representation for Abandoned; keep it Enve-local |
| BookOrbit | full paginated snapshot + bounded last-page window | complete read-status snapshot when filtered queries are supported; bounded dashboard fallback | complete collection snapshot | older releases reject filtered queries; server pagination cannot expose books beyond roughly 50,200 |
| Storyteller | complete unpaged book snapshot, fingerprinted before catalog reconciliation | user status and position embedded in the complete book snapshot | complete collection snapshot | no paging, cursor, bounded recent window, lightweight activity endpoint, or server Abandoned status |

## Startup and refresh

Startup must remain cache-first and bounded:

1. Open the local mirror and render.
2. Flush ready pending mutations.
3. Pull lightweight activity state.
4. Refresh only stale domains.
5. Schedule periodic complete reconciliation rather than refreshing the entire library on every launch.

Pull-to-refresh on Collections requests the collections domain for every active capable connection. It does not require a catalog refresh. Manual full-library refresh remains a repair and reconciliation action.

## Mutation conflicts

User actions update the local presentation optimistically and enter a typed persistent outbox. Until acknowledgment, the pending mutation overlays the last server snapshot for that field. A successful write is followed by an authoritative response or read-back, then the pending entry is removed. Failed writes remain queued with bounded retry and never become a permanent competing source of truth.

Provider limitations remain explicit. For example, Silo cannot make Abandoned server-authoritative until its existing API represents that status; Enve must not pretend a local-only value came from Silo.
