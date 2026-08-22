# Enve Book Player — Playback + Library Engine API Contract

All paths below are relative to `enve/`. Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, new code uses `@Observable` (not ObservableObject) except where noted.

---

## 1. Book model

**`Models/Library/Book.swift`** — `public struct Book: Identifiable, Codable, Equatable, Sendable` (value type, not a class).

Key properties:

| Property | Type | Notes |
|---|---|---|
| `id` | `String` | provider-native id |
| `uniqueId` | `String` (computed) | `"\(providerId)_\(id)"` — SwiftData primary key, install-local |
| `stableId` | `String` (computed) | `"source:backendId:id"` (e.g. `"audiobookshelf:<backend>:<id>"`) — cross-install identity, used for progress/downloads |
| `downloadKey` | `String` (computed) | alias of `stableId` |
| `title` | `String` | |
| `author` / `authors` | `String?` / `[String]?` | |
| `narrator`, `series`, `seriesNumber: Int?`, `seriesSequence: String?` | | `seriesInfo: SeriesInfo?` computed |
| `thumb` | `String?` | raw cover URL/path; resolve via `coverURL: URL?` (computed; falls back to Caches/`Covers/<id>.jpg` and App Support `Enve/Covers/<downloadKey>.jpg`) |
| `mediaType` | `AppMediaType` | `Models/AppMediaType.swift`: `enum AppMediaType: String, Codable { case audiobook, podcast, ebook }` |
| `duration` | `TimeInterval?` | seconds |
| `chapters` | `[Chapter]?` | |
| `audioTracks` | `[AudioTrack]?` | multi-file books; `isMultiFile`, `audioTrack(at:)`, `localPosition(for:)`, `globalPosition(trackIndex:localOffset:)` |
| `currentTime` | `TimeInterval` | audio position (`progress: TimeInterval?` is a get/set alias) |
| `ebookProgress` | `Double?` | 0–1; `epubLocator: String?` (Readium Locator JSON); `canonicalEbookProgress: Double` reconciles the two |
| `isFinished`, `lastUpdate: Date` | | `progressPercentage: Double`, `isStarted`, `isCompleted` computed |
| `source` | `Book.BookSource` | `plex, audiobookshelf, local, smb, webdav, jellyfin, emby, booklore("grimmory"), realdebrid, komga, kavita, opds, storyteller, bookOrbit` |
| `providerId: UUID`, `libraryId: String`, `backendId: String?` | | links to `ServerConnection`/`Library` |
| Podcast: `isPodcastEpisode`, `episodeId`, `podcastLibraryItemId`, `podcastName` | | |
| Linking: `linkedAudiobookStableId`, `linkedAudiobookChapterOffset`, `readAloudSourceStableId`, `hasAlternateFormat` | | ebook↔audiobook / StoryAlign |

**`Chapter`** — `Networking/Models/UniversalModels.swift:496`:
```swift
public struct Chapter: Identifiable, Codable, Hashable {
    public let id: String; public let start: Double; public let end: Double
    public let title: String; public var index: Int
    public var duration: Double { end - start }   // also startTime/endTime aliases
}
```

**`AudioTrack`** — `Models/AudioTrack.swift`: `public struct AudioTrack: Identifiable, Codable, Equatable, Sendable` with `index, title?, filePath?, contentUrl?, duration, startOffset, fileSize?, format?, headers?`. Global↔local mapping helpers in `Models/Playback/AudioTrackInfo+Playback.swift`.

---

## 2. Library data: source of truth & queries

**Source of truth = SwiftData store.** Concrete: `Persistence/SwiftDataBookStore.swift`, built by `BookStoreManager.shared` (`Persistence/BookStoreManager.swift`), exposed as protocol **`BookStoreRepository`** (`Persistence/BookStoreRepository.swift`). Reach it via `AppState.shared.bookStore` (`let bookStore: BookStoreRepository`). Row model: `Persistence/BookRecord.swift` (`@Model final class BookRecord`, mirrors Book; flags `isHidden`, `isDeleted`; keyed by `uniqueId`).

