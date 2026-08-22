<p align="center">
  <img src="./assets/enve-book-player.svg" alt="Enve Book Player" width="180">
</p>

<h1 align="center">Enve Book Player</h1>

<p align="center">
  A native iPhone and iPad app for audiobooks, ebooks, comics, and podcasts from your own files and self-hosted libraries.
</p>

<p align="center">
  <a href="https://envemedia.com/books/"><img src="https://img.shields.io/badge/iOS-TestFlight-F5921A?style=for-the-badge&logo=apple&logoColor=white" alt="Get Enve Book Player"></a>
  <a href="https://github.com/opisaac9001/Enve-Book-Player/actions/workflows/ios-ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/opisaac9001/Enve-Book-Player/ios-ci.yml?branch=main&style=for-the-badge&label=build" alt="iOS CI status"></a>
  <a href="https://github.com/opisaac9001/Enve-Book-Player/issues"><img src="https://img.shields.io/github/issues/opisaac9001/Enve-Book-Player?style=for-the-badge&color=F5921A" alt="Open issues"></a>
  <a href="https://discord.gg/Hw4nmXRehb"><img src="https://img.shields.io/badge/Discord-community-5865F2?style=for-the-badge&logo=discord&logoColor=white" alt="Join the Discord community"></a>
  <a href="https://buymeacoffee.com/envebookplayer"><img src="https://img.shields.io/badge/Buy%20Me%20a%20Coffee-support-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=000000" alt="Support Enve on Buy Me a Coffee"></a>
  <a href="./LICENSE.md"><img src="https://img.shields.io/badge/license-source--available-1F2937?style=for-the-badge" alt="Source-available license"></a>
</p>

Enve brings listening and reading together without requiring an Enve account, subscription, or cloud service. Connect the servers you already run, import local files, and keep your library and progress under your control.

The public repository follows stable releases. Day-to-day development happens privately, so `main` is updated in reviewed, release-sized snapshots rather than carrying unfinished work.

## What it does

- Plays audiobooks and podcasts with chapters, queue management, sleep timers, bookmarks, CarPlay, and offline downloads.
- Reads EPUB books with a native Readium-based reader, annotations, themes, and reading controls.
- Keeps books from different sources in one library and merges duplicate editions where possible.
- Syncs playback and reading progress with supported servers and optional sync services.
- Supports read-along books with synchronized text and audio.
- Includes collections, smart shelves, reading statistics, a reading journal, widgets, and a watchOS companion.

## Screenshots

<p align="center">
  <img src="./assets/screenshots/home.png" alt="Enve home screen" width="250">
  <img src="./assets/screenshots/library.png" alt="Library" width="250">
  <img src="./assets/screenshots/book-details.png" alt="Book details" width="250">
</p>

<p align="center">
  <img src="./assets/screenshots/now-playing.png" alt="Audiobook player" width="250">
  <img src="./assets/screenshots/reader.png" alt="Ebook reader" width="250">
  <img src="./assets/screenshots/read-along.png" alt="Read-along player" width="250">
</p>

## Supported libraries and services

Enve works with local files and self-hosted services, including:

- Audiobookshelf
- Plex, Jellyfin, and Emby
- Booklore and Grimmory
- Storyteller
- Komga and Kavita
- OPDS catalogs
- WebDAV and SMB
- Silo
- RSS podcasts
- Premiumize, Real-Debrid, and TorBox

Provider capabilities differ. The [documentation](https://envemedia.com/docs/) has current setup instructions and service-specific notes.

## Get the app

Current TestFlight and availability information lives on the [Enve Book Player page](https://envemedia.com/books/). Enve is free, contains no advertising or analytics, and does not place a cloud service between the app and your library.

## Building from source

You need Xcode 26.4 or newer, an Apple-silicon Mac, and an iOS 17 or newer deployment target.

```sh
git clone --recurse-submodules https://github.com/opisaac9001/Enve-Book-Player.git
cd Enve-Book-Player
open enve.xcodeproj
```

Let Swift Package Manager resolve dependencies, then build the `enve` scheme for an Apple-silicon iOS Simulator. Device builds require your own Apple development team, bundle identifiers, and entitlements. Optional Google Drive and Dropbox support also require developer-owned OAuth applications.

The complete setup and signing notes are published with the source in `DEVELOPMENT.md`.

## AI-ready development

Enve is set up for contributors who use coding agents as well as those who work directly in Xcode. [`CLAUDE.md`](CLAUDE.md) contains the app's architecture, build, and verification guidance, while [`AGENTS.md`](AGENTS.md) defines repository-wide rules that apply to any coding agent, regardless of vendor or model.

Some especially sensitive source files begin with `// AGENT-LOCKED`. These files contain behavior that can be easy to break without understanding the surrounding invariants. Agents must not inspect or edit their contents unless the repository owner has authorized that specific work and the owner-set advisory password has been verified with `./scripts/agent-lock`. The password and verification state are local and are never committed.

The lock is a guardrail for cooperative tools, not encryption or a security boundary. Human contributors can read the source normally, but should change protected files only when they understand the relevant architecture and can fully test the result. Start by giving your agent the repository root and asking it to read `CLAUDE.md`, `AGENTS.md`, and `DEVELOPMENT.md` before making changes.

## Contributing

Bug fixes, accessibility improvements, provider work, documentation, and focused features are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and open an issue before undertaking a large feature, architectural change, or new dependency.

For app support and setup questions, use the central [Enve Support repository](https://github.com/opisaac9001/Enve-Support) or [Discord](https://discord.gg/Hw4nmXRehb). Please report security problems privately as described in [SECURITY.md](SECURITY.md).

## Important links

| Resource | Link |
| --- | --- |
| Enve Media | [envemedia.com](https://envemedia.com/) |
| Book Player and downloads | [envemedia.com/books](https://envemedia.com/books/) |
| Documentation | [envemedia.com/docs](https://envemedia.com/docs/) |
| FAQ | [envemedia.com/faq](https://envemedia.com/faq.html) |
| Bug reports and source requests | [GitHub issues](https://github.com/opisaac9001/Enve-Book-Player/issues) |
| General Enve support | [Enve Support](https://github.com/opisaac9001/Enve-Support) |
| Community | [Discord](https://discord.gg/Hw4nmXRehb) |
| Support development | [Buy Me a Coffee](https://buymeacoffee.com/envebookplayer) |

## License

Enve is **source-available**, not OSI open source. It is distributed under the [Enve Noncommercial Public Source License](LICENSE.md). Personal use, study, modification, and noncommercial community contributions are permitted. Commercial use, paid redistribution, advertising, monetization, and closed-source forks are prohibited. Third-party components remain under their own licenses.
