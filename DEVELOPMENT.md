# Developing Enve Book Player

This guide covers building and modifying the iOS repository. Read `ARCHITECTURE.md` for target boundaries, dependency direction, feature ownership, and file placement.

## Project shape

Enve is a native Swift 6 audiobook and ebook client for iOS 17 and newer. The Xcode project also contains a watchOS companion, widgets, and a tvOS target. The iOS app is the primary supported development target.

```text
enve/
  App/                 lifecycle, root presentation, app bootstrap
  Components/          shared SwiftUI controls and Hearth design tokens
  Configuration/       local developer configuration and provenance
  Networking/          backend contracts, models, and providers
  Persistence/         SwiftData records, queries, and migrations
  Plugins/             provider, sync, and playback plugin contracts
  Reader/Engine/       Readium and Foliate reader integration
  Screens/             feature screens and their local view models
  Services/            focused domain services and state stores
  Utilities/           small cross-cutting helpers
EnveBookShared/         models shared with widgets and Watch
EnveBookWidgets/        WidgetKit extension
EnveWatch/              watchOS companion
enve-tvOS/              tvOS client
LocalPackages/          packages maintained or wrapped in this repository
ThirdParty/             vendored upstream source
BuildSupport/           reproducible build-time assets and scripts
docs/                   feature contracts, backend notes, and design records
scripts/                repository checks and local developer tools
```

## Requirements

- macOS on Apple silicon
- Xcode 26.4 or newer
- Git with submodule support
- An iOS 17 or newer simulator
- An Apple Developer account only when installing on a physical device

FluidAudio does not ship the required x86_64 simulator slice. Use an Apple-silicon simulator destination rather than a generic multi-architecture simulator.

## Initial setup

Clone with submodules and allow Xcode to resolve Swift packages:

```sh
git clone --recurse-submodules <repository-url>
cd <repository-directory>
xcodebuild -resolvePackageDependencies -project enve.xcodeproj -scheme enve
```

For optional Google Drive or Dropbox development, create the ignored local settings file:

```sh
cp enve/Configuration/DeveloperSettings.example.plist \
  enve/Configuration/DeveloperSettings.plist
```

Use developer-owned OAuth applications and redirect schemes. Never commit the populated file. Do not put OAuth client secrets in an iOS application.

## Build the iOS app

List destinations, then build against the desired simulator UDID:

```sh
xcodebuild -project enve.xcodeproj -scheme enve -showdestinations

xcodebuild -project enve.xcodeproj \
  -scheme enve \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath .build/DerivedData \
  build
```

Install and launch the built app:

```sh
APP_PATH=$(find .build/DerivedData -name 'enve.app' \
  -path '*/Debug-iphonesimulator/*' \
  -not -path '*/Index.noindex/*' | head -1)
xcrun simctl install <simulator-udid> "$APP_PATH"
xcrun simctl launch <simulator-udid> com.enve.enve
```

## Run the test plan

The `AllTests` plan contains the supported unit and regression suite:

```sh
xcodebuild -project enve.xcodeproj \
  -scheme enve \
  -testPlan AllTests \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath .build/DerivedData \
  test
```

Run the plan for changes to models, services, persistence, providers, synchronization, import, playback, and reader behavior. Tests do not replace installing and exercising user-facing changes.

Physical device builds require your own development team, bundle identifiers, App Group, CloudKit container, push configuration, and related entitlements. Do not ship a fork using Enve's production identifiers.

## Other targets

Build the Watch app with:

```sh
xcodebuild -project enve.xcodeproj \
  -scheme EnveWatch \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath .build/DerivedData \
  build
```

The phone is the broker for Watch discovery and control. Shared payloads live in `EnveBookShared/WatchPayloads.swift`. Closures passed to WatchConnectivity must be `@Sendable` because callbacks can arrive off the main actor.

The tvOS target is present but does not define the acceptance bar for ordinary iOS changes. If a task explicitly affects tvOS, verify that target separately and document any upstream framework limitation.

## Architecture entry points