**`AppState.allBooks` is NOT the source of truth.** `Models/Application/AppState.swift` (`@Observable @MainActor public class AppState`, `AppState.shared`):
- `@ObservationIgnored var allBooks: [Book]` is a **capped in-memory mirror — first 2000 books only** (`loadCachedBooks()` loads `pagedBooks(offset: 0, limit: 2000, mediaType: nil)`). At 50k books the rest live only in SQLite.
- `let hotCache = BookHotCache()` (`Persistence/BookHotCache.swift`, LRU capacity 2000 + pinning) backs sync lookups: `AppState.bookInMemory(uniqueId:)` / `bookInMemory(stableId:)` (returns nil for cold books — fall back to `await bookStore.book(uniqueId:)`).
- Single-book mutation chokepoint: `AppState.mutateBook(uniqueId:_:(inout Book)->Void) -> Book?` (and `stableId:` variant, plus batched `mutateBooks(_:)` / `mutateBooksByStableId(_:)`) — writes mirror + hotCache + persists via `bookStore.upsertBooks`. **A new UI must mutate through these, never poke `allBooks` directly.**

**Querying (what a new UI should call):** key `BookStoreRepository` methods (all `async`, all return value-type `[Book]`):
```swift
func bookCount() async -> Int
func book(uniqueId: String) async -> Book?
func book(stableId: String) async -> Book?
func book(byAnyId id: String) async -> Book?           // uniqueId → stableId → bookId
func pagedBooks(after cursor: Book?, limit: Int, mediaType: String?) async -> [Book]   // keyset paging
func pagedBooks(libraryId: String, providerId: UUID, after cursor: Book?, limit: Int) async -> [Book]
func firstBooks(mediaType: String, limit: Int) async -> [Book]                          // capped reads
func searchBooks(query: String, limit: Int) async -> [Book]
func searchBooks(query: String, libraryId: String?, providerId: UUID?, limit: Int) async -> [Book]
func continueListeningBooks(limit: Int) async -> [Book]
func continueReadingBooks(limit: Int) async -> [Book]
func recentBooks(limit: Int) / recentEbooks(limit:) / downloadedEbooks(limit:) async -> [Book]
func books(inSeries:) / books(byAuthor:mediaType:limit:) / books(byNarrator:...) / books(bySeries:...)
func browseAuthorAggregates(mediaType:) async -> [BrowseAuthorAggregate]   // {name, bookCount, representativeThumb}
func browseNarratorAggregates(mediaType:) / browseSeriesAggregates(mediaType:)
func booksMatching(_ collection: SmartCollection, limit: Int?) async -> [Book]
func upsertBooks(_ books: [Book]) async
```
`mediaType` is a raw string: `"audiobook"`, `"ebook"`, `"podcast"`.

**Observation:** `BookQuery` (`Persistence/BookQuery.swift`, `enum BookQuery: Hashable, Sendable` — cases `.mediaType`, `.library`, `.continueListening(limit:)`, `.search(query:limit:)`, `.inSeries`, `.matching`, `.recent`, etc.) + the extension on `BookStoreRepository`:
```swift
func observe(_ query: BookQuery) -> AsyncStream<[Book]>     // re-runs on .bookStoreDidChange, 1.5s debounce
func observe<T: Sendable>(_ fetch: @Sendable @escaping () async -> T) -> AsyncStream<T>
```
Intended SwiftUI pattern: `.task(id: query) { for await books in store.observe(query) { self.books = books } }`. Change signal: `Notification.Name.bookStoreDidChange` posted via `BookStoreChangeNotifier` (`Persistence/BookStoreChangeNotifier.swift`, 0.5s coalesce). Legacy bridge: `AppState.allBooksChanged` (`PassthroughSubject<Void, Never>`) also triggers it.

