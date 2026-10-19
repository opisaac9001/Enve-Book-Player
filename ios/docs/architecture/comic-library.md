# Comic library and reading cache

Comic browsing uses server identities scoped to a connection and library. Reading
streams pages where supported; Download for offline retains a complete asset.
Temporary reading cache never establishes offline availability.

## Offline availability and storage

Implementation owners: `LocalEbookImporter`, `DownloadsEngine`,
`SwiftDataBookStore`, `DetailDownloadButton`, `StorageScreen`, `LibraryModel`.

- Use one filesystem-backed offline asset resolver for details and repository
  queries. Reader cache, partial transfers, stale completed tasks and missing
  files do not establish offline availability.
- Preserve imported local ebooks and retained readaloud EPUBs. Resolve assets
  within the captured profile's storage, including after a container relocation.
- Keep the primary Read/Resume action. Label the explicit saving action
  Download for offline, then Available offline after completion. Use a consistent
  semantic checkmark color; keep reading progress independent.
- Read filters and storage lists from the same retained assets. Apply repository
  limits after availability checks so recent cache entries cannot hide older
  offline files. Keep badges complete for visible paginated results without
  rescanning the entire catalog on each render.
- Remove the retained download through the established download service and
  persist the cleared asset path even when the book is not in the hot cache.
  Report removal failures without claiming success. Never remove an imported
  original through Remove download.
- Display Offline downloads and Reading cache separately. Include temporary
  ReaderEbooks, StreamedEpubs and StreamedPages in storage totals exactly once.
  Cache clearing and eviction must preserve retained downloads.


## Comic browsing and hierarchy

Implementation owners: library model/browse views, focused comic series model,
provider mapping and repository projections.

- Add a Comics media scope. Default comic-library browsing to Series when no
  preference exists; remember Series/Issues and layout per source/library scope.
  Do not change a previously selected view or an audiobook/ebook preference.
- One series card shows its title, publication run when supplied, issue count,
  unread count and current/next unread issue. Keep a direct Continue action.
- Identify comic series by connection, library and server series ID. Never merge
  unrelated runs or editions because normalized titles match. Preserve current
  book IDs and legacy Kavita first-issue identity.
- Preserve typed series/volume/section metadata from provider responses through
  persistence. Do not derive the hierarchy by reparsing a display title. Extend
  the existing model and projections with optional metadata. Follow the existing
  versioned schema/migration pattern, test opening a previous store with progress
  and download paths intact, and populate missing metadata on provider refresh.
- Inside a series, expose Issues/Volumes/Specials only when meaningful for that
  server library type. Use collapsible volume sections with stable IDs. A single
  section opens directly. Collected editions and ranges remain one publication.
- Keep collection membership and reading-list order as distinct navigation
  contexts. Fetch only the selected series detail; paginate long issue lists.
- Provide loading, empty, offline and retry states without discarding already
  loaded content. Use the existing Hearth controls, Dynamic Type and VoiceOver.


## Reader entry and return

Implementation owners: `ClassicReaderModel`, `ReaderPublicationSession`,
`ReaderPagedContentController`, `ReaderOpenCoordinator`, library/series screens.

- Prefer a valid local archive before remote metadata. Otherwise show the saved
  page as soon as it arrives and prefetch a small neighboring window. Do not wait
  for unrelated metadata, progress upload or the entire series/catalog.
- Keep Back/Cancel available during preparation. Describe the actual operation
  (opening comic, loading a page, downloading a file); show a percentage only
  when measurable. Surface a retryable error when streaming fails rather than
  silently starting an unexpectedly large archive transfer.
- Persist reading progress locally immediately. Upload in the background using
  existing conflict handling. Reader dismissal must not await network work.
- Cancel reader-only preparation/prefetch on dismissal. An explicit offline
  download can continue under the existing scheduler.
- Keep the library/series view and model identities stable. Preserve exact scroll
  position, sort, filters, selected section and expanded volumes. Coalesce
  progress updates rather than rebuilding an unrelated 17,400-book view.
- Continue within the context used to open the issue: series order or reading
  list order, including after reopening an offline issue.


## Bounded reading cache

Implementation owners: `ServerPageStreamingService`, importer cache policy,
profile-owned cache metrics and storage controls.

- Set a bounded automatic disk budget with least-recently-used eviction across
  inactive comic reading sessions. Reuse cached pages across opens within that
  budget. Protect active reader assets and in-flight writes from eviction.
- Keep automatic page prefetch separate from explicit offline saving. A session
  cache must never promise complete offline access or grow without a bound.
- Clear reading cache through its owner, canceling its own work safely. Do not
  delete another profile's cache or retained downloads. Explain retained active
  reading data if it cannot be removed immediately.
- Run disk enumeration/size measurement and eviction off the UI thread. Avoid
  full directory scans during page turns and SwiftUI body evaluation.

## Verification

`ComicCatalogTests`, `ComicLibraryBrowseTests`, and `ComicSeriesModelTests` cover
scoped identities, sections, filtering, pagination, and browsing state.
`ComicCatalogMigrationTests` and `ComicMigrationCompatibilityTests` cover the
versioned store migration. `OfflineAvailabilityTests`, `ReadingCacheStoreTests`,
`ServerPageStreamingCacheTests`, and `ComicReaderLifecycleTests` cover retained
assets, cache ownership, cancellation, eviction, and reader cleanup.

`ComicLibraryUXUITests` exercises series, specials, reader return navigation,
and large accessibility text against a synthetic 17,400-item catalog. Live
provider tests require developer-supplied configuration outside the repository.

Before releasing reader or cache changes, exercise streaming, explicit offline
saving, airplane-mode reopening, removal, profile switching, and clearing the
cache while a reader is open. Check older devices with large libraries; simulator
results do not establish physical-device responsiveness.
