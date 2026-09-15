# Enve Book Player

Enve is a native Swift audiobook and ebook player for local libraries and self-hosted media servers. It supports Audiobookshelf, Plex, Jellyfin, Emby, Booklore/Grimmory, Storyteller, Komga, Kavita, OPDS, WebDAV, SMB, and local files.

The iOS app includes audiobook playback, a Readium-based EPUB reader, library deduplication, downloads, progress sync, CarPlay, reading statistics, annotations, and read-along support. A tvOS target is included in the same project.

## Requirements

- Xcode 26.4 or newer
- iOS 17 or newer
- Swift 6

## Building

Clone the repository with its Foliate submodule:

```sh
git clone --recurse-submodules <repository-url>
cd <repository-directory>
```

Open `enve.xcodeproj`, let Swift Package Manager resolve dependencies, and build the `enve` scheme.

From the command line:

```sh
xcodebuild -project enve.xcodeproj -scheme enve -showdestinations

xcodebuild -project enve.xcodeproj \
  -scheme enve \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  build
```

Use an Apple-silicon simulator destination. FluidAudio's bundled text-processing library does not include an x86_64 simulator slice, so a generic multi-architecture simulator build will not link.

The app accepts user-supplied server addresses, including local HTTP servers. Do not commit server credentials, API keys, or exported diagnostic data.

### Optional OAuth providers

Google Drive and Dropbox require developer-owned OAuth applications. Copy the example configuration and supply your registered client identifiers:

```sh
cp enve/Configuration/DeveloperSettings.example.plist \
  enve/Configuration/DeveloperSettings.plist
```

`DeveloperSettings.plist` is ignored by Git. Its redirect scheme must match the scheme registered with each OAuth provider. These providers remain unavailable when their client identifier is empty.

### Device signing

Simulator builds do not require an Apple Developer account. Device builds require selecting your own development team in Xcode. CloudKit, App Groups, push notifications, HealthKit, CarPlay, widgets, and the Watch app use Enve's production identifiers and entitlements; forks must register their own identifiers and update the corresponding project settings and entitlements.

## Repository layout

- `enve/` — main iOS application, features, domain services, providers, persistence, and reader engine
- `EnveWatch/` — watchOS companion app
- `enve-tvOS/` — tvOS app
- `EnveBookWidgets/` — WidgetKit extension
- `EnveBookShared/` — models shared between selected targets
- `LocalPackages/` — maintained wrappers and pinned source dependencies
- `docs/` — architecture, UI contracts, backend references, and legal notes

Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing source ownership or adding a subsystem. The [documentation index](docs/README.md) routes to architecture, UI, backend, and distribution references.

See [DEVELOPMENT.md](DEVELOPMENT.md) for setup and build instructions and [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a change. Report vulnerabilities through [SECURITY.md](SECURITY.md).

## License

Enve's original source is free and open-source software under the [GNU Affero General Public License v3.0 only](LICENSE.md) (`AGPL-3.0-only`). Commercial use and paid redistribution are permitted, provided the AGPL's source-disclosure, notice, and reciprocal-licensing requirements are met. Third-party components remain under their respective licenses.

Redistributions must retain the license, the source provenance described in [NOTICE.md](NOTICE.md), and all applicable [third-party notices](THIRD_PARTY_NOTICES.md). The [third-party audit](docs/legal/THIRD_PARTY_AUDIT.md) identifies items that still require clearance before distributing a public binary.