**50k path (how the existing UI does it, in `ViewModels/LibraryViewModel.swift`):** when `bookStore.bookCount() > 3000` it flips to paged mode — first page `store.pagedBooks(after: nil, limit: pageSize /* = 2000 */, mediaType:)`, infinite scroll via `loadNextPageIfNeeded(currentIndex:)` using last book as keyset cursor; while in paged mode, search delegates to `bookStore.searchBooks(query:limit: 200)` (SQLite `localizedStandardContains` over title/author/narrator/series, predicate-level, `fetchLimit`). Sorting/filtering prefs persist in `LibraryDisplayPreferencesStore.shared` (`UserPreferences.SortLevel/SortOption/SortOrder`).

---

## 3. Audio playback

Playback has one public contract with platform-specific adapters. `ActivePlayback.composition` selects `PlaybackManagerController` on iOS and `AudioServicePlaybackController` on tvOS once at composition time. Feature code consumes the narrow capabilities in `Plugins/PlaybackStateProvider.swift`; it does not branch on platform or reach into either engine singleton.

### Playback contract: `Plugins/PlaybackStateProvider.swift`

`PlaybackControlling` exposes transport commands plus one authoritative `PlaybackSnapshot`. Its `snapshots` publisher drives observation. Optional capabilities in `PlaybackComposition` cover loading, book starts, restoration, now-playing updates, progress conflicts, overlays, preparation state, and audio processing.

`PlaybackManager` and `AudioService` remain internal engine implementations behind their adapters. Do not bind UI or feature code directly to either engine.

Snapshot state:
```swift
struct PlaybackSnapshot {
    let currentBook: Book?
    let isPlaying: Bool
    let position: TimeInterval
    let duration: TimeInterval
    let playbackSpeed: Double
    let volume: Double
    let isLoaded: Bool
    let isLoading: Bool
    let isOverlayPlaybackActive: Bool
    let errorDescription: String?
}
```

Transport:
```swift
func play(); func pause(); func stop(); func togglePlay()
func seek(to time: TimeInterval)
func skipForward(seconds: TimeInterval)
func skipBackward(seconds: TimeInterval)
func setPlaybackRate(_ rate: Double)
func setVolume(_ volume: Double)
func fadeOutAndPause(duration: TimeInterval, steps: Int) async
```

**Do not call an engine or adapter load method directly from UI to start a book.** The entry point is `EnveEngine.shared.playback.play(_ book: Book, presentPlayer: Bool = true)`. `PlaybackEngine` routes ebooks to the reader and sends audiobooks through `PlaybackQueueCoordinator` and the composition's `BookPlaybackStarting` capability. Provider preparation, resume resolution, presentation, and platform-specific loading stay behind that boundary.

Chapters for UI come from `PlayerViewModel`; time remaining is derived from the snapshot's duration, position, and playback rate. Progress persistence and remote delivery route through `CurrentPlaybackPersister` and `SyncCoordinator`, including its persistent retry queue.

### Presentation model: `Screens/Player/PlayerViewModel.swift`
`@Observable public class PlayerViewModel`, `PlayerViewModel.shared`. It observes the selected controller's `PlaybackSnapshot`, issues transport commands through `PlaybackControlling`, and owns player-session presentation features such as chapters, sleep timers, bookmarks, and audio settings. It is not an authoritative playback-state store.

State: `currentBook: Book?`, `isPlaying`, `progress`, `duration`, `chapters: [Chapter]`, `currentChapter: Chapter?`, `nextChapterInList: Chapter?`, `bookmarks: [Bookmark]`, `sleepTimer: Date?`, `sleepTimerRemainingSeconds`, `isFadingOut`, `progressConflict: ProgressConflict?`, `error`, `isLoading`, `preferences: UserPreferences`, `playbackSpeed: Double`, `absSyncStatus`.

