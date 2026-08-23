# enve — Developer Instructions (Android)

Android audiobook + ebook player. Kotlin, Compose, Android Studio. Stack: Compose Material3, Hilt, Room, Retrofit + OkHttp, Coil, Media3 (ExoPlayer), Readium.

The Hearth UI is built on a **hard front-end/back-end module split**. The backend engine is reached only through the pure-interface `:engine-api` facades. The Hearth UI lives in `:hearth-ui`, which depends on **only** `:core` + `:engine-api` and cannot import a backend concrete.

Read this file before making changes. Also read `AGENTS.md` for the protected-file password protocol and `DEVELOPMENT.md` for setup, module boundaries, and verification details. `docs/README.md` indexes the rest. The architecture section below describes the project boundaries.

**Scope.** This file governs the Android app only. If the checkout nests it beside a sibling platform (an `ios/` tree, shared tooling, a workspace-level `CLAUDE.md`), those have their own instructions — do not apply Android rules to them, and do not edit them from an Android task. Everything here is relative to this Android root.

---

## Code Standards

- Write as a mid-to-senior Android developer would — confident, direct, no hand-holding.
- Production-quality, idiomatic Kotlin. Clarity over cleverness. Structured concurrency (`suspend` + `Flow`/`StateFlow`), Compose best practices (state hoisting, `remember`, `derivedStateOf`, immutable state classes).
- Do not add prose comments, KDoc, or section banners. Use names and structure to make the code readable. Compiler and tooling directives are still allowed. The first-line `// AGENT-LOCKED` marker on the security-sensitive files listed in `AGENTS.md` is the only standing exception.
- No placeholder logic, unused code, or speculative abstractions. No half-finished implementations.
- Don't add error handling, fallbacks, or validation for scenarios that can't happen. Trust internal code and framework guarantees. Validate only at system boundaries.
- Modify existing code over rewriting unless a rewrite is clearly required.
- No backwards-compatibility shims, `// removed` markers, or unused-but-renamed variables — if it's dead, delete it.
- For UI changes, exercise the feature on an Android device or emulator before reporting done. Compilation and tests verify code correctness, not feature correctness.

## Scope Discipline

- Stay strictly focused on the stated task. Don't touch unrelated code, refactor adjacent APIs, or add unrequested features.
- Don't introduce helpers or abstractions unless they're used in more than one place inside the change.
- Don't add feature flags or migration scaffolds when you can just change the code.
- If a change would require touching something outside the stated scope, flag it and ask before proceeding.

## Code Quality Pass

When you encounter redundant wrappers, placeholder scaffolding, generic names, or unnecessary defensive branches in a file you are already editing, clean them up as part of the change. Don't broaden the change to files you would not otherwise touch.

## Agent-Locked Source

Before reading or changing a file whose first line is `// AGENT-LOCKED`, follow `AGENTS.md` exactly. The password belongs to the user and is stored only as a salted hash in the ignored local `.agent-lock` file.

- If no password is configured, ask the user to create one with `./scripts/agent-lock set`.
- If a password is configured, ask before inspecting or changing the protected source and verify it with `./scripts/agent-lock verify`.
- Never put the password in a command argument, file, log, commit, or response.
- Never remove or add a lock marker without explicit user approval.
- Treat this as an advisory stop sign for agents, not encryption or operating-system access control.

## Response Style

- No preamble, summaries, or AI-style narration — provide code and minimal necessary context only.
- No verbose inline comments explaining what the code does.
- Extended explanations only if explicitly asked.

---

## Project-Specific Gotchas

These have bitten this project before — keep them in mind:

- **Edge-to-edge insets.** `MainActivity.onCreate` calls `enableEdgeToEdge()` and `EnveApp`'s `Scaffold` zeroes `contentWindowInsets`. **Every top-level screen must apply `Modifier.statusBarsPadding()`** to the root scrollable, or content renders behind the status bar.
- **Room migrations.** `ReaderDatabase` uses explicit `Migration` objects — `fallbackToDestructiveMigrationOnDowngrade()` only. Schema changes require a new `Migration(N, N+1)` and a version bump. Never use unconditional `fallbackToDestructiveMigration` — annotations / highlights are user data.
- **ConnectionScope (multi-connection).** Per-coroutine connection context propagates via `ConnectionScope.asContextElement(connectionId)` — a `ThreadLocal` element. `AggregatorRepository.withConnectionContext` holds `connectionMutex` only for the volatile `applyConnection` write; the network block runs unprotected. **Any sync read inside a connection-scoped block MUST go through a scope-aware resolver** (`GrimmoryRepository.resolveScopedContext()`, `AudiobookshelfRepository.scopedServerUrlAndToken()`, `KomgaRepository.scopedServerUrl()`, `StorytellerRepository.scopedServerUrl()`). Direct `prefs.getServerUrlSync()` / `getAccessTokenSync()` / `getActiveBookSourceSync()` calls inside these blocks will see WHICHEVER connection ran `applyConnection` last and silently route requests to the wrong server when two top-level callers (HomeViewModel, LibraryViewModel) iterate connections in parallel. The interceptors (`AuthInterceptor`, `DynamicUrlInterceptor`) already prefer ConnectionScope; new repository code should follow the same pattern.
- **Persisting UI state.** ViewModel state is in-memory only. Anything the user sets via the UI that should survive process death (sort order, filters, layout, theme, e-ink prefs) must be wired through `PreferencesManager` (DataStore) — read in `init`, write in every `set*` call.
- **Cover URLs and auth.** `resolveCoverUrl` does **not** append `?token=`. Coil shares the OkHttpClient, and `AuthInterceptor` adds the `Authorization` header. Baking tokens into URLs persists stale JWTs into the on-disk book index cache.
- **Audiobook duration & title.** `BookSummaryDto.durationMs` and `BookDetailDto.durationMs` both exist — Bookloore's audiobook duration lives on `/api/v1/audiobooks/{id}/info` (not the detail endpoint). Title for ambiguous audiobooks comes from `primaryFile.fileName`.
- **Logging.** Release builds use `HttpLoggingInterceptor.Level.BASIC`; debug uses `HEADERS`. Never log `Authorization` headers in release — they reach `adb logcat`.
- **CancellationException must propagate** in any fire-and-forget coroutine on a long-lived scope. `runCatching { ... }` and `catch (e: Exception)` both catch `CancellationException`, which breaks structured concurrency. Always rethrow it: `try { ... } catch (e: CancellationException) { throw e } catch (e: Exception) { ... }`. ViewModelScope launches are usually fine but the pattern is still preferred.

---

## Build & Run

Use Android Studio's bundled JDK or another JDK supported by the project's Android Gradle Plugin. Set `JAVA_HOME` only when your shell does not already resolve the correct JDK:
```bash
export JAVA_HOME="<path-to-supported-jdk>"
```

```bash
./gradlew :app:assembleDebug         # debug build
./gradlew :app:assembleRelease       # release (exercises R8 / ProGuard)
./gradlew :app:testDebugUnitTest     # unit tests
./gradlew :app:connectedDebugAndroidTest   # instrumented (Room migrations, Hilt wiring)
```

A clean release build is the authoritative test for ProGuard rule completeness. Missing keep rules surface as `Missing class` warnings during `minifyReleaseWithR8` and `ClassNotFoundException` at runtime.

Confirm a device or emulator is visible before installing:
```bash
adb devices
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop com.enve.app.debug
adb shell am start -n com.enve.app.debug/com.enve.app.MainActivity
adb logcat --pid=$(adb shell pidof com.enve.app.debug)
```
If more than one device is attached, add `-s <serial>` to scope `install`, `shell`, and `logcat` commands.

Watch logcat for `FATAL`, silent `IllegalStateException`s, Compose recomposition errors. Cold-start crashes from Hilt / Room are often suppressed by the OS dialog — only logcat shows them.

Confirm **zero errors and zero new warnings** before considering a task complete, and exercise UI changes on a supported device or emulator before reporting done.

---

## Architecture

The app is built around three interlocking ideas: **Gradle multi-module isolation** per provider, a **Hilt-driven plug-in registry** that wires those modules together, and a **hard front-end/back-end wall** enforced by module dependencies. Adding a new backend should mean creating a new `:<provider>` module with its own Hilt bindings, without adding provider branches to `AggregatorRepository`, `SyncCoordinator`, or shared registry modules.

