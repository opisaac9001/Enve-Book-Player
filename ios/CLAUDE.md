# Enve Book Player Agent Guide

This file is the repository guide for Claude Code and other coding agents. Treat it as project policy when inspecting, modifying, or validating the app.

Enve Book Player is a native Swift audiobook and ebook player for iOS. The project uses Swift 6, SwiftUI, Readium, and Xcode 26.4 or newer. The main scheme is `enve`, and the minimum iOS version is 17.0.

## Start every task here

Run these checks from the repository root before reading application code or making changes:

```sh
pwd
git remote get-url origin
git branch --show-current
git status --short
```

Then read the documentation relevant to the task:

1. `AGENTS.md` for protected files and the advisory password protocol.
2. `ARCHITECTURE.md` for ownership boundaries and dependency direction.
3. `DEVELOPMENT.md` for setup, signing, build, and runtime verification.
4. `CONTRIBUTING.md` and `SECURITY.md` for public contribution and security rules.
5. The focused documentation under `docs/` for the feature or provider being changed.
6. `docs/distribution/public-source-release.md` before preparing or publishing a public source snapshot.

Do not inspect a file marked `// AGENT-LOCKED` beyond its first line until every step in `AGENTS.md` has been followed. The authorization applies only to the files and task approved by the user in that agent turn.

## How to work in this repository

- Keep the change limited to the requested outcome.
- Preserve all existing work in a dirty worktree. Never discard or overwrite unrelated changes.
- Inspect the current implementation and its callers before designing a replacement.
- Prefer modifying an established type over adding another layer.
- Do not perform drive-by refactors, mass formatting, or unrelated cleanup.
- Do not add placeholder behavior, speculative abstractions, compatibility shims, or unused code.
- Add validation only at system boundaries. Trust internal invariants and framework guarantees.
- Ask before expanding scope, introducing a dependency, changing architecture, or touching release and signing configuration.
- Do not switch branches, commit, push, merge, rewrite history, or open a pull request unless the user explicitly requests it.

Generated code is a draft until it has been reviewed, built, and exercised. Never claim a task works based only on a patch or successful type-check.

## Code standards

- Write idiomatic Swift 6 with Apple naming and native concurrency.
- Prefer direct, readable code over cleverness or generic infrastructure.
- Use comments for constraints, protocol behavior, workarounds, or reasoning that is not clear from the code. Do not narrate obvious control flow or add generated section banners. Add documentation comments only when they clarify a public contract.
- Use `async`/`await` for asynchronous work and keep UI state on the main actor.
- The project uses MainActor-default isolation. Use `@MainActor final class` for app-state services rather than introducing actors that do not compose with the existing model.
- Use `@Observable` for new observable state unless an existing framework boundary requires another mechanism.
- Import `Combine` explicitly when it is used; SwiftUI does not re-export it under the enabled member-import rules.
- Route per-book serialized operations through `PerBookSerialQueue`.
- Match existing error handling and naming in the subsystem being changed.

## Repository map

| Path | Responsibility |
| --- | --- |
| `enve/App/` | App lifecycle, environment setup, root presentation, and plugin registration |
| `enve/Components/` | Shared SwiftUI components and design primitives |
| `enve/Screens/` | User-facing features and feature-local views |
| `enve/Networking/` | Provider contracts, API models, authentication flows, and backend implementations |
| `enve/Persistence/` | SwiftData records, repositories, queries, and migrations |
| `enve/Plugins/` | Shared plugin contracts and the plugin registry |
| `enve/Reader/Engine/` | Readium integration and reader engine ownership |
| `enve/Services/` | Focused domain services and state stores |
| `EnveBookShared/` | Models shared by selected app targets |
| `EnveWatch/` | watchOS companion app |
| `enve-tvOS/` | tvOS app |
| `EnveBookWidgets/` | WidgetKit extension |
| `LocalPackages/` | Maintained wrappers and pinned local dependencies |
| `docs/` | Architecture, UI, backend, distribution, and legal references |

New Swift files under synchronized Xcode groups are discovered automatically. Do not edit `project.pbxproj` merely to add a source file.

## Architecture boundaries

### Providers and sync

The app uses `PluginRegistry.shared` for backend and sync extension points. Registration happens in `EnveApp.bootstrapPlugins()`.

- A library backend implements `LibraryProvider` under `enve/Networking/Providers/` and registers one factory for its `ProviderType`.
- A progress destination implements `SyncSink` under `enve/Services/Sync/` and registers with the plugin registry.
- Provider-specific batch synchronization implements `ProviderSyncStrategy` and owns its own throttling state.
- Read-only playback consumers depend on `PlaybackStateProvider`, not directly on the concrete player singleton.

Provider implementations follow these structural rules:

- Keep each provider implementation in one file. Do not split it merely to reduce line count.
- Use the same internal order in every provider file: state and initialization, capability implementations, transport and mapping logic, then DTOs and helpers.
- Extract code only when it is shared infrastructure used across providers.
- Keep DTOs and helpers nested or file-private where practical so a large provider does not create an equally large module-wide API surface.
- Add or update structural tests or lint rules when needed to prevent provider-specific branching from leaking into unrelated views, services, `AppState`, or sync coordination.
- Measure duplicated logic across providers rather than file size.