Key methods a UI calls:
```swift
func play(book: Book)                       // delegates book start to EnveEngine playback
func togglePlay(); func pause(); func stop()
func seek(to time: TimeInterval)
func skipForward(); func skipBackward()
func setPlaybackSpeed(_ speed: Double); func setVolume(_ volume: Double)
func nextChapter(); func previousChapter(); func seekToChapter(_ chapter: Chapter)
// Sleep timer
func startSleepTimer(minutes: Int, fadeOut: Bool = true)
func setSleepTimerToEndOfChapter(fadeOut: Bool = true)
func setSleepTimerToEndOfNextChapter(fadeOut: Bool = true)
func stopSleepTimer(); func snoozeSleepTimer()
func applySleepRewind(); func dismissSleepRewind()         // pendingSleepRewindMinutes
// Bookmarks
func addBookmark(at position: TimeInterval? = nil, title: String? = nil, note: String? = nil) -> Bookmark?
func removeBookmark(_:); func updateBookmark(_:newTitle:newNote:); func seekToBookmark(_:)
// Audio FX (delegates to the selected PlaybackComposition capabilities)
func setVoiceBoostEnabled/_Preset, setEQEnabled/_Bands, setMonoMixEnabled, setStereoBalance,
func setNoiseReductionLevel, setBinauralEnabled, setIndependentPitchSemitones, setBasicVoiceMode
func previewBook(_ book: Book, backendOverride: BackendConfig? = nil) async throws -> AVPlayer
func resolveStreamURL(for book: Book, backendOverride: BackendConfig? = nil) async throws -> URL?
```

**Practical contract for a new player UI:** observe transport state from the injected `PlaybackControlling.snapshot` (or from `PlayerViewModel` where it already projects that snapshot), send transport commands through that controller, and use `PlayerViewModel` for session presentation features. Start books through `EnveEngine.shared.playback.play(book)`. Presentation state comes from `AppPresentationState`; no UI should retrieve `PlaybackManager.shared` or `AudioService.shared`.

Now-playing / remote commands: `Services/Player/NowPlayingCoordinator.swift` — `final class NowPlayingCoordinator` (`.shared`), `struct NowPlayingInfo {title, artist, albumTitle, duration, elapsed, rate, chapterNumber, chapterCount, artworkImage, ...}`, `protocol RemoteCommandTarget` (PlaybackManager + AudioService both conform; coordinator arbitrates which engine owns MPRemoteCommandCenter). UI never touches this. AirPlay: no route picker view in iOS app; audio session sets `.allowAirPlay` (`Services/Audio/AudioService.swift:736`) — standard `AVRoutePickerView` can be added by the new UI safely.

Sleep timer persistence: `Services/PlayerStateStore.swift` (`saveSleepTimer/loadSleepTimer` of `Models/SleepTimerState.swift`, `saveLastPlayedBookId/loadLastPlayedBookId` — drives launch mini-player restore).

---

## 4. Cover images

Pipeline a new UI should reuse, all in **`Utilities/DiskImageCache.swift`**:

- `class DiskImageCache` (`.shared`): two-tier cache — `NSCache` (200 items / 96MB cost-bounded) + disk at Caches/`BookCovers/` keyed by percent-encoded absolute URL. API: `memoryImage(for: URL?) -> UIImage?` (sync, hot path), `image(for: URL?) async -> UIImage?` (disk decode off-main), `save(_:for:)`, `hasImage(for:)`, `shouldSkipRemoteFetch(for:)` / `markRemoteFetchFailure(for:)` (5-min negative cache), `clearAllCache()`.
- `struct CachedAsyncCoverImage: View` (iOS-only, same file) — **the** cover view. Usage from `Views/Components/BookCard.swift`:
  ```swift
  CachedAsyncCoverImage(url: book.coverURL, fallbackColor: "Blue",
                        headers: CachedAsyncCoverImage.authHeaders(for: book), book: book)
  ```
  Handles: memory→disk→`LocalStorageManager.coverOverridePath(for: book.downloadKey)`→remote (with retry + token-refresh headers), special-cases Storyteller (`provider.fetchCoverImage`), Booklore (`provider.fetchImageData`), OPDS (challenge auth). Persists fetched bytes to `AppCache.shared.setCoverData(_:for:)` and the cover override file.
  - `@MainActor static func authHeaders(for book: Book) -> [String: String]` — builds Basic/Bearer/X-API-Key headers from the matching `ServerConnection`. Reuse this; do not hand-roll headers.
