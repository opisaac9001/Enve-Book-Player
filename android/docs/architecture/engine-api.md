# Engine API Contract

`:engine-api` is the only surface the Compose UI is allowed to call. It holds pure interfaces and UI-state DTOs, depends on `:core` alone, and contains no implementations and no Hilt modules. Backend implementations live in `:engine` and are bound to these interfaces in `com.enve.app.hearth.FacadeModule`, which Hilt aggregates at the `:app` build.

The dependency graph enforces this: `:hearth-ui` cannot see an engine class, so a UI ViewModel cannot inject one. See [module-boundaries.md](module-boundaries.md).

## Rules

- **Start playback through `PlaybackFacade.open(book)`.** Never construct a media session or touch `AudioPlaybackManager` / `PlaybackService` from the UI.
- **Library reads and mutations go through `LibraryFacade`**, never a provider repository or `AggregatorRepository`.
- **The UI never touches `ConnectionScope`.** Facade implementations run scoped reads through the connection-aware resolvers and hand the UI aggregated results.
- **Value types come from `:core`** (`Book`, `Chapter`, `Library`, `BookSource`, `AppMediaType`, `ProviderConnection`). UI-state DTOs with no `:core` equivalent live beside their facade in `:engine-api`. No parallel model hierarchies.
- **State is exposed as `Flow` / `StateFlow`.** ViewModels combine facade flows and re-expose a single `StateFlow<UiState>` via `combine(...).stateIn(viewModelScope, WhileSubscribed(5000), initial)`.

## Facades

| Facade | Backed by | Surface |
|---|---|---|
| `LibraryFacade` | `AggregatorRepository`, `BookCacheDao`, paging sources | Home and library flows (`continueBooks`, `recentlyAdded`, `downloaded`, `allBooks`, `libraries`), series/author/shelf browsing and paging, edition links, collection membership, progress and finished mutations. |
| `PlaybackFacade` | `AudioPlaybackManager` via `MediaController` | `transport` / `nowPlaying` / `queue` StateFlows, `open`, `playAll`, queue mutation, transport controls, an error `SharedFlow`. |
| `PlayerSessionFacade` | `PlayerChapterService`, `PlayerBookmarkService`, `PlayerSleepTimerService`, `PlayerProgressService`, `PlaybackChapterStore` | Chapter list and current index, bookmark CRUD and seek, sleep timer including end-of-chapter. |
| `AnnotationsFacade` | `AnnotationRepository`, `AnnotationDao` | Per-book annotation flow, tags, refresh, update, delete. |
| `SourcesFacade` | `ConnectionRegistry` | Connection list, enable/disable, edit, remove. Provider auth flows stay in their own Activities. |
| `PreferencesFacade` | `PreferencesManager` (DataStore) | Typed slices only — theme mode, OLED, accent, text scale, reduce motion, skip intervals, default speed, library layout/sort/filters, start tab, home section order. Not a whole-store passthrough. |
| `EinkFacade` | `EinkManager`, `EpdRefreshManager` | `state: StateFlow<EinkState>`, `requestFullRefresh(view)`, mode / refresh-strength / bold-text writes. See [eink.md](eink.md). |
| `ServerToolsFacade` | Per-provider admin and stats APIs | Available targets plus stats, achievements, highlights, bookmarks, history, and related books per connection. |
| `BookOrbitFacade` | BookOrbit provider reads | Insight and achievement DTOs for the BookOrbit screens. |
| `StoryAlignFacade` | StoryAlign job pipeline | Job and candidate-pair flows, create / cancel / retry / delete. |
| `SleepDataFacade` | `HealthConnectSleepDataFacade` | Sleep-session snapshot for the sleep-tracking surfaces. |

Readium, downloads, and per-book sync are not yet behind facades. Reader Activities in `:app` still talk to `ReadiumManager`, `OfflineDownloadManager`, and `SyncCoordinator` directly, because those engines need Android lifecycle integration. New general-purpose UI must not follow that path — add a facade instead.

## Binding pattern

```kotlin
// :engine
@Singleton
class LibraryFacadeImpl @Inject constructor(
    private val repo: AggregatorRepository,
    private val cache: BookCacheDao,
) : LibraryFacade { /* delegate */ }

// :engine — com/enve/app/hearth/FacadeModule.kt
@Module
@InstallIn(SingletonComponent::class)
abstract class FacadeModule {
    @Binds @Singleton
    abstract fun bindLibraryFacade(impl: LibraryFacadeImpl): LibraryFacade
}

// :hearth-ui
@HiltViewModel
class HearthHomeViewModel @Inject constructor(
    private val library: LibraryFacade,
    private val prefs: PreferencesFacade,
) : ViewModel()
```

## Adding a facade

1. Define the interface and any UI-state DTOs in `engine-api/src/main/java/com/enve/engine/<area>/`.
2. Implement it in `engine/src/main/java/com/enve/app/hearth/<Name>FacadeImpl.kt` as a `@Singleton` with `@Inject constructor`.
3. Add one `@Binds @Singleton` line to `FacadeModule`.
4. Inject the interface into the `:hearth-ui` ViewModel that needs it.

Keep the facade thin. It exists to hide backend types from the UI, not to become a second place where domain logic lives.