Do not add provider switches to unrelated views, `AppState`, or sync coordinators when the registry already owns dispatch.

### State ownership

New persisted or domain-specific state belongs in a focused store under the matching `enve/Services/` area. Give it a typed API and keep its storage keys private.

Do not add new state to these surviving coordination types when a focused owner is appropriate:

- `AppState`
- `SyncCoordinator`
- `StorageService`

When extracting responsibility, migrate callers to the new owner. Do not leave a forwarding API behind solely for compatibility.

### SwiftUI

- Use the Hearth design system through `@Environment(\.hearth)`; do not introduce ad hoc colors or materials.
- Use `.hearthDisplay()` for serif display text and `AmbientColorStore` for per-book ambient color.
- Tab screens account for `@Environment(\.mantelInset)`.
- Full-screen presentation must restore the app environment with `.enveEnvironment()`.
- Start playback or reading through `EnveEngine.shared.playback.play(book)`; transport state and commands come from the injected `PlaybackControlling` selected by `ActivePlayback.composition`.
- Read the library through `AppState.shared.bookStore` and apply book mutations through `AppState.mutateBook`.
- Preserve the connection-flow contracts in `docs/ui/connections-layer.md`.
- Match existing accessibility labels, Dynamic Type behavior, reduced-motion handling, and VoiceOver order.

## Security and transport invariants

Do not weaken or “clean up” these behaviors without explicit user approval and end-to-end provider testing:

- `NSAllowsArbitraryLoads = true` is intentional. Enve connects to user-selected LAN and self-hosted servers that may use HTTP, bare IP addresses, or custom hostnames.
- Local-network self-signed TLS handling is intentional for recognized private, loopback, `.local`, and `.lan` hosts.
- Some AVPlayer, AVURLAsset, and image URLs intentionally carry provider tokens because those framework paths cannot reliably attach custom headers. Continue using headers for ordinary API, metadata, and download requests.
- Credentials and refresh tokens belong in Keychain, never UserDefaults, logs, fixtures, screenshots, or source files.
- Never log authorization headers, tokens, signed media URLs, private server addresses, or diagnostic payloads containing them.
- OAuth client identifiers belong in the ignored `enve/Configuration/DeveloperSettings.plist`. Client secrets do not belong in a distributed iOS app.
- Entitlements, App Groups, CloudKit containers, URL schemes, background modes, and production identifiers are release-sensitive. Do not change them as incidental cleanup.

Read `SECURITY.md` and the relevant provider documentation before changing authentication, networking, trust handling, or credential storage.

## Build and verification

Use an available Apple-silicon iOS Simulator. FluidAudio does not provide the text-processing library slice needed by an x86_64 simulator build.

```sh
xcodebuild -project enve.xcodeproj -scheme enve -showdestinations

xcodebuild -project enve.xcodeproj -scheme enve \
  -destination "platform=iOS Simulator,id=<simulator-udid>" \
  -derivedDataPath .build/DerivedData \
  -quiet build
```

The `AllTests` plan is active. Run it for changes to models, services, persistence, providers, sync, import, playback, and reader behavior:

```sh
xcodebuild -project enve.xcodeproj -scheme enve \
  -testPlan AllTests \
  -destination "platform=iOS Simulator,id=<simulator-udid>" \
  -derivedDataPath .build/DerivedData \
  -quiet test
```

Tests complement rather than replace runtime verification. Verification must be proportional to the change:

- Documentation-only changes: review the rendered structure, links, and diff.
- Model or service changes: build the affected app target and exercise the affected workflow.
- UI changes: build, install, launch, and interact with the changed screen on a simulator.
- Provider changes: test against the affected provider and verify authentication, loading, playback or reading, and progress behavior as applicable.
- Shared-target changes: build every affected target separately.

Install and launch the iOS app after user-facing changes:

```sh
APP_PATH=$(find .build/DerivedData -name "enve.app" \
  -path "*/Debug-iphonesimulator/*" \
  -not -path "*/Index.noindex/*" | head -1)

xcrun simctl install "<simulator-udid>" "$APP_PATH"
xcrun simctl terminate "<simulator-udid>" com.enve.enve 2>/dev/null
xcrun simctl launch "<simulator-udid>" com.enve.enve
```

For focused UI verification, debug builds support:

```sh
xcrun simctl launch <simulator-udid> com.enve.enve \
  -imagineScreen library|journal|settings|addsource|player|reader|readerchrome|detail
```

Build the watch app when shared watch models or watch behavior change:

```sh
xcodebuild -project enve.xcodeproj -scheme EnveWatch \
  -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath .build/DerivedData build
```

Closures passed to WatchConnectivity, MediaPlayer, and similar off-main callbacks must be `@Sendable` where required. Missing this can cause runtime queue assertions even when the project compiles.

## Before reporting completion

1. Review `git status` and the entire diff from the repository root.
2. Confirm every changed file is required for the requested outcome.
3. Remove placeholders, generated explanations, debug output, secrets, and unrelated formatting.
4. Confirm zero build errors and zero new warnings for every affected target.
5. Exercise the changed workflow when behavior or UI changed.
6. Run `./scripts/verify-provenance` for release-oriented work.
7. Report the outcome, affected files, exact verification performed, and any remaining limitation.

If verification cannot be completed, state exactly what was not tested and why. Do not present an unverified change as finished.