- Cover **URL building is a provider concern at import time** — each `LibraryProvider` writes the full (often token-in-query) URL into `Book.thumb`; UI only consumes `book.coverURL`. (Token-in-URL for covers is an accepted, documented risk.)
- Secondary persistent store: `Services/AppCache.swift` `AppCache.shared` — `coverCacheKey(for:)`, `getCoverData(for:) async -> Data?`, `setCoverData(_:for:)`, `cacheAllCovers(for:progress:)`, `clearCoverCache()`.

---

## 5. Progress

**`Services/Sync/BookProgressStore.swift`** — `@MainActor final class BookProgressStore`, `.shared`. UserDefaults-backed (`bookProgress_<stableId>` and legacy `bookProgress_<id>` dual-write).

```swift
func saveProgress(for book: Book, progress: TimeInterval, duration: TimeInterval)   // no-ops on <1s delta
func loadProgress(for book: Book) -> (progress: TimeInterval, duration: TimeInterval, lastUpdated: TimeInterval)?
func saveProgress(bookId: String, progress: TimeInterval, duration: TimeInterval)
func loadProgress(bookId: String) -> (progress:, duration:, lastUpdated:)?
func clearProgress(for bookId: String)
func saveServerStamp(for book: Book, _ date: Date); func loadServerStamp(for book: Book) -> Date?
// Recently played (Continue Listening), capped 50:
func saveRecentlyPlayed(_ book: Book)                       // (and (_:date:) variant)
func loadRecentlyPlayed() -> [Book]
func loadSnapshots() -> [RecentlyPlayedSnapshot]            // {stableId, book, lastUpdated}
func remove(stableId: String); func removeOrphaned(bookIds: [String])
```
Writes post `Notification.Name.bookProgressDidChange` (defined `Services/System/StorageService.swift:8`), debounced 1/s, `object` = stableId.

For list rendering at scale prefer the store-side queries instead: `bookStore.continueListeningBooks(limit:)` / `continueReadingBooks(limit:)` and `bookStore.progress(forBookUniqueId:) -> BookProgressSnapshot?` (`{bookUniqueId, stableId, currentTime, duration, ebookProgress, epubLocator, isFinished, lastUpdate, hideFromContinue}`). In-memory per-session map: `AppState.userMediaProgress: [String: UserMediaProgress]` keyed by `uniqueId`, read via `AppState.getUserMediaProgress(for: book, episodeId: String? = nil)`. Cross-device sync status (for a Sync UI) lives on `SyncCoordinator.shared` (`isSyncing`, `lastSyncDate`, `pendingSyncCount`, …).

---

## 6. Downloads

Two layers; **UI talks to `UnifiedDownloadService`**, which orchestrates `BookDownloadManager` (the URLSession engine).

**`Services/UnifiedDownloadService.swift`** — `@MainActor final class UnifiedDownloadService: NSObject, ObservableObject`, `.shared` (legacy ObservableObject — observe with `@ObservedObject`/`@StateObject` or `.onReceive`).