This mirrors the iOS port one-to-one — same architectural vocabulary, same plug-in patterns, adapted for Hilt + Kotlin.

### Module layout

```
:core              Shared types, persistence (Room/DataStore/vault), network infra
                   (AuthInterceptor, DynamicUrlInterceptor, ConnectionScope), contracts
                   (ProviderAdapter, ProviderSyncStrategy), shared DTOs.
:engine-api        Pure interfaces — the facade contract the UI calls (LibraryFacade,
                   PlaybackFacade, PlayerSessionFacade, ReaderFacade, DownloadsFacade,
                   SyncFacade, SourcesFacade, PreferencesFacade, EinkFacade) + UI-state
                   DTOs. Depends on :core only. NO implementations, NO Hilt modules.
:engine            Backend implementations under com.enve.app.*: data/ (repository, sync, paging,
                   offline, librarian, metadata, …), playback/ (Media3 + PlaybackService),
                   readium/, eink/, document/ (+ native MOBI cpp/), diagnostics/, di/,
                   Grimmory. Implements :engine-api. Depends on :core + :engine-api + every
                   provider module. Hosts the @AndroidEntryPoint services (class bodies);
                   their <service> registrations stay in the :app manifest.
:hearth-ui         Hearth UI: design system (design/) + Compose screens + @HiltViewModel
                   ViewModels. Depends on :core + :engine-api ONLY — it CANNOT import a
                   backend concrete. This dependency rule IS the portability guarantee.
:audiobookshelf    ABS provider (api, dto, repo, adapter, auth, Hilt module)
:storyteller       Storyteller provider
:komga             Komga provider (incl. OAuth flow + password login)
:local             Local file provider
:plex              Plex provider (PIN OAuth + multi-server + Home users)
:bookorbit :silo   BookOrbit (OIDC) and Silo providers
:wear-protocol     Message + payload types shared by the phone and watch apps.
                   Depends on nothing but kotlinx.serialization.
:wear              Wear OS companion app (own applicationId suffixing, minSdk 30).
                   Depends on :wear-protocol ONLY — never on :core or :engine.
:app               THIN shell: MainActivity, EnveApplication (@HiltAndroidApp), Hilt
                   aggregation, AndroidManifest (service registrations), splash,
                   WearCompanionService. Depends on everything except :wear.
                   Its ui/ files are login and Settings bridge tools, reader Activities,
                   and Android lifecycle integration code.
```

Each provider module owns its API, DTOs, repository, ProviderAdapter, and a single `<provider>/di/<Provider>Module.kt` that contributes the adapter + sync strategies to the shared multibinding sets. Provider modules depend only on `:core` — never on each other, `:engine`, or `:app`.

**The facade wall.** UI in `:hearth-ui` may call the backend only through `:engine-api` facades — never `AggregatorRepository`, a provider repository, `AudioPlaybackManager`, `OfflineDownloadManager`, `ReadiumManager`, or `ConnectionScope` directly. Facade impls live in `:engine` under `com.enve.app.hearth` (`*FacadeImpl @Inject`), bound via `@Binds` in `com.enve.app.hearth.FacadeModule` (co-located with the impls; Hilt aggregates it at the `:app` build). Start playback/reading only via the playback facade. The full contract is in `docs/architecture/engine-api.md`; the module layout and boot contract are in `docs/architecture/module-boundaries.md`.

The Hearth shell, design system, home, library, player, detail, and settings features live in `:hearth-ui`. Readium, comic, and PDF readers remain Activity-based in `:app` because their engines require Android lifecycle integration. Source-management screens in `:hearth-ui` may bridge to the login and administration activities in `:app`, but new general-purpose UI must stay behind `:engine-api` facades. Check the current source and the `docs/architecture/` contracts before assuming a facade or screen exists.

### Hearth design system (`:hearth-ui/design/`)

