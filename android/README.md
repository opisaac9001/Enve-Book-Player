# Enve Book Player for Android

Enve is a native Android audiobook and ebook player for local libraries and self-hosted media servers. It is one half of a pair — the iOS app is developed alongside it and the two deliberately share architecture and naming.

Project site: [envemedia.com/books](https://envemedia.com/books/)

## Features

- Audiobook playback on Media3 with chapters, bookmarks, sleep timer, playback queue, speed and skip controls, audio effects, and Chromecast
- Ebook reading on Readium and Foliate, plus PDF, comic, and MOBI readers
- Annotations, highlights, notes, vocabulary, and Markdown/Obsidian export
- Offline downloads with resumable transfers, and progress sync back to the server
- Reading statistics, series and collection browsing, and metadata editing
- StoryAlign read-along generation from a matching ebook and audiobook
- A first-class e-ink mode with hardware detection and EPD refresh control
- A Wear OS companion for transport control and sleep tracking
- Automation via Android media controllers and broadcast intents

## Sources

Enve connects to media servers, network storage, and local files. From **Add source**:

- **Media servers** — Audiobookshelf, Plex, Jellyfin, Emby, Grimmory, Storyteller, Silo, Komga, Kavita, BookOrbit, OPDS
- **Cloud and network storage** — WebDAV, SMB, TorBox, Premiumize, Real-Debrid
- **Local** — files on the device

Feature depth varies by backend. A server only supports what its API exposes, so progress sync, metadata writes, and admin tools are available for some sources and not others.

## Requirements

- Android Studio with JDK 17 or newer
- Android SDK 36
- Android NDK 27.2.12479018
- Android 8.0 (API 26) or newer to run the app; the Wear companion needs Wear OS on API 30 or newer

## Building

Clone the combined repository with submodules, then enter the Android directory. Each platform keeps its own pinned Foliate checkout so it can build independently.

```sh
git clone --recurse-submodules https://github.com/opisaac9001/Enve-Book-Player.git
cd Enve-Book-Player/android
```

Build the debug APK:

```sh
./gradlew :app:assembleDebug
```

Run the unit tests and the minified release build:

```sh
./gradlew :app:testDebugUnitTest :app:assembleRelease
```

The release build is unsigned. Use your own signing configuration for a distributable APK or app bundle. Never commit a keystore, signing password, server credential, private URL, downloaded book, or diagnostic export.

## Repository layout

- `app/` — application shell, login and reader Activities, manifest
- `core/` — shared models, persistence, credential vault, network infrastructure
- `engine-api/` — the facade contracts available to the UI
- `engine/` — playback, readers, sync, downloads, e-ink, native code, backend implementations
- `hearth-ui/` — the Compose UI, depending only on `core` and `engine-api`
- `audiobookshelf/`, `bookorbit/`, `komga/`, `local/`, `plex/`, `silo/`, `storyteller/` — provider modules
- `wear/`, `wear-protocol/` — Wear OS companion app and the messages it shares with the phone
- `ThirdParty/` — vendored upstream source, licences, and reference assets
- `BuildSupport/` — reproducible build inputs and provenance
- `docs/` — architecture, guides, testing, and release documentation
- `scripts/` — repository checks and developer tools

## Documentation

Start at [docs/README.md](docs/README.md).

- [DEVELOPMENT.md](DEVELOPMENT.md) — setup, project shape, common changes, verification
- [docs/architecture/module-boundaries.md](docs/architecture/module-boundaries.md) — module layout and the UI/backend wall
- [docs/architecture/engine-api.md](docs/architecture/engine-api.md) — the facade contract the UI calls
- [docs/architecture/eink.md](docs/architecture/eink.md) — e-ink detection, refresh policy, and design degradation
- [docs/guides/automation.md](docs/guides/automation.md) — Tasker and broadcast-intent control

## Contributing and support

Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request. Report vulnerabilities through the private process in [SECURITY.md](SECURITY.md), never in a public issue. For product questions, setup help, and bug reports, use [Enve Support](https://github.com/opisaac9001/Enve-Support) or the [Enve documentation](https://envemedia.com/docs/).

### AI-ready development

The Android source includes [AGENTS.md](AGENTS.md) and [CLAUDE.md](CLAUDE.md) so coding agents can discover the architecture, build commands, and project constraints before editing. Security-sensitive files carry an agent-lock marker and require the user to configure a local password before an agent may inspect or change them. The lock is a workflow guardrail, not access control; contributors remain responsible for reviewing and testing every change. See [AI_POLICY.md](AI_POLICY.md) for the contribution requirements.

If Enve is useful to you, you can [support its development on Buy Me a Coffee](https://buymeacoffee.com/envebookplayer).

## License

Enve is source-available under the [Enve Noncommercial Public Source License](../LICENSE.md). Commercial use, paid redistribution, advertising, monetization, and closed-source forks are prohibited. This is not an OSI-approved open-source license.

Third-party components remain under their respective licenses. Redistributions must retain [NOTICE.md](NOTICE.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and the license files shipped with vendored components. The [third-party audit](docs/legal/THIRD_PARTY_AUDIT.md) lists requirements that must be resolved before distributing an APK or app bundle.