```swift
struct BookDownloadTask: Identifiable, Codable {
    let id: String; let bookId: String /* = book.downloadKey (stableId) */; let title: String
    let source: Book.BookSource
    var status: DownloadStatus   // .queued .downloading .paused .completed .failed .cancelled
    var progress: Double; var bytesDownloaded: Int64; var totalBytes: Int64; var errorMessage: String?
    var isActive: Bool; var progressText: String
}

@Published private(set) var tasks: [BookDownloadTask]
@Published private(set) var isNetworkAvailable: Bool; @Published private(set) var isOnCellular: Bool
var activeTasks/completedTasks/failedTasks: [BookDownloadTask]; var activeCount: Int; var overallProgress: Double
var canDownload: Bool; var downloadBlockedReason: String?; var allowCellularDownloads: Bool

func download(book: Book, overrideCellular: Bool = false) async        // start (resolves URLs per provider)
func pause(taskId: String); func resume(taskId: String, book: Book) async
func cancel(taskId: String); func retry(taskId: String, book: Book) async
func remove(taskId: String); func clearCompleted()
func deleteDownload(bookId: String) async                              // bookId = book.downloadKey
func checkStorageLimit() async
```

**`Services/BookDownloadManager.swift`** — `final class BookDownloadManager: NSObject, ObservableObject`, `.shared`. Lower-level; useful read API: `progress(for bookId:) -> Double`, `isDownloading(_ book:) -> Bool`, `isDownloaded(bookId:) -> Bool`, `@Published progressByBookId: [String: Double]`, `completedBookIds: Set<String>`, `lastErrorByBookId`, and `static let downloadDidCompleteNotification`. Downloaded-state check used by playback routing: `LocalStorageManager.shared.isAudiobookDownloaded(_ book:)` (`Services/LocalStorageManager.swift`); files live under `LocalStorageManager.bookAudioDirectory(for: downloadKey)`. Ebook download progress: `Services/EbookDownloadProgressStore.swift`.

---

## 7. Search

- **Library search (the one a new UI needs):** `bookStore.searchBooks(query:limit:)` / `searchBooks(query:mediaType:limit:)` / `searchBooks(query:libraryId:providerId:limit:)` — SQLite-side OR-contains over title/author/narrator/series, sorted by title, `fetchLimit`-capped. Observable form: `store.observe(.search(query: q, limit: 200))`. This is exactly what `LibraryViewModel.recomputeFilteredBooks()` does in paged mode (limit 200); for small in-memory sets it filters `books` with `localizedCaseInsensitiveContains` over title/author/narrator/series/genres/description.
- `Services/EnveSearchService.swift` (`EnveSearchService.shared`) — **not** library search; Audible-catalog metadata lookup (`getBook(asin:)`, `searchAuthors(name:)`, `getChapters(asin:)`).
- `Services/EbookSearchService.swift` — in-book full-text search over a Readium `Publication` (`search(in:query:)`, `nextResult()`), plus `EbookSearchIndex.shared.searchLibrary(query:)` for indexed ebook text. Not for library browsing.
- Search history persistence: `StorageService` (`Services/System/StorageService.swift`).

---

## Cross-cutting notes for the new UI

- Legacy shared instances still exist at composition boundaries, but feature code should receive narrow dependencies. Playback is selected through `ActivePlayback.composition`; `PlayerViewModel` is injected into the environment as `@Environment(PlayerViewModel.self)` in existing views.
- Libraries/connections for filtering UI: `AppState.libraries: [Library]`, `activeLibraries`, `connections: [ServerConnection]`, `connectionsChanged: PassthroughSubject`. Media-type tab: `AppState.currentMediaType` (persisted), `showUnifiedLibrary`.
- Provider lookup for playback/covers stays behind the relevant engine or loader; use `EnveEngine.shared.playback.play` rather than fetching a provider from UI code.
- Collections: `AppState.collections` + `UserCollectionStore.shared` + `SmartCollectionStore.shared` (`bookStore.booksMatching(_:limit:)` evaluates smart collections in SQLite).
- Ebooks do not enter an audio engine: `PlaybackEngine.play` routes `mediaType == .ebook` through `ReaderOpenCoordinator`; ebook progress arrives through the reader locator pipeline and the progress repository.