Ported hex-for-hex from the iOS `Hearth.swift`. Consume tokens through `LocalHearth` / the `Hearth` object (`Hearth.palette`, `Hearth.eink`, `Hearth.Radius`, `Hearth.Spacing`); wrap screens in `HearthTheme(mode, accent, oledEnabled, eink)`. `HearthPalette` has `ink` / `oled` / `paper` / `eink` variants; ember accent is `#F5921A`. Serif display via `hearthDisplay(...)` / `HearthText`; `Overline` for section headers. **E-ink is a first-class mode, not a bolt-on:** every primitive degrades at the point of use through `Hearth.eink` (`suppressGradients`/`suppressAnimations`/`borderInsteadOfShadow`/`sharpCorners`/`denseListLibrary`), and the palette auto-flips to pure black/white when the panel is monochrome. Never hard-code colours or reach for `MaterialTheme` colours in a Hearth screen.

### Plug-in contracts

Bootstrapped via Hilt multibindings; the runtime "registry" is the injected `Set<...>` of conformers, aggregated across every module that contributes one.

| Contract | Where (in `:core`) | Contributing modules | Purpose |
|---|---|---|---|
| `ProviderAdapter` | `data/provider/ProviderAdapter.kt` | Each `:<provider>/di/<Provider>Module.kt` | Per-backend data + sync API. Conformers: Grimmory, Audiobookshelf, Komga, Storyteller, Local, Plex. |
| `ProviderSyncStrategy` | `data/sync/ProviderSyncStrategy.kt` | Same | Per-provider batch sync (the recently-played / launch sweep). |
| `PasswordLogin` | `data/auth/PasswordLogin.kt` | Provider modules where extracted; `:app` only for app-owned / hidden providers | Username+password login conformers, keyed by `BookSource`. |
| `AuthHeaderStrategy` | `data/remote/AuthHeaderStrategy.kt` | Provider modules where extracted; `:app` only for app-owned / hidden providers | Per-provider request signing (`Bearer`, Basic, Plex headers/query, Storyteller cookie, etc.). |
| `TokenRefreshStrategy` | `data/remote/TokenRefreshStrategy.kt` | Providers that support token renewal / password fallback | Per-provider token refresh and re-login used by proactive refresh and OkHttp 401 retry. |
| `SyncCoordinator` | `engine`/`com.enve.app.data.sync.SyncCoordinator` | (consumes the registry; lives in `:engine` with AggregatorRepository) | Per-book pull-on-open + debounced push, conflict resolution, event stream. |

When you need a new plug-in contract, define the interface in `:core/data/<area>/`, add a Hilt `@Module` in each contributing provider module with `@Binds @IntoSet` for the conformer, and inject `Set<TheContract>` where you need it. Don't write a runtime registry singleton — Hilt is the registry.

### Focused stores / services (single-responsibility)

Backend implementations live in `:engine` under `com.enve.app.*`. The playback layer is split into single-responsibility services in `com.enve.app.playback`:
- `PlayerProgressService` — per-book position persistence
- `PlayerBookmarkService` — bookmarks
- `PlayerChapterService` — chapter resolution
- `PlayerSleepTimerService` — sleep timer
- `PlayerSessionService` — per-session lifecycle
- `PlaybackChapterStore` — chapter cache

Long-lived state belongs in focused storage:
- `CredentialVault` — EncryptedSharedPreferences for tokens (per-connection keys + scope-aware reads)
- `PreferencesManager` — DataStore for everything UI-persisted (sort order, filters, theme, e-ink prefs)
- `PendingProgressPushDao` — queue for retried progress pushes
- `BookCacheDao` — local SQLite cache (the source of truth for in-progress / recently-added)
- `AnnotationDao` — annotations / highlights
- `ConnectionRegistry` — multi-connection registry

**Don't add new fields to `AggregatorRepository`, `SyncCoordinator`, or any provider repository to hold state.** If something feels like it belongs in a god class, it belongs in a focused service or store.

### Multi-connection isolation

