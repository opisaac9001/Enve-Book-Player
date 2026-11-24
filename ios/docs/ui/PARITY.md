# Feature parity

The SwiftUI layer must carry every feature of the original app. This table is the source of truth for parity.

| Feature | Status | Where |
|---|---|---|
| Home: continue/recent shelves, hero | Shipped | Hearth |
| Home: see-all lists, rotating quote, offline banner, last-sync line, Hardcover shelf, podcast Up Next | Shipped | Hearth + LibraryListScreen |
| Library: grid, search, status/media/sort chips, series/author facets, 50k paging | Shipped | Library |
| Library: multi-select bulk ops, list/grid toggle, source filter, narrators facet, cluster cards, OPDS/doc import entries, Collections + Shows facets | Shipped | Library |
| Book detail: actions, chapters, series, downloads, dual-format | Shipped | Detail |
| Book detail: metadata edit/merge, history, sync-status row, read-aloud formats, BookOrbit shelf statuses, debug info | Shipped | Detail + Matches |
| Player: transport, chapter ribbon, speed, sleep (EOC/shake), chapters, bookmarks, conflicts, dozed-off | Shipped | Player |
| Player: EQ/voice boost/mono/balance/noise/binaural/pitch, ambient audio mixing, audiobook clips + transcripts, Librarian entry | Shipped | Player + Librarian |
| Reader: EPUB/PDF/comic/HTML, trays, annotate, search, define, TTS, narrate | Shipped | Reader |
| Reader: Google Fonts UI, bionic toggle, TTS voice picker, read-aloud knobs, export annotations, Read Together, listen-along bar | Shipped | Reader |
| Podcasts: home (Up Next/New Episodes/Your Shows), iTunes browse+genres, subscribe, episode detail, stats | Shipped | Podcasts |
| Collections: smart (rule builder), manual (+editor/custom cover), server collections | Shipped | Collections |
| Dedup: clusters, merge review, version dialog, per-library toggles, unmerge | Shipped | Dedup |
| Matches: pending queue, per-book metadata match, ebook↔audiobook link, orphaned matcher, batch download | Shipped | Matches |
| Stats: week numbers, streak, heatmap, finished shelf, marginalia | Shipped | Journal |
| Stats: XP/levels, achievements, reader profile, top authors/books, hour histogram, per-service, goals editor + ring, library stats, stats import, per-media screens | Shipped | Journal |
| Hardcover: API-key connect | Shipped | Sources |
| Hardcover: hub (profile, goal, friends, trending, search, lists, history, match/reverse) | Shipped | Hardcover |
| Discover: Audible trending/bestsellers/new + detail/see-all | Shipped | Discover |
| Vocabulary: hub, flashcards (Leitner), settings | Shipped | Vocabulary |
| Obsidian: sync settings, template editor | Shipped | Sources |
| Sources: all server providers, Plex PIN, OIDC, QuickConnect, WebDAV presets, SMB, Files | Shipped | Sources |
| Sources: Google Drive/Dropbox/iCloud drives, SMB drill-down browse, per-connection Booklore↔KOReader, mTLS re-import, OPDS bulk import flow, drag-and-drop | Shipped | Sources |
| Settings: appearance/playback/sync/storage/about basics | Shipped | Sources |
| Settings: accessibility (vision mode), seasonal-icon toggle, player background pref, full playback prefs, library display, hidden books, recently deleted, dictionaries (StarDict), book sync, KOReader hub extras (links/hash/register), StoryAlign hub, storage depth, downloads views, tip jar, report issue, news, video cross-promo, diagnostics | Shipped | Sources |
| Server admin: ABS users/libraries/backups/stats, Plex, Jellyfin, Komga collections/read-lists, Grimmory users/shelves/magic shelves/stats | Shipped | Admin |
| Sleep timer full | Shipped | Player |
| CarPlay | Shipped | unchanged engine |
| Sync: CloudKit, KOReader, conflicts, sync center basics | Shipped | Sources/engine |
| Onboarding tour (replayable) | Shipped | Shell |
| Announcements (Discord) | Shipped | Shell/Sources |
| Read Together tvOS receiver target | Shipped target builds (shell repaired, exclusion list rebuilt) | enve-tvOS |
| Seasonal icon engine (stubbed in this variant originally) | Not applicable stub parity only | Sources toggle |

## Cross-package screen contract
`PodcastsHomeScreen()` · `PodcastBrowseScreen()` · `PodcastShowScreen(show: Book)` ·
`PodcastStatsScreen()` · `LibrarianChatScreen(book: Book)` · `CollectionsScreen()` ·
`CollectionDetailScreen(collection: Collection)` · `DedupSettingsScreen()` ·
`ClusterDetailScreen(cluster: BookCluster)` · `PendingMatchesScreen()` ·
`MetadataMatchScreen(book: Book)` · `EbookAudiobookMatchScreen(book: Book)` ·
`MetadataEditScreen(book: Book)` · `MetadataBatchScreen()` · `OrphanedBookMatcherScreen()` ·
`HardcoverHubScreen()` · `DiscoverScreen()` · `AchievementsScreen()` · `StatsImportScreen()` ·
`VocabularyHubScreen()` · `AdminHubScreen(connection: ServerConnection)` ·
`LibraryListScreen(title: String, books: [Book])`
