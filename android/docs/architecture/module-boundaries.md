# Module Boundaries and Boot Contract

Enve's Android source is split so that the Compose UI cannot reach a backend implementation. The Gradle dependency graph is what enforces it; nothing relies on review discipline.

## Module layout

```text
:core            models, plug-in contracts, persistence, network infrastructure
:engine-api      pure interfaces (facades) + UI-state DTOs. Depends on :core only.
:engine          backend implementations — repositories, sync, playback, Readium,
                 e-ink, offline, document, Grimmory. Implements :engine-api.
                 Depends on :core + :engine-api + every provider module.
:hearth-ui       Compose UI, design system, and ViewModels.
                 Depends on :core + :engine-api ONLY.
:app             MainActivity, EnveApplication (@HiltAndroidApp), Hilt aggregation,
                 AndroidManifest, splash, login and reader Activities.
providers        :audiobookshelf :storyteller :komga :local :plex :bookorbit :silo.
                 Depend on :core only.
:wear-protocol   message and payload types shared by the phone and watch apps.
:wear            Wear OS companion app. Depends on :wear-protocol only.
```

Two rules carry the design:

- `:hearth-ui` may depend on `:core` and `:engine-api` and nothing else. A UI ViewModel physically cannot `@Inject` an engine class, because that class is not on its compile classpath.
- Provider modules may depend on `:core` and nothing else. They never depend on each other, on `:engine`, or on `:app`.

Everything a screen needs from the backend therefore has to appear on a facade in `:engine-api`. See [engine-api.md](engine-api.md) for that contract.

## Boot contract

`EnveApplication` (`@HiltAndroidApp`, WorkManager `Configuration.Provider`) and `MainActivity` own application startup. The Hearth shell supplies the *content* of `MainActivity` — it does not own the Activity lifecycle. Any change to the shell must preserve:

- `enableEdgeToEdge()` in `MainActivity.onCreate`. Because the `Scaffold` zeroes its content window insets, every screen root applies `Modifier.statusBarsPadding()` and the MantelBar applies `navigationBarsPadding()`.
- The `installSplashScreen()` gate.
- Hilt initialization and the `EnveApplication` WorkManager configuration.
- `EpdRefreshManager` injection and the resume-refresh hooks carried into `HearthRoot`.

## Manifest ownership

`@AndroidEntryPoint` service classes live in `:engine`, but their `<service>` entries, `foregroundServiceType` values, and permissions stay in the `:app` manifest, which references the moved classes:

- `.playback.PlaybackService` — `foregroundServiceType=mediaPlayback`
- `.data.librarian.LiteRtLibrarianProcessService` — runs in the `:librarian_model` process
- WorkManager `SystemForegroundService` — `dataSync`

Readium, comic, and PDF readers remain Activity-based in `:app` because their engines need Android lifecycle integration. Source-management screens in `:hearth-ui` may bridge to the login and administration Activities in `:app`; new general-purpose UI stays behind `:engine-api` facades.
