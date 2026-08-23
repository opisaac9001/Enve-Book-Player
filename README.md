<p align="center">
  <img src="./screenshots/enve-book-player.svg" alt="Enve Book Player" width="180">
</p>

<h1 align="center">Enve Book Player</h1>

<p align="center">
  Native iOS and Android apps for audiobooks, ebooks, comics, and podcasts from your own files and self-hosted libraries.
</p>

<p align="center">
  <a href="https://envemedia.com/books/"><img src="https://img.shields.io/badge/iOS-TestFlight-F5921A?style=for-the-badge&logo=apple&logoColor=white" alt="Get Enve Book Player"></a>
  <a href="https://envemedia.com/books/#android"><img src="https://img.shields.io/badge/Android-open%20testing-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Test Enve Book Player for Android"></a>
  <a href="https://github.com/opisaac9001/Enve-Book-Player/actions/workflows/ios.yml"><img src="https://img.shields.io/github/actions/workflow/status/opisaac9001/Enve-Book-Player/ios.yml?branch=main&style=for-the-badge&label=iOS" alt="iOS CI status"></a>
  <a href="https://github.com/opisaac9001/Enve-Book-Player/actions/workflows/android.yml"><img src="https://img.shields.io/github/actions/workflow/status/opisaac9001/Enve-Book-Player/android.yml?branch=main&style=for-the-badge&label=Android" alt="Android CI status"></a>
  <a href="https://github.com/opisaac9001/Enve-Book-Player/issues"><img src="https://img.shields.io/github/issues/opisaac9001/Enve-Book-Player?style=for-the-badge&color=F5921A" alt="Open issues"></a>
  <a href="https://github.com/opisaac9001/Enve-Book-Player/discussions"><img src="https://img.shields.io/badge/GitHub-Discussions-24292F?style=for-the-badge&logo=github" alt="GitHub Discussions"></a>
  <a href="https://discord.gg/Hw4nmXRehb"><img src="https://img.shields.io/badge/Discord-community-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join the Discord community"></a>
  <a href="https://buymeacoffee.com/envebookplayer"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=000000" alt="Support Enve on Buy Me a Coffee"></a>
  <a href="./LICENSE.md"><img src="https://img.shields.io/badge/license-source--available-1F2937?style=for-the-badge" alt="Source-available license"></a>
</p>

Enve brings listening and reading together without requiring an Enve account, subscription, or cloud service. Connect the servers you already run, import local files, and keep your library and progress under your control.

This repository contains both editions: the Swift app under [`ios/`](ios/) and the Kotlin/Compose app under [`android/`](android/). The two apps share product behavior and architectural vocabulary while remaining native to their platforms.

The public repository follows stable releases. Day-to-day development happens privately, so `main` is updated in reviewed, release-sized snapshots rather than carrying unfinished work.

## What it does

| | |
| :---: | --- |
| 🎧 | **Listen** — Audiobooks and podcasts with chapters, queues, sleep timers, bookmarks, CarPlay, and offline downloads. |
| 📖 | **Read** — EPUB books and comics with a native Readium-based reader, annotations, themes, and reading controls. |
| 🔄 | **Keep your place** — Playback and reading progress sync with supported servers and optional sync services. |
| 📚 | **Bring libraries together** — One library across multiple sources, with duplicate-edition merging where possible. |
| 🔊 | **Read along** — Synchronized text and audio for compatible books. |
| 📊 | **Track and organize** — Collections, smart shelves, reading statistics, a journal, widgets, and platform companion experiences. |

## Screenshots

These screenshots show the iOS edition. Android follows the same Enve product direction with a native Compose interface.

<p align="center">
  <img src="./screenshots/ios/home.png" alt="Enve home screen" width="250">
  <img src="./screenshots/ios/library.png" alt="Library" width="250">
  <img src="./screenshots/ios/book-details.png" alt="Book details" width="250">
</p>

<p align="center">
  <img src="./screenshots/ios/now-playing.png" alt="Audiobook player" width="250">
  <img src="./screenshots/ios/reader.png" alt="Ebook reader" width="250">
  <img src="./screenshots/ios/read-along.png" alt="Read-along player" width="250">
</p>

## Supported libraries and services

Enve works with local files and a broad range of self-hosted services:

| | Supported sources |
| :---: | --- |
| 🎧 | **Audiobook and media servers:** Audiobookshelf, Plex, Jellyfin, Emby, Storyteller, Grimmory, BookOrbit, and Silo |
| 📚 | **Comics and ebooks:** Komga, Kavita, and OPDS catalogs |
| 🗂️ | **Files and feeds:** Local files, WebDAV, SMB, and RSS podcasts |
| ☁️ | **Cloud and debrid:** Premiumize, Real-Debrid, and TorBox |

