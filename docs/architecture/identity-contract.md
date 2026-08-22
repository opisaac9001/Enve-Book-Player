# Book Identity Contract

**Source of truth:** `Models/Library/Book.swift` (the in-memory value type) and `Persistence/BookRecord.swift` (the persisted SwiftData row).

This document defines identifier ownership and stability across duplicate titles, moved files, reimports, multi-part audio, podcast episodes, companion reading, and local-file imports.

## At a glance

| Field | Type | Owner | Stability |
|---|---|---|---|
| `id` | `String` | provider | server-defined; "stable per provider" |
| `providerId` | `UUID` | local (`ServerConnection.id`) | stable per connection (lost on connection delete) |
| `libraryId` | `String` | provider | server-defined |
| `backendId` | `String?` | local (a copy of the source connection key) | tied to the connection |
| `ratingKey` | `String` | provider (Plex) | server-defined; track-level for Plex |
| `partKey` | `String?` | provider | Plex media part / ABS `libraryItemId` |
| `episodeId` | `String?` | provider (ABS podcasts) | server-defined |
| `podcastLibraryItemId` | `String?` | provider (ABS podcasts) | server-defined |
| `audioFileIno` | `String?` | provider (ABS) | server-defined inode |
| `uniqueId` | `String` (computed) | local (this app) | `"<providerId>_<id>"` — stable per app install |
| `stableId` | `String` (computed) | local (this app) | per-source format below — stable across reimport / move when source-specific fields hold |
| `downloadKey` | `String` (`= stableId`) | local | tracks offline files |
| `linkedAudiobookStableId` | `String?` | local | reader/audiobook companion link |
| `readAloudSourceStableId` | `String?` | local | StoryAlign source ebook link |
| `isbn` / `asin` | `String?` | provider | cross-library dedup key when present |
| `deduplicationKey` | `String` (computed) | local | dedup-only — see §"Duplicate title" |

## The two app-owned identities

**`uniqueId`** = the SwiftData primary key. It's `"<providerId UUID>_<provider's book id>"`. It's stable as long as the connection lives. **Delete the connection and `uniqueId` is gone** — every book reimports under a fresh `providerId`. Don't synchronise on `uniqueId` across devices: it's local to *this install*.

`uniqueId` is the right key for:
- BookStore upsert / lookup (the SwiftData `BookRecord.uniqueId`).
- Per-install caches keyed by "this exact row".
- Targeting a write to a specific row.

