# Enve Architecture

Enve is a native Swift application with separate iOS, watchOS, tvOS, widget, and shared-code targets. The main iOS target is organized as a layered application rather than a collection of independent packages. These boundaries are conventions inside one target, so contributors are responsible for preserving the dependency direction described here.

## Targets

| Target | Location | Responsibility |
|---|---|---|
| `enve` | `enve/` | Main iOS application, domain logic, integrations, persistence, and UI |
| `EnveWatch` | `EnveWatch/` | Standalone watchOS shell and playback client |
| `enve-tvOS` | `enve-tvOS/` | tvOS application shell and television-specific UI |
| `EnveBookWidgets` | `EnveBookWidgets/` | WidgetKit extension |
| Shared target sources | `EnveBookShared/` | Payloads and state shared by selected targets |
| Local packages | `LocalPackages/` | Maintained wrappers and pinned source dependencies |

The iPhone app brokers Watch discovery and control, but the Watch target does not import the iOS playback engine. Shared wire models belong in `EnveBookShared/`; platform behavior stays in its platform target.

## Main application layers

| Layer | Location | Owns |
|---|---|---|
| Application | `enve/App/` | Lifecycle, environment bootstrap, root presentation, plugin registration |
| Features | `enve/Screens/` | User-facing feature composition and feature-local models |
| Shared UI | `enve/Components/` | Reusable Hearth controls, styling, and presentation primitives |
| Domain models | `enve/Models/` | App, library, playback, reader, provider, and statistics value types |
| Domain services | `enve/Services/` | Focused state owners, orchestration, imports, playback, sync, and integrations |
| Provider boundary | `enve/Networking/` | Provider contracts, transport models, and backend implementations |
| Persistence | `enve/Persistence/` | SwiftData records, repositories, queries, and migrations |
| Extension contracts | `enve/Plugins/` | Provider, sync, and playback plugin contracts and registry |
| Reader engine | `enve/Reader/Engine/` | Readium, Foliate, comic, navigation, and locator integration |
| Platform integration | `enve/CarPlay/`, `enve/Watch/`, `enve/Widgets/` | iOS system surfaces and companion bridges |
| Cross-cutting support | `enve/Utilities/` | Small leaf utilities that do not own domain state |

## Dependency direction

```text
App ───────────────► Features ─────────────► Services / Reader
 │                       │                         │
 │                       └──────────────► Models ◄┤
 │                                                │
 └────────► Plugin registry ──────► Networking ───┤
                                  └► Persistence ─┘

Platform targets ──────► EnveBookShared
```

- `App` composes the application. It may register concrete providers and services, but it should not implement their behavior.
- `Screens` owns presentation. Feature-local view models stay beside their screens; reusable domain state belongs in a service or store.
- `Services` coordinates work across models, providers, persistence, playback, and the reader. A service should remain scoped to one domain.
- `Networking` adapts remote APIs into Enve models. Provider-specific wire models belong beside the provider or under `Models/Providers/` when shared outside transport code.
- `Persistence` stores and queries domain state. UI code should use repository and engine APIs rather than create ad hoc SwiftData queries.
- `Plugins` defines extension points. Concrete implementations live with the domain they integrate.
- `Utilities` is a leaf layer. It must not become a second service directory.

## Feature ownership

Feature UI is grouped by user workflow under `enve/Screens/`:

| Feature | Primary location | Related domain code |
|---|---|---|
| Home | `Screens/Hearth/` | `Services/Engine/`, `Services/Collections/` |
| Library | `Screens/Library/` | `Persistence/`, `Services/Local/`, `Services/Metadata/` |
| Book details | `Screens/BookDetails/` | `Services/Download/`, `Services/Sync/`, `Services/Metadata/` |
| Player | `Screens/Player/` | `Services/Audio/`, `Services/Player/` |
| Reader | `Screens/Reader/` | `Reader/Engine/`, `Services/Reader/`, `Services/ReadAlong/` |
| Sources | `Screens/Sources/` | `Networking/Providers/`, provider-specific services |
| Collections and matching | `Screens/Collections/`, `Screens/Dedup/`, `Screens/Matches/` | `Services/Collections/`, `Services/Dedup/`, `Services/Metadata/` |
| Journal | `Screens/Journal/` | `Services/ListeningStats/`, `Services/Sync/` |
| Podcasts | `Screens/Podcasts/` | Podcast provider and persistence types |
| Settings | `Screens/Settings/` | Focused stores and services; no settings-owned business logic |

## Provider integrations

A backend integration normally has four pieces:

1. Wire and domain models under `Models/Providers/<Provider>/` or beside the provider when private to transport.
2. A `LibraryProvider` implementation under `Networking/Providers/`.
3. Focused provider services under `Services/<Provider>/` only when the behavior is not part of the provider contract.
4. Optional admin and connection UI under `Screens/Admin/<Provider>/` and `Screens/Sources/`.

Provider factories, sync sinks, and sync strategies are registered once during app bootstrap. Do not add provider switches to feature screens or central state objects.

## State and persistence

- Cross-feature observable state belongs in a focused store under `Services/`.
- Credentials belong behind the existing Keychain boundary.
- Library records and queries belong in `Persistence/`.
- Small feature-only state belongs in the feature model next to its screen.
- Do not add unrelated state to `AppState`, `SyncCoordinator`, or `StorageService`.

Several older files remain large because they predate these boundaries. Split them by stable responsibility when making a related change; do not create path-only rewrites or speculative layers solely to reduce line counts.

## File placement checklist

Before adding a file, choose the narrowest owner:

1. Is it visible UI or feature-local presentation state? Put it in the matching `Screens/<Feature>/` directory.
2. Is it a reusable UI primitive? Put it in `Components/`.
3. Does it own domain behavior or persisted preferences? Put it in a focused `Services/<Domain>/` directory.
4. Does it represent shared domain data? Put it in `Models/<Domain>/`.
5. Does it talk to a remote backend? Put it in `Networking/`.
6. Does it store or query app data? Put it in `Persistence/`.
7. Is it an extension contract? Put it in `Plugins/`.
8. Is it platform-specific? Put it in the corresponding platform integration or target.

If none applies, reconsider whether the new abstraction is needed.

## Further documentation

- [Documentation index](docs/README.md)
- [Provider capability matrix](docs/architecture/provider-capability-matrix.md)
- [Identity contract](docs/architecture/identity-contract.md)
- [Server mirror contract](docs/architecture/server-mirror-contract.md)
- [UI design language](docs/ui/DESIGN.md)
- [Reader stack](docs/ui/reader-stack.md)
- [Development guide](DEVELOPMENT.md)