`ConnectionScope` is unique to Android (iOS doesn't have it). It propagates a connection ID via a `ThreadLocal` `CoroutineContext` element through OkHttp's dispatcher. Two top-level callers iterating connections in parallel each see their own scope. **Any new repository code that does scoped reads must go through the connection-aware resolver pattern** — see the gotcha above.

### Build notes

- Multi-module Gradle: `:core` + `:engine-api` + `:engine` + `:hearth-ui` + one per provider (`:audiobookshelf`, `:storyteller`, `:komga`, `:local`, `:plex`, `:bookorbit`, `:silo`) + `:wear-protocol` + `:wear` + `:app`.
- Hilt + KSP are configured in every code module. KSP runs per-module; Hilt aggregation happens at `:app` build time (`@HiltAndroidApp EnveApplication`). `@AndroidEntryPoint` services live in `:engine`; their `<service>` entries + `foregroundServiceType` stay in the `:app` manifest.
- Provider modules MUST NOT depend on each other, `:engine`, or `:app`. `:hearth-ui` MUST NOT depend on anything except `:core` + `:engine-api` (that is the wall — keep it that way).
- `:core` exposes most networking + Room deps as `api(...)` so dependent modules don't redeclare them; `:engine` declares heavier backend deps (Media3, Readium, WorkManager, native MOBI CMake, etc.). `:app` owns Compose/navigation dependencies for login, settings bridges, and reader integration; `:hearth-ui` owns dependencies for the Hearth shell.

### Known architecture exceptions

- **Grimmory lives in `:engine`.** It is implemented as `com.enve.app.data.repository` classes rather than a standalone provider module. Keep changes behind the existing facades and do not increase its coupling to `:app`.
- **Some auth bindings are engine-owned.** OPDS, WebDAV, SMB, Grimmory, Jellyfin, Emby, and Kavita auth implementations are registered from the backend layer. Keep provider-specific behavior out of shared interceptors and authenticators.

---

## How to add things

These are recipes. Each one is intentionally small: that's the architectural payoff.

### Add a library backend

1. Create a new Gradle module `:<name>` at the repo root. Copy `:plex/build.gradle.kts` as the template — Android library plugin, Kotlin + serialization + KSP + Hilt, `implementation(project(":core"))` only.
2. Add `include(":<name>")` to `settings.gradle.kts` and `implementation(project(":<name>"))` to `app/build.gradle.kts`.
3. Add the `BookSource` enum case in `:core/data/model/Enums.kt`.
4. Inside the new module:
   - `api/<Name>Api.kt` — Retrofit interface. Use `http://localhost/` placeholder path; `DynamicUrlInterceptor` rewrites it to the connection's serverUrl at request time.
   - `dto/<Name>Dto.kt` — wire DTOs. Anything cross-provider goes in `:core/data/remote/dto/`; provider-specific shapes stay here.
   - `<Name>Repository.kt` — domain logic. Use the `scoped()` pattern from `PlexRepository.scoped()` to read the right `(serverUrl, token)` for the current `ConnectionScope`.
   - `<Name>ProviderAdapter.kt` — thin delegate implementing `ProviderAdapter`. Override the methods the backend actually supports; others fall back to the interface defaults.
   - `di/<Name>Module.kt` — Hilt wiring. One `@Binds @IntoSet` for the adapter, one `@Provides` for the Retrofit API.

```kotlin
@Module
@InstallIn(SingletonComponent::class)
abstract class <Name>Module {
    @Binds @IntoSet
    abstract fun bind<Name>Adapter(impl: <Name>ProviderAdapter): ProviderAdapter

    companion object {
        @Provides @Singleton
        fun provide<Name>Api(retrofit: Retrofit): <Name>Api =
            retrofit.create(<Name>Api::class.java)
    }
}
```

If the backend has its own progress endpoint, override `syncAudiobookProgress` / `syncEbookProgress` / `fetchAudiobookProgress` / `fetchEbookProgress` on the adapter. If it has a special protocol (KOReader-style), write a sink class — `BookloreKoreaderSink` is the existing example.

If the backend needs provider-specific request signing, implement `AuthHeaderStrategy` in the provider module and bind it with `@Binds @IntoMap @AuthHeaderStrategyKey(BookSource.<NAME>)`. If it supports token renewal or password fallback, implement `TokenRefreshStrategy` and bind it with `@TokenRefreshStrategyKey`. Do not add provider-specific branches to `AuthInterceptor` or `TokenRefreshAuthenticator`.

### Add a per-provider batch sync (recently-played path)

1. Implement `ProviderSyncStrategy` inside the provider module (`<name>/sync/<Name>SyncStrategy.kt`). Mark `@Singleton`, use `@Inject constructor`.
2. Set `id`, `displayName`, and implement `sync(force, launchOptimized) -> ProviderSyncResult`.
3. Own your own throttle clock (`@Volatile private var lastSyncAtMs: Long? = null`, 60s minimum unless `force`).
4. Add one `@Binds @IntoSet` line to the same `<Name>Module.kt` that registers your `ProviderAdapter`:

```kotlin
@Binds @IntoSet
abstract fun bind<Name>SyncStrategy(impl: <Name>SyncStrategy): ProviderSyncStrategy
```

`RecentlyPlayedSyncService` enumerates and dispatches automatically. Don't add anything to `SyncCoordinator` for this — strategies and per-book sync are intentionally separate.

### Add a piece of persisted state

Don't add fields to `AggregatorRepository`, `SyncCoordinator`, or `PreferencesManager`'s mega-class shape. Write a focused store:

1. New file under `data/local/` (or a sub-folder if it has companions): `<Thing>Store.kt`.
2. `@Singleton class <Thing>Store @Inject constructor(...) { ... }`.
3. Persistence keys live as `private const val` at the top of the file.
4. Expose a typed API. Don't expose generic `save<T>` / `load<T>` helpers across the public surface.
5. Hilt injects it where needed. No DI plumbing in callers.

If the data is multi-row tabular, use a Room `@Dao` instead — see `BookCacheDao` for the canonical pattern (suspend writes, suspend reads, Flow observers).

### Add observable sync status to a UI surface

Add a `MutableStateFlow` (or `MutableSharedFlow` for events) to the relevant service as `private` with a public `Flow` view:

```kotlin
private val _state = MutableStateFlow(...)
val state: StateFlow<...> = _state.asStateFlow()
```

ViewModels collect the flow and re-expose to UI as `StateFlow<...>` via `stateIn(viewModelScope, ...)`. `SyncCoordinator.events` is the canonical example.

### Touch credentials (any backend)

- `CredentialVault` (EncryptedSharedPreferences) only. Never DataStore for tokens.
- No token logging — not even truncated. Release builds already pass `HttpLoggingInterceptor.Level.BASIC` so headers don't leak; never raise that to `HEADERS` for release.
- Prefer headers (`Authorization: Bearer …`, `X-Plex-Token`, etc.) over URL query params.
- Verify against the backend's API docs before changing the auth flow.
- For per-connection credentials, use `CredentialVault.<key>KeyForConnection(connectionId)` so two accounts on the same host don't collide.

---

## Working with Git

- Run Git commands from the repository root and inspect the current status before editing.
- Preserve unrelated changes in a dirty worktree.
- Keep commits focused and use short, descriptive messages.
- Follow the branch and pull-request workflow chosen by the repository or fork owner.
- Do not push, merge, rewrite history, or open a pull request unless the person directing the work asks for it.
- Never commit `local.properties`, `.agent-lock`, signing material, credentials, private server data, downloaded media, diagnostics, or build products.

---

## When in doubt

- **Don't add to god classes.** If something feels like it belongs in `AggregatorRepository`, `SyncCoordinator`, or a provider repository, it almost certainly belongs in a focused service or store.
- **Don't write a runtime registry singleton.** Hilt multibinding (`@Binds @IntoSet`) is the registry. Inject `Set<TheContract>` where you need it.
- **Don't introduce a new singleton without checking the registry.** If the new singleton is a provider, it's a `ProviderAdapter` conformer, not a free-standing class. If it's a sync strategy, it's a `ProviderSyncStrategy` conformer.
- **Don't create speculative plug-in contracts.** Define the interface when you have the second conformer, not the first.
- **Match iOS architecture vocabulary.** When a feature exists on iOS, name the Android version the same — `RecentlyPlayedSyncService`, `ProviderSyncStrategy`, `SyncCoordinator`. The two ports stay easier to maintain in lockstep this way.
- Build clean against debug + release. Verify the app launches healthy with `adb logcat` after a cold start before considering done.