- `ARCHITECTURE.md` maps the targets, application layers, features, and dependency direction.
- `enve/App/EnveApp.swift` registers provider factories, sync sinks, and sync strategies.
- `enve/Plugins/PluginRegistry.swift` owns plugin registration and lookup.
- `enve/Networking/LibraryProvider.swift` defines backend behavior.
- `enve/Services/Sync/` contains progress synchronization.
- `enve/Persistence/` owns SwiftData records and migrations.
- `enve/Reader/Engine/` contains the reader boundary.
- `enve/Screens/` owns screen composition and feature-local state.

Do not grow `AppState`, `SyncCoordinator`, or `StorageService` with unrelated state. Add a focused store or service in the matching domain. New backend behavior should conform to existing plugin contracts and register once during app bootstrap.

## Common changes

### Add a backend

1. Add a `LibraryProvider` catalog implementation under `enve/Networking/Providers/` and conform only to the optional capability protocols the backend implements.
2. Add the provider case and capability mapping to the shared models.
3. Register its factory in `EnveApp.bootstrapPlugins()`.
4. Add a provider-specific sync strategy only if the normal provider sync sink cannot represent its behavior.
5. Verify login, library loading, covers, playback or reading, downloads, progress push, progress pull, and logout.

### Add persisted state

1. Decide whether it is a SwiftData record, Keychain value, or small preference.
2. Put domain records and migrations in `enve/Persistence/`.
3. Put a small preference behind a typed focused store under `enve/Services/`.
4. Add migration logic when changing an existing stored shape.

### Change authentication or transport security

1. Read `SECURITY.md` and preserve its configuration invariants.
2. Test the actual provider against HTTP, trusted HTTPS, and supported local self-signed HTTPS as applicable.
3. Confirm secrets are absent from logs, URLs where headers are supported, diagnostics, and persisted preferences.

### Change SwiftUI

1. Use Hearth values from the environment rather than new hard-coded colors or materials.
2. Keep reusable controls in `enve/Components/` and feature-specific composition in its screen directory.
3. Route playback and reading through `AppState.shared.playBook(book)`.
4. Preserve `mantelInset` handling and re-inject the app environment into full-screen presentation boundaries.
5. Exercise the workflow in the simulator and check light, dark, Dynamic Type, empty, loading, and error states that apply.

## Code standards

- Prefer clear platform-native names. Add comments when they preserve reasoning, compatibility constraints, protocol details, or non-obvious workarounds.
- Do not add comments that narrate the code, generated section banners, placeholder code, or speculative abstractions.
- Keep types and files aligned by responsibility. A screen should not become a networking service and a provider should not own UI state.
- Use Swift concurrency and the project's MainActor-default isolation deliberately.
- Import modules explicitly. SwiftUI does not stand in for Combine.
- Validate data at provider, filesystem, persistence, and user-input boundaries. Do not add defensive branches for impossible internal states.
- Preserve unrelated work and keep commits focused.
- Keep files in the narrowest owning feature or layer described in `ARCHITECTURE.md`; do not create new catch-all directories.

## Verification checklist

Before submitting a change:

1. Review the complete diff from the repository root.
2. Confirm no credentials, private URLs, downloaded media, diagnostic exports, or local developer settings are tracked.
3. Build every affected target with zero errors and zero new warnings.
4. Run the `AllTests` plan for testable application behavior.
5. Install and launch the iOS app for any runtime or user-facing change.
6. Exercise the changed workflow with representative data.
7. Run `./scripts/verify-provenance`.
8. Update documentation when a public contract, setup step, or security assumption changed.

## Source control

Use a focused branch only when the maintainer asks for one. Do not rewrite published history. Pull requests should explain the user-visible outcome, notable design decisions, and verification performed.

Release archives must retain `LICENSE.md`, `NOTICE.md`, `THIRD_PARTY_NOTICES.md`, third-party license files, and the compiled provenance keys. Resolve every blocking item in `docs/legal/THIRD_PARTY_AUDIT.md` before public distribution. The repository license does not replace any third-party license.
