# Enve Book Player for Android

Enve is a native Android audiobook and ebook player for local libraries and self-hosted media servers. It supports Audiobookshelf, Plex, BookOrbit, Silo, Storyteller, Komga, Grimmory, Jellyfin, Emby, Kavita, OPDS, WebDAV, SMB, and local files.

The app includes audiobook playback, a Readium and Foliate based reader, downloads, progress sync, Chromecast playback, reading statistics, annotations, StoryAlign read-along generation, and an e-ink mode.

## Requirements

- Android Studio with JDK 17 or newer
- Android SDK 36
- Android NDK 27.2.12479018
- Android 8.0 or newer

## Building

Clone the repository with its Foliate submodule:

```sh
git clone --recurse-submodules <repository-url>
cd <repository-directory>
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

- `app/` contains the Android application shell and reader activities.
- `core/` contains shared models, persistence, credentials, and network infrastructure.
- `engine-api/` defines the backend facades available to the UI.
- `engine/` contains playback, reader, sync, download, and backend implementations.
- `hearth-ui/` contains the Compose UI and depends only on `core` and `engine-api`.
- Provider modules such as `audiobookshelf/`, `komga/`, `plex/`, and `storyteller/` own their provider integrations.
- `ThirdParty/` contains vendored upstream source.
- `BuildSupport/` contains reproducible build inputs and provenance.
- `docs/` contains architecture, testing, and release notes.

See [DEVELOPMENT.md](DEVELOPMENT.md) for setup and architecture details. Read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Automated coding tools must follow [AGENTS.md](AGENTS.md) and [AI_POLICY.md](AI_POLICY.md).

## License

Enve is source-available under the [Enve Noncommercial Public Source License](LICENSE.md). Commercial use, paid redistribution, advertising, monetization, and closed-source forks are prohibited. This is not an OSI-approved open-source license.

Third-party components remain under their respective licenses. Redistributions must retain [NOTICE.md](NOTICE.md), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), and the license files shipped with vendored components. The [third-party audit](docs/legal/THIRD_PARTY_AUDIT.md) lists requirements that must be resolved before distributing an APK or app bundle.
