# Changelog

Release notes for the Android app. Versions are `<name> build <code>`, matching `versionName` and `versionCode` in `app/build.gradle.kts`.

## Unreleased

- Removed the duplicate orange library loading indicator; pull-to-refresh keeps its grey spinner.

## 1.2 build 53 — 2026-10-09

- Added separate user profiles with isolated settings, history, downloads, and sync state.
- Scoped provider caches and progress writes to the correct server and account.
- Improved Android Auto checkpoints and resume handling.
- Fixed retry counts, cancellation, concurrent KOReader link updates, and streamed-comic cleanup.
- Respected manual and provider-supplied comic reading direction.
- Removed unused sync code and expanded regression tests and contributor setup checks.

## 1.2 build 52 — 2026-09-28

Changes since the Android build 51 public snapshot.

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

### Android

- Added cards to Continue Reading and Continue Listening with progress, chapter, and time or page, plus a matching top card with Read and Listen buttons for paired books.
- Jellyfin and Emby progress now syncs; it was being skipped.
- Opening a book's details or downloading no longer interrupts your Audiobookshelf listening session, and each install has its own device ID for Audiobookshelf and Komga.
- Grimmory sessions that fail to upload are retried, and the stats screen uses your recorded listening time.
- The Stats Hub says when Audiobookshelf can't be reached and offers a retry.
- Added standalone Wear OS listening for Audiobookshelf and Grimmory, with phone-based linking, offline downloads, playback, and progress sync.
- StoryAlign keeps the previous read-aloud book when a new alignment scores worse. You can restore the earlier version yourself.
- Fixed BookOrbit highlights with attached notes not appearing in the reader.
- Fixed reader page restoration, PDF page counts, comic edge taps, and highlight handles across paragraphs.
- Removed unavailable libraries during refresh and stopped requesting covers for missing books.
- Fixed repeated progress updates after an audiobook finishes and preserved reading positions when toggling reader controls.
- Improved podcast episode lists, search labels, and large-library queries.
- Added a configurable rest-your-eyes reminder.

## 1.2 build 46 — 2026-08-29

### Added

- Wear OS companion app with transport control, recent books, and sleep-timer control
- Sleep tracking backed by Health Connect
- Server tools hub — per-connection stats, achievements, highlights, bookmarks, and history
- BookOrbit and Silo providers, and BookOrbit reading insights
- Playback automation contract for broadcast-intent control
- Android Auto browsing, playback controls, voice search, and artwork
- EPUB page labels in the reader, offline-first opening of downloaded ebooks, and expanded text-selection tools

### Distribution and privacy

- Added in-app open-source acknowledgements and an exact release dependency inventory.
- Pinned Enve-managed Qwen and Whisper model downloads to verified revisions and SHA-256 digests.
- Added model download disclosures and expanded Health Connect, Google service, and model-download privacy disclosures.
- Recorded exact libmobi, whisper.cpp, and jcifs-ng provenance and LGPL replacement instructions.

### Pending release-candidate verification

- Android Auto on a compatible car or Desktop Head Unit.
- Wear controls and sleep-timer behavior on physical Wear OS hardware.
- Remote and downloaded playback on physical Cast hardware.
- Komga reading-direction behavior with an affected library.

## 1.2 build 29 — 2026-07-22

### Added

- Chromecast support for remote audiobooks and locally downloaded audio.
- Persistent playback queue with Play All actions.
- Volume leveling with configurable strength.
- Automatic offline downloads for upcoming books in started series.
- Android Assistant actions to resume playback or play a downloaded audiobook.
- Multi-select actions for adding books to collections.
- Media-notification controls for configurable rewind, fast-forward, play or pause, and next chapter.

### Fixed and improved

- Restored Audiobookshelf in-progress catalog loading and improved refresh fallback behavior.
- Corrected Audiobookshelf ebook classification.
- Applied Komga RTL/LTR reading-direction metadata and persisted per-book overrides.
- Made the Now Playing notification open Enve when its non-control area is tapped.
- Updated the EPUB reader to the current Readium implementation and fixed a Compose crash when opening books.
- Improved BookOrbit progress sync.
- Fixed Emby authentication routing and cover artwork.
- Filtered non-book libraries from supported media-server sources.
- Improved empty-library onboarding and Android 16 compatibility.

### Pending verification

- Komga RTL/LTR metadata and per-book overrides still need confirmation with an affected Komga library.
- Notification tap behavior and configurable playback controls still need confirmation on a release build.
- Chromecast playback for both remote and downloaded local media still needs end-to-end testing on physical Chromecast hardware.
