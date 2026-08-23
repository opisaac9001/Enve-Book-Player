# Changelog

Release notes for the Android app. Versions are `<name> build <code>`, matching `versionName` and `versionCode` in `app/build.gradle.kts`.

## Unreleased

Current version: **1.2 build 44**.

Notes were not written for builds 30 through 44. Notable additions visible in the current source since build 29, without a build attribution:

- Wear OS companion app with transport control, recent books, and sleep-timer control
- Sleep tracking backed by Health Connect
- Server tools hub — per-connection stats, achievements, highlights, bookmarks, and history
- BookOrbit and Silo providers, and BookOrbit reading insights
- Playback automation contract for broadcast-intent control
- EPUB page labels in the reader, offline-first opening of downloaded ebooks, and expanded text-selection tools

This list is incomplete and should be reconciled with the release notes before the next release.

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