`uniqueId` is the *wrong* key for:
- CloudKit / cross-device sync.
- Bookmarks / annotations / progress that the user expects to survive a connection-recreate.
- Persisted external references (other backends' "linked book" pointer).

**`stableId`** = the cross-install / cross-launch / cross-connection-recreate identifier. Its derivation is in [Book.swift](../../enve/Models/Library/Book.swift):

| Source | `stableId` format | Notes |
|---|---|---|
| Plex                  | `plex:<ratingKey>`                                   | Track-level; bundle to album via `partKey`. |
| Audiobookshelf        | `audiobookshelf:<backendId ?? providerId>:<id>`      | `backendId` is the user-named ABS instance key — survives reimport on the same server. |
| Local (file-sharing)  | `local:<backendId ?? "unknown">:<id>`                | `id` is the file fingerprint; moved files break this unless `backendId` is held. |
| SMB                   | `smb:<backendId ?? "unknown">:<id>`                  | Same model as local. |
| WebDAV                | `webdav:<backendId ?? providerId>:<id>`              |  |
| Jellyfin              | `jellyfin:<backendId ?? providerId>:<id>`            |  |
| Emby                  | `emby:<backendId ?? providerId>:<id>`                |  |
| Booklore (Grimmory)   | `grimmory:<backendId ?? providerId>:<id>`            | Note: source enum is `.booklore` but stableId prefix is `grimmory:` for historical compat. **Don't normalise this without a tombstone migration** — it's referenced by sinks. |
| RealDebrid            | `realdebrid:<backendId ?? providerId>:<id>`          |  |
| Komga / Kavita        | `komga:<...>:<id>` / `kavita:<...>:<id>`             |  |
| OPDS                  | `opds:<backendId ?? providerId>:<id>`                |  |
| Storyteller           | `storyteller:<backendId ?? providerId>:<id>`         |  |
| BookOrbit             | `bookorbit:<backendId ?? providerId>:<id>`           |  |
| **Read-aloud (any)**  | `storyalign:<readAloudSourceStableId>`               | **Overrides the source-based form.** A StoryAlign-built ebook *is* identified by the source ebook it was built from. The `readAloudSourceStableId` is itself a regular `stableId` from one of the rows above. |

`stableId` is the right key for:
- CloudKit progress / annotations / bookmarks (the things the user expects to follow them across re-installs).
- The companion pointer (`linkedAudiobookStableId`) and the read-aloud pointer (`readAloudSourceStableId`).
- KOReader sync target id.
- Cross-provider linking (an ebook → its companion audiobook on a different provider).

`stableId` is the *wrong* key for:
- SwiftData primary lookup (use `uniqueId`).
- Anything that needs a guarantee "exactly one row in this install" — `stableId` is *not* unique inside a single SwiftData store: two rows from two providers can share a `stableId` if they describe the same content from different angles (rare, but possible — see §"Reimport").

## Identifier rules per cross-cutting case

### Duplicate title
Two books with the same title (and possibly author) from the same or different providers are **not** identical. They keep separate rows. Identity is `(uniqueId)` per row; sync/companion-linking uses `(stableId)`. The `deduplicationKey` (computed: `isbn:<isbn>` → `asin:<asin>` → normalised `title|author`) is consulted **only** by the relationship / linker code (`EbookAudiobookLinker`); it is **never** used as a row key, **never** sent to sinks, and **never** persisted as a `stableId` substitute.

### Moved file (local / SMB)
For local and SMB sources, `id` is the file fingerprint. Moving the file changes the path but **not** the fingerprint, so `id` is preserved; `stableId` is preserved; `uniqueId` is preserved. The path on disk (`filePath`) updates on next scan. **Bookmarks/progress/links survive a move.**

If the fingerprint *itself* changes (re-encoded file, different sample), the file looks like a new book: a new row, a new `uniqueId`, and a new `stableId`. The previous row is removed during generation-based reconciliation. Manual recovery is available through the orphan matcher.

### Reimport (delete + re-add the same server)
A delete-and-recreate of a connection produces a **new `providerId` UUID** (the connection's UUID). All `uniqueId`s change. But `backendId` is preserved (it's user-named, copied through), so for sources whose `stableId` formula starts with `backendId ??` (ABS, Jellyfin, Emby, Komga, Kavita, Storyteller, BookOrbit, WebDAV, Booklore), `stableId` is preserved. **Sync, bookmarks, companion links keep working.** For Plex (`plex:<ratingKey>`), `stableId` is independent of `providerId` and survives reimport unconditionally.

For local / SMB, `stableId` uses `backendId ?? "unknown"` — if the local library was added without a custom backend ID (rare), reimport produces a fresh `stableId` and old progress is orphaned. The orphan matcher recovers these.

### Multi-part audio (Plex album → tracks)
A Plex audiobook is the *album*; tracks are `ratingKey`-distinct rows on the server. The app collapses tracks into one `Book` keyed at the album level when possible (via `partKey` / the album's representative track). `ratingKey` on the Book is the *representative track* id; `partKey` carries the album-level handle. The track-level `audioTracks: [AudioTrack]?` array carries each track's `ratingKey`. **Progress and chapter math are at the album level**; track-level `ratingKey`s are routing-only (asset URLs).

### Podcasts (Audiobookshelf)
ABS podcasts have a two-level identity: the *podcast library item* (`podcastLibraryItemId`) and the *episode* (`episodeId`). The Book's `id` is the **episode**'s id for podcast episodes; `isPodcastEpisode = true`; `podcastLibraryItemId` carries the parent. Progress, bookmarks, sync push **all target the episode** — never the podcast library item. The library item is a *grouping*, not a sync target.

### Companion link (ebook ↔ audiobook of the same title)
`linkedAudiobookStableId` on the ebook points to the audiobook's `stableId`. It is **always a `stableId`**, never a `uniqueId`. A reimport of either side preserves the link as long as the relevant `stableId` is preserved (which is the case for all backend providers where `backendId` is held).

### Read-aloud (StoryAlign-built EPUBs)
A StoryAlign-aligned EPUB is identified by the **source ebook it was built from**. Its `readAloudSourceStableId` is the source ebook's `stableId`, and its own `stableId` is `storyalign:<that stableId>`. This means:
- A StoryAlign EPUB never carries a "raw" `stableId` from its hosting provider — even if the aligned file is stored on, e.g., Audiobookshelf.
- Sync sinks should target the `storyalign:` form so progress on the aligned EPUB lives separately from the source ebook's progress.
- Below iOS 26, this rule is dormant — no rows carry `readAloudSourceStableId`.

### Local file imports (file sharing / SMB scan)
`id` is the fingerprint computed from file content (and possibly path-dependent metadata). The library has a `backendId` that the importer assigns when the library was created; that key is what gives local-source rows their `stableId` continuity. Importing the same file under two different file-sharing libraries produces **two rows** with two `stableId`s — this is intentional; they're conceptually different "copies."

### Multi-volume series (Komga / Booklore)
Series membership is held by the *series* concept, not the book; a book's `series` and `seriesSequence` are display fields. Identity is per-book (`uniqueId` / `stableId`). The Browse / aggregate views index by `(seriesName, providerId)` — a Komga series named "Foo" and a Booklore series named "Foo" are two distinct series entries.

## What changes if?

| Change | `uniqueId` | `stableId` | Bookmarks / progress survive? |
|---|---|---|---|
| App reinstall (same data restored) | depends on UserDefaults / CloudKit restore — assume **lost** without explicit restore | preserved if `backendId` is restored | only via CloudKit / sink-side restore (keyed by `stableId`) |
| Delete & re-add connection | new `providerId` → new `uniqueId` | preserved if `backendId` was custom; otherwise lost (local/SMB) | sink-restored on next sync |
| Server-side file move (Plex / ABS) | preserved | preserved (`ratingKey` / `id` unchanged) | yes |
| Server-side re-encode that changes provider's `id` | new `uniqueId` | new `stableId` | no — orphan matcher recovers |
| Local file move (same fingerprint) | preserved | preserved | yes |
| Local file re-encode (new fingerprint) | new | new | no — orphan matcher recovers |
| StoryAlign rebuilds the aligned EPUB | preserved if `readAloudSourceStableId` is preserved | preserved | yes |
| Connection's `backendId` is changed manually | preserved | **lost** (the prefix changes) | **no** — orphans created; recover via matcher |

The current UI does not expose backend IDs for editing. Any future editor must migrate the affected stable identifiers.

## Bridging rules

Where one identifier must be translated into another, it happens at exactly these seams:

| From | To | Where |
|---|---|---|
| `uniqueId` ↔ `Book` | row read / upsert | `SwiftDataBookStore` only (`upsertBooks`, `bookByUniqueId`, etc.) |
| `stableId` → `uniqueId` | "find the row that matches this sync record" | `BookStoreRepository` projection helper — **do not** scan `allBooks()` to find it |
| provider `id` + `providerId` → `uniqueId` | importer write path | exactly the formula above; **don't** invent variants |
| `linkedAudiobookStableId` → `Book` | reader link resolution | one query into BookStore by `stableId`; no array scan |
| `readAloudSourceStableId` → `Book` | StoryAlign source resolution | one query into BookStore by `stableId` |
| `deduplicationKey` → match candidates | `EbookAudiobookLinker` only | never used as a key elsewhere |

Anything outside these seams that performs its own translation is missing a store API or belongs in a focused store.

## Anti-patterns to avoid

- **Treating `uniqueId` as a sync target.** It's local to the install. Use `stableId`.
- **Treating `stableId` as a SwiftData primary key.** It's not unique (storyalign override; rare cross-provider collisions). Use `uniqueId`.
- **Computing `stableId` outside `Book.swift`.** The formula must live in one place — duplicating it leads to divergence on the next source addition.
- **Scanning `allBooks()` to find a row by `stableId`.** Add a store API.
- **Re-routing `stableId` to `uniqueId` for "convenience" in a sync sink.** It silently breaks reimport recovery.
- **Stripping the `grimmory:` prefix from Booklore `stableId`.** Several sinks key on it. A normalisation pass must go through a tombstone migration.

## Type wrappers

The minimal-blast-radius wrappers `UniqueID` / `StableID` in `Persistence/Identifiers.swift` are adopted at exactly these boundaries:
- `BookStoreRepository` upsert / lookup / delete methods.
- Sync sink `push` / `pull` targeting parameters.
- Companion / read-aloud link parameters (`linkedAudiobookStableId`, `readAloudSourceStableId`).

Everywhere else, `String` is fine — wrapping is intentionally limited to where mis-targeting risk is high.