Provider capabilities differ. The [documentation](https://envemedia.com/docs/) has current setup instructions and service-specific notes.

## Get the app

Current TestFlight, Android testing, and availability information lives on the [Enve Book Player page](https://envemedia.com/books/). Enve is free, contains no advertising or analytics, and does not place a cloud service between the app and your library.

## Repository layout

| Platform | Source | Development guide | CI |
| --- | --- | --- | --- |
| iOS, iPadOS, watchOS, tvOS | [`ios/`](ios/) | [ios/DEVELOPMENT.md](ios/DEVELOPMENT.md) | [iOS CI](https://github.com/opisaac9001/Enve-Book-Player/actions/workflows/ios.yml) |
| Android and Wear OS | [`android/`](android/) | [android/DEVELOPMENT.md](android/DEVELOPMENT.md) | [Android CI](https://github.com/opisaac9001/Enve-Book-Player/actions/workflows/android.yml) |

## Building from source

Clone once with submodules for either platform:

```sh
git clone --recurse-submodules https://github.com/opisaac9001/Enve-Book-Player.git
cd Enve-Book-Player
```

### iOS

You need Xcode 26.4 or newer, an Apple-silicon Mac, and an iOS 17 or newer deployment target.

```sh
cd ios
open enve.xcodeproj
```

Let Swift Package Manager resolve dependencies, then build the `enve` scheme for an Apple-silicon iOS Simulator. Device builds require your own Apple development team, bundle identifiers, and entitlements. Optional Google Drive and Dropbox support also require developer-owned OAuth applications.

The complete iOS setup and signing notes are in [ios/DEVELOPMENT.md](ios/DEVELOPMENT.md).

### Android

You need Android Studio, JDK 17 or newer, Android SDK 36, and Android NDK 27.2.12479018. Android 8.0 (API 26) is the minimum supported version.

```sh
cd android
./gradlew :app:assembleDebug
```

The release build is unsigned and requires your own signing configuration. See [android/README.md](android/README.md) and [android/DEVELOPMENT.md](android/DEVELOPMENT.md) for the module map, device commands, Wear OS target, and full verification workflow.

## Contributing

Bug fixes, accessibility improvements, provider work, documentation, and focused features are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md); Android contributors should also read [android/CONTRIBUTING.md](android/CONTRIBUTING.md). Use [Discussions](https://github.com/opisaac9001/Enve-Book-Player/discussions) for questions and early ideas, and Issues for reproducible bugs or agreed work.

For app support and setup questions, use the central [Enve Support repository](https://github.com/opisaac9001/Enve-Support) or [Discord](https://discord.gg/Hw4nmXRehb). Please report security problems privately as described in [SECURITY.md](SECURITY.md).

<details>
<summary><strong>Using a coding agent</strong></summary>

This repository includes detailed instructions for coding agents. Start with the root [`CLAUDE.md`](CLAUDE.md) and [`AGENTS.md`](AGENTS.md), then use the platform guides under [`ios/`](ios/) or [`android/`](android/) before changing application code.

Files beginning with `// AGENT-LOCKED` have extra safeguards because they are easy to break without understanding their invariants. The owner-set password is local and advisory: it guides cooperative tools, but it is not encryption or a security boundary. Human contributors can inspect the source normally and should edit protected files only when they understand and can fully test the affected behavior.

</details>

## Important links

| Resource | Link |
| --- | --- |
| Enve Media | [envemedia.com](https://envemedia.com/) |
| iOS Book Player and downloads | [envemedia.com/books](https://envemedia.com/books/) |
| Android edition | [Source](android/) · [Status and open testing](https://envemedia.com/books/#android) |
| Documentation | [envemedia.com/docs](https://envemedia.com/docs/) |
| FAQ | [envemedia.com/faq](https://envemedia.com/faq.html) |
| Questions and ideas | [GitHub Discussions](https://github.com/opisaac9001/Enve-Book-Player/discussions) |
| Bugs and tracked work | [GitHub Issues](https://github.com/opisaac9001/Enve-Book-Player/issues) |
| General Enve support | [Enve Support](https://github.com/opisaac9001/Enve-Support) |
| Community | [Discord](https://discord.gg/Hw4nmXRehb) |
| Support development | [Buy Me a Coffee](https://buymeacoffee.com/envebookplayer) |

## License

Enve is **source-available**, not OSI open source. It is distributed under the [Enve Noncommercial Public Source License](LICENSE.md). Personal use, study, modification, and noncommercial community contributions are permitted. Commercial use, paid redistribution, advertising, monetization, and closed-source forks are prohibited.

[Third-party notices](THIRD_PARTY_NOTICES.md) list the licenses and attribution requirements for dependencies, bundled resources, and provider artwork. They are legal notices for redistribution, not additional setup instructions.
