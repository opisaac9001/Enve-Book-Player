# Developing Enve Book Player for Android

This guide covers the Android repository. `CLAUDE.md` is the detailed architecture reference. `AGENTS.md` adds rules for automated coding tools. `docs/README.md` indexes everything else.

## Project shape

```text
app/             application shell, login and reader activities, Android manifest
core/            shared models, Room, DataStore, credential vault, networking
engine-api/      pure facade contracts exposed to the UI
engine/          playback, readers, downloads, sync, e-ink, native code, backends
hearth-ui/       Compose UI, depending only on core and engine-api
audiobookshelf/  Audiobookshelf provider
bookorbit/       BookOrbit provider
komga/           Komga provider
local/           local-file provider
plex/            Plex provider
silo/            Silo provider
storyteller/     Storyteller provider
wear-protocol/   message types shared by the phone and watch apps
wear/            Wear OS companion app
ThirdParty/      vendored upstream source, licences, and reference assets
BuildSupport/    reproducible build assets and provenance
docs/            architecture, guides, testing, and release documentation
scripts/         repository checks and developer tools
```

The `hearth-ui` to `engine-api` boundary is deliberate. UI code must not import a backend implementation. Provider modules own their API, DTOs, repository, adapter, sync strategy, and Hilt bindings. `docs/architecture/module-boundaries.md` explains what the dependency graph enforces and why.

## Initial setup

From the combined Enve Book Player checkout, initialize the shared Foliate submodule, enter the Android directory, open that directory in Android Studio, and let Gradle sync:

```sh
git submodule update --init --recursive
cd android
```

Create `local.properties` with your local Android SDK path if Android Studio does not create it. That file is ignored.

If an agent will work in security-sensitive files, create a local password:

```sh
./scripts/agent-lock set
```

The password is chosen by the user. Only its salted hash is stored in the ignored `.agent-lock` file.

## Build and test

```sh
./gradlew :app:assembleDebug
./gradlew :app:testDebugUnitTest
./gradlew :app:assembleRelease
```

The release task exercises R8, resource shrinking, and release lint. Run connected tests on an authorized device when changing Room migrations, Hilt wiring, or Android integration behavior:

```sh
./gradlew :app:connectedDebugAndroidTest
```

Install the debug APK with:

```sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am force-stop com.enve.app.debug
adb shell am start -n com.enve.app.debug/com.enve.app.MainActivity
```

Add `-s <serial>` to every `adb` command when more than one device is attached. The Wear companion builds separately:

```sh
./gradlew :wear:assembleDebug
```

## Architecture entry points

- `app/src/main/java/com/enve/app/MainActivity.kt` owns the application entry point.
- `engine-api/src/main/java/com/enve/engine/` defines UI-facing facades.
- `engine/src/main/java/com/enve/app/hearth/` implements those facades and binds them in `FacadeModule`.
- `core/src/main/java/com/enve/core/data/provider/ProviderAdapter.kt` defines provider behavior.
- `core/src/main/java/com/enve/core/data/sync/ProviderSyncStrategy.kt` defines batch sync behavior.
- `engine/src/main/java/com/enve/app/data/sync/SyncCoordinator.kt` owns per-book sync.
- `hearth-ui/src/main/java/com/enve/hearth/` contains the production Compose shell.

Hilt multibindings are the provider registry. Do not add a runtime registry singleton. The facade surface is documented in `docs/architecture/engine-api.md`.

## Common changes

### Add a provider

1. Create a Gradle library module that depends on `core` only.
2. Add the provider model case and capabilities in shared core models.
3. Keep the API, DTOs, repository, adapter, auth strategies, sync strategy, and Hilt module inside the provider module.
4. Bind adapters and strategies with Hilt multibindings.
5. Verify login, libraries, covers, playback or reading, downloads, progress push, progress pull, and logout.

### Add persisted state

Use Room for tabular data, `CredentialVault` for secrets, DataStore for UI preferences, or a focused typed store for domain state. Schema changes require an explicit Room migration and database version bump.

### Change authentication or transport security

Read `SECURITY.md` and follow the password process in `AGENTS.md`. Test the actual provider against every supported transport. Confirm secrets are absent from logs, persisted preferences, diagnostics, and URLs where headers are supported.

### Change Compose UI

Use Hearth tokens from `LocalHearth`. Keep reusable design primitives in `hearth-ui/design/` and feature composition in its feature package. Every top-level screen must handle status-bar insets. Test light, dark, OLED, large text, empty, loading, error, and the e-ink states that apply — `docs/architecture/eink.md` covers how the design system degrades on EPD panels and how to force the mode on a normal phone.

## Runtime invariants

`CONTRIBUTING.md` has the general code conventions. These are the ones that bite at runtime rather than at review:

- Validate provider, filesystem, persistence, and user-input boundaries. Trust internal invariants.
- Propagate `CancellationException` from broad exception handlers, or structured concurrency breaks.
- Keep connection-scoped credential access inside scope-aware resolvers, or concurrent connections will borrow each other's servers.
- Every top-level screen applies `Modifier.statusBarsPadding()`, because the app is edge-to-edge and the scaffold zeroes its content insets.

## Verify a change

Choose verification based on what changed:

- Kotlin logic: run the affected unit tests and `:app:assembleDebug`.
- Compose UI: install the debug APK and exercise the changed states on a device or emulator.
- Room schema: add an explicit migration and run migration tests plus connected tests.
- Hilt or module wiring: run debug and minified release builds.
- Authentication or networking: test the real provider flow and inspect logs for leaked secrets.
- Native, dependency, manifest, or ProGuard changes: run `:app:assembleRelease`.
- Protected markers, bundled assets, licensing, notices, or provenance: run `./scripts/verify-provenance`.

`docs/testing/manual-test-plan.md` is the on-device checklist. Run the sections covering what you changed; run all of it before a release.

Before submitting, review the complete diff, remove unrelated generated noise, confirm no private data is present, and update documentation when behavior or architecture changed.
