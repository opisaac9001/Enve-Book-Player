# Changelog

## 1.2.6 — 2026-10-09

- Added separate user profiles with isolated settings, history, downloads, and sync state.
- Fixed stale sync work and profile switches affecting the wrong user.
- Improved provider integrations, reader interactions, and streamed-comic handling.
- Removed unused services and simplified shared ownership of playback and downloads.
- Expanded regression tests and contributor setup checks.

## 1.2.5 — 2026-09-28

Changes since the iOS 1.2.3 public snapshot.

### Reading and sync

- Added passages to reading-position conflicts so you can see where each device left off.
- Fixed stale positions overwriting newer server progress when opening a book. Enve also recognises deliberate rewinds and ignores its own sync updates.
- Improved Audiobookshelf listen-along resume, EPUB positions, and chapter matching. An empty reading or listening position no longer replaces a saved one.
- Imported highlights are checked against the book text. Highlights that cannot be located stay saved and are retried.
- KOReader links now detect replaced EPUB files and update their hashes.
- Expanded OPDS browsing, downloads, sign-in, and reading-progress support.
- Fixed provider metadata and progress handling for Komga, Kavita, Grimmory, Jellyfin, Emby, and TorBox.
- Listening on downloaded or offline Audiobookshelf books now counts in Audiobookshelf's listening stats, and listening time is no longer lost when a sync fails.
- Jellyfin, Emby, Plex, and Silo show Enve in Now Playing and record listening in their play history. Jellyfin no longer resets positions early in an audiobook, and other apps resume multi-file books on the right file.
- Kavita reading statistics load again, and finishing a book reaches its last page so Kavita counts it.
- Grimmory receives one session per stretch of listening with active reading time and the correct file type. BookOrbit sessions also use active time.
- Plex progress is saved per track on both platforms, so iOS and Android share positions.

### iOS

- Added cards to Continue Reading and Continue Listening with progress, chapter, and time or page, plus a matching top card with Read and Listen buttons for paired books.
- The Stats Hub loads quickly on large Grimmory libraries, shows your own stats while servers respond, and no longer counts listening twice.
- Hardcover no longer creates a new read on every launch, keeps finish dates, and records audiobook time.
- Fixed listening time reported at playback speed and the end of each session going unreported.
- Fixed Journal days and best-day labels showing the previous day.
- Added OneDrive connection support.
- Fixed tvOS target membership and chapter handling for the new OneDrive source.
- Quick Sync keeps the previous calibration when a new match scores worse. You can restore it from the match screen.
- Fixed BookOrbit opening the wrong cached file when book IDs share a prefix.
- Improved chapter labels, search snippets, podcast episode lists, and series counts.
- Added a configurable rest-your-eyes reminder and improved text selection and highlight removal.
- Fixed overlapping text-selection menus in Foliate and added missing accessibility labels.

## 1.2 (117) — 2026-07-31

### Fixed

- Reworked Storyteller reading-location sync to use the same timestamp-based position rules as Silveran Reader, preventing a book from reopening at an unrelated location.
- Moved Storyteller location updates into a dedicated sync pipeline, so they no longer affect the sync behavior of Audiobookshelf, Plex, Komga, Grimmory, or other services.
- Preserved pending Storyteller positions across app restarts and prevented stale server responses or older requests from overwriting a newer reading location.
- Correctly detect read-aloud EPUBs even when media-overlay metadata is incomplete, so Storyteller books use the appropriate reading and audio behavior.
- Improved in-book quote search: searches now tolerate punctuation and typographic apostrophe differences, and long quotes are no longer constrained to a short matching window.

### Maintained

- Added automated coverage for Storyteller position ordering and read-aloud quote search behavior to help prevent regressions.

## 1.2 (116) — 2026-07-29

### Added

- Apple Watch companion app with library browsing, search, cover art, now-playing controls, standalone streaming, offline downloads, and phone-to-watch playback handoff.
- Dual EPUB reader support with Readium and Foliate, per-book engine selection, automatic themes, improved open preparation, and safer Notes captures.
- Native EPUB footnote popovers in both reader engines.
- Finish Line completion center for reviewing and completing nearly finished books.
- Reading Insights and annual reading review in the Journal.
- Stackable Library filters for combining media, status, source, and metadata criteria.
- Series auto-advance and an optional bedtime window that automatically starts a sleep timer.
- Settings backup and restore from Data Management.
- Audiobookshelf chapter editor with Audnexus chapter lookup.
- Native Komga OAuth sign-in.
- Enve Quick Sync calibration, legacy Quick Sync fallback, and expanded linked ebook/audiobook synchronization.
- Home ordering and startup destination preferences.
- Source-provider rating synchronization.
- Batch library metadata matching.
- Broader accessibility labels, traits, and navigation foundations.

### Reading and playback

- Improved linked ebook/audiobook progress mapping, chapter alignment, downloads, and Storyteller read-aloud position sync.
- Improved reader margins from edge-to-edge through wide gutters, including correct zero-margin Foliate behavior and proportional Classic Reader gutters.
- Dismissed text-selection tools when tapping outside a selection.
- Preserved Plex album boundaries when grouping audiobook tracks.
- Improved local audiobook cover discovery and M4B chapter extraction.
- Hardened Apple Watch streaming, downloads, remote controls, background audio, and phone protocol behavior.
- Audited and corrected CarPlay playback, downloads, search, chapters, and now-playing behavior.

### Library, sources, and metadata

- Corrected Grimmory audiobook imports when server metadata repeats one folder title across many books: Enve now uses each audiobook filename, retrieves duration and metadata, loads the correct cover endpoint, and prevents duration-less audiobooks from being merged.
- Refresh now performs a full visible-scope reconciliation, waits for completion, refreshes server collections, and presents user-facing progress.
- Corrected Grimmory regular shelf and Magic Shelf discovery, membership, dates, and collection refresh behavior.
- Purged stale catalog rows when a source or server library is removed.
- Improved Komga series mapping, comic metadata, publisher details, release dates, page counts, and format classification.
- Improved settings, source, and library refresh performance for large catalogs.
- Added privacy manifests and aligned release configuration across the iOS app, widgets, and Apple Watch app.

### Interface

- Aligned book and podcast artwork consistently across Library, facet, detail, collection, Journal, and podcast grids when titles wrap to different line counts.
- Added visible collection-refresh status and progress.
- Consolidated legacy Browse behavior into the current Library and discovery surfaces.

### Removed and maintained

- Removed the unfinished ReadMeABook request and upcoming-release discovery integrations before release.
- Removed unused PulseUI, Whisper, ReadiumOPDS linkage, obsolete assets, dead code, and retired services.
- Declared exempt encryption and tightened production privacy, logging, playback, and App Store configuration.

## 1.2 (115) — 2026-07-22

### Added

- Persistent playback queue with Play All actions for grouped library views.
- Volume leveling with low, medium, and high strength settings.
- Automatic offline downloads for upcoming items in started series and followed podcasts.
- Automatic queueing for newly published podcast episodes.
- Siri actions to resume the current audiobook or play a downloaded book.
- Multi-select actions for adding books to playlists and collections.

### Fixed and improved

- Improved Komga comic recognition, format handling, and series metadata.
- Improved browser-session authentication for Cloudflare and other cookie-based access proxies.
- Preserved Xcode Cloud, widget, and app build configuration consistency.

### Pending verification

- Komga comic classification and series metadata still need confirmation against affected live libraries.
- Browser-session proxy authentication still needs confirmation against a protected live server.
- Siri voice invocation still needs final physical-device verification.
