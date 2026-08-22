# Deduplication

## Why the old system was unreliable
- **Two sources of truth.** Clusters lived in a *separate* SwiftData store (`Documents/ClusteringService.store`), disjoint from the book store, each `BookSource` embedding a full **stale JSON copy** of the Book. Guaranteed drift.
- **Non-deterministic + O(n²).** `passA_groupByWork` fuzzy-matched against a `Dictionary`'s keys in iteration order → same library clusters differently per run; Levenshtein over all works doesn't scale to 50k.
- **Identifiers wasted.** ASIN/ISBN only nudged pairwise confidence; grouping was title/author fuzzy → the dominant "same book on Plex+ABS won't merge" failure.
- **Progress triplicated, never shared.** Position lived on cluster + version + blob; the normal `playBook` path wrote none of them (`currentCluster` only set by `playCluster`, never reset → wrote the wrong book's position into a stale cluster). The "shared progress across sources" feature was effectively absent.
- **Manual merges not durable.** `userReviewed` was graph state that `rebuild`/`reset` freely discarded; partial unmerge re-merged on next analyze.
- **Over-modeled.** 3-level Cluster→Version→Source graph; a second unused Work/Edition/Version model alongside; mostly-singleton clusters inflating everything.

## Architecture

Two-level model: **Work** (the abstract book) → **Edition** (a format/version) → **Source** (a provider copy).

1. **`workKey` + `editionKey` on `BookRecord`** ([WorkIdentity.swift](../../enve/Services/Dedup/WorkIdentity.swift)) — pure, content-derived, computed at upsert (and a one-time `backfillWorkKeysIfNeeded`). Nonisolated so the off-MainActor upsert worker can call them.
   - `workKey` = `w:<workTitle>|<author>` and is format/version-agnostic so the ebook, the original-narration audiobook, the full-cast audiobook and a translation of one *volume* all share it.
   - **Series position is a HARD separator.** When the book has a series position (`seriesSequence`/`seriesNumber`), the trailing volume number is stripped from the title (so "… 4" and the bare series name share a base) and the volume is split off with `|s:<position>`. This is the fix for the #1 disaster: a same-titled series ("He Who Fights with Monsters" 1..N, where Plex/ABS put the volume only in metadata) never collapses into one work. Verified: `seriesViolations=0` on the 50k library.
   - **Untagged audiobooks separate by exact (rounded-minute) duration** — `|d:<min>`. Real Plex libraries store every volume under one identical title with no series tag and no number; duration is the only discriminator and identical-to-the-minute runtimes are effectively a fingerprint (same recording → merge; different length → different volume → split). Biases hard toward under-merge (recoverable by a manual merge) over the over-merge that broke the old system.
   - **Placeholder titles** ("Unknown Title", "[Unknown Album]", "Untitled", …) return an empty key and never consolidate.
   - `editionKey` = `workKey|f:<format>|p:<production>|a:<abridged>|l:<lang>|n:<narrators>` — copies of one edition across providers collapse; different format, production, narrator, abridgement, and language remain separate editions.
2. **Override ledger** ([WorkOverrideStore.swift](../../enve/Services/System/WorkOverrideStore.swift)) — `[stableId: mergeInto(key) | split]`, persisted. Manual merge and split decisions survive recomputation.
3. **Group at query time** ([WorkGrouping.swift](../../enve/Services/Dedup/WorkGrouping.swift)) — `WorkView` and `EditionView` values are grouped by effective work key, edition key, and source. No cluster rows or separate store are persisted.
4. **Representative** = deterministic tiebreak: downloaded/local › most-complete metadata › stable uniqueId. Edition order: in-progress › audiobook-over-ebook › more sources.
5. **Progress shared per-content** — same-content editions share position through the existing linker; different-length versions keep independent progress.
6. **Play a work** reuses `AppState.playBook` on the preferred source; failover = next member by source preference.
7. **Fuzzy matching is advisory** — near-key matches, including ASIN or ISBN agreement, are surfaced for review and never merge automatically.

## Removed architecture
`BookCluster`/`BookVersion`/`BookSource`(@Model)/`MergeReview`, `ClusteringService` (+ its separate store), `DuplicateDetector`, `SimilarityCalculator`, `LibraryItemAdapter`, the old Dedup UI (`ClusterDetailScreen`/`DedupComponents`/`DedupSettingsScreen`), all `AppState` cluster plumbing (`bookClusters`/`loadCachedClusters`/`clusterLookupCache`/`playCluster`/`playSource`/`processDeduplication`/`findCluster`/`rebuildClusters`/`analyzeLibrary`/`resetAllMerges`/`dedupStats`/review counts), and the `currentCluster`/failover plumbing in PlaybackManager. Kept: `TextNormalizer`, `VersionDetector`, `ProductionType`, `AbridgedState`, and the ebook↔audiobook linking layer (`EbookRelationshipStore` / `WhisperSync`) used for cross-format progress sharing.

## Retained components
`TextNormalizer`, the Dedup and Matches screens, and the strict separation from ebook↔audiobook linking (`EbookRelationshipStore` / `WhisperSync`) remain in place. A cluster key never spans formats.
