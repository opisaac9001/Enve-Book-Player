# Service-Connections Layer Contract

All paths are relative to the repository root.

---

## 1. ServerConnection / ProviderType

**File: `enve/Networking/Models/UniversalModels.swift`**

### `enum ProviderType: String, Codable, CaseIterable`
Cases (raw values matter — they are persisted):
`audiobookshelf`, `plex`, `jellyfin`, `emby`, `webdav`, `premiumize`, `realdebrid`, `local`, `booklore = "grimmory"` (UI name "Grimmory"; custom decoder accepts both `"booklore"` and `"grimmory"`), `komga`, `kavita`, `opds`, `storyteller`, `bookOrbit = "bookorbit"`.
Helpers: `iconName: String` (SF symbol), `assetIconName: String?` (asset-catalog logos, e.g. `PlexLogo`, `AudiobookshelfLogo`).

> Note: TorBox/Premiumize/Real-Debrid are not separate UI tiles — they are WebDAV presets; Real-Debrid is promoted to `ProviderType.realdebrid` at save time. Hardcover and KOReader are **sync integrations**, not `ProviderType`s.

### `enum ConnectionAuthMode: String, Codable, CaseIterable` (same file, public)
`auto`, `usernamePassword`, `token`, `sso` — with `displayName`.

### `struct ServerConnection: Identifiable, Codable, Hashable` (same file, line 116)
Stored fields:
- `id: UUID`, `name: String`, `url: String`, `type: ProviderType`
- `username: String?`, `password: String?`, `token: String?` (API key or JWT), `userId: String?` (required for Jellyfin/Emby)
- `isConnected: Bool`, `lastVerified: Date?`
- `selectedLibraryIds: Set<String>?` — **nil means "all libraries"**
- `isArchived: Bool`
- `rootPath: String?` (cloud providers RD/PM/WebDAV root folder)
- `customHeaders: [String: String]?`, `secretCustomHeaderNames: Set<String>` (auto-classified secret headers; see `isSecretHeaderName`)
- `authMode: ConnectionAuthMode`, `mtlsEnabled: Bool`
- `grimmoryOIDCRedirectURI: String?` (per-connection OIDC redirect override — must persist, provider validates exact match)
- Plex Home user block: `plexHomeUserId/Name/Thumb/Token: String?`, `plexHomeUserIsManaged: Bool?`, `plexOwnerToken: String?`; computed `effectivePlexToken` (home token wins).

**Codable contract (critical):** custom `encode(to:)` **strips all secrets** (token, password, plexHomeUserToken, plexOwnerToken, secret custom-header values) out of the JSON and writes them to `SharedKeychainStore` first (throws if keychain write fails); custom `init(from:)` calls `hydrateSecretsFromSharedKeychain()` to put them back. Helper methods: `persistSecretsToSharedKeychain()`, `hydrateSecretsFromSharedKeychain()`, `publicCustomHeadersForPersistence()`, `allSecretCustomHeaderNames()`.

Also in this file: `CloudflareAccessHeaders` (`CF-Access-Client-Id`/`CF-Access-Client-Secret`/browser `Cookie: CF_Authorization=` merging — `mergedHeaders(...)`, `detectedServiceTokenConfiguration(...)`, `detectedBrowserHeaders(...)`), `struct Library {id, name, type, providerId: UUID; uniqueId = "\(providerId)_\(id)"}`, `Chapter`, `SeriesInfo`, `Author`, `Series`, `Collection`, `LibrarySource`.

### Legacy sibling: `struct BackendConfig` — `enve/Models/Library/BackendConfig.swift`
`id: String, name, type (BackendType: plex/audiobookshelf/jellyfin/emby/storyteller), url, token?, enabled, username?, password?, userId?, selectedLibraryIds?, customHeaders?, authMode, mtlsEnabled` + `init?(from: ServerConnection)`. Still used by Plex/ABS legacy views, Emby login, and `RecentlyPlayedSyncService` (via `AppState.getAllBackends()`).

---

## 2. Persistence stores

### Connections themselves: persisted by **AppState**, not ServerConfigStore
**File: `enve/Models/Application/AppState.swift`** (`@MainActor @Observable public class AppState`, ~4800 LOC, `AppState.shared`)
- `var connections: [ServerConnection]` (line 170) with `didSet` → `saveConnections()` + `syncProviders()` + prune-on-library-selection-change + `connectionsChanged: PassthroughSubject<[ServerConnection], Never>`.
- `saveConnections()` (line 3778): JSON-encode → `UserDefaults.standard` key **`"enve_server_connections"`**; then mirrors token/password to `SharedKeychainStore` and `await ServerConnectionCloudKitSync.shared.pushAll()` (CloudKit mirror of non-secret bits).
- `loadConnections()` (line 3862): runs `migrateConnectionSecretsIfNeeded()` (one-time flag `enve.connectionSecretsMigratedV1`), decodes blob (**on decode failure it preserves the blob and sets `StoreHealth.shared.state = .rebuildRequired` — never overwrites with `[]`**), then merges legacy `ServerConfigStore.loadBackends()` entries not already present.
- Add = `appState.connections.append(conn)`; edit = mutate by index; archive = `isArchived = true`; remove = `connections.remove(at:)`. There are no dedicated add/remove functions — the `didSet` is the contract.
- `connectionsNeedingReauth: [ServerConnection]` (line 37) — set on Cloudflare Access rejection; blocks refresh until reauth.
- `updateConnectionToken(_:)` (line 792) — providers call back via `onTokenUpdated` when they rotate tokens (ABS/Booklore/Storyteller/BookOrbit).
- `getAllBackends() -> [BackendConfig]` (line 985) — connections converted + legacy ServerConfigStore backends appended.

### `ServerConfigStore` — `enve/Services/Network/ServerConfigStore.swift`
`@MainActor final class ServerConfigStore { static let shared }` — **legacy/SMB only**:
- `saveBackends/loadBackends([BackendConfig])` — UserDefaults key `"backends"`.
- `saveSMBServers/loadSMBServers([SMBServerConfiguration])` — key `"smbServers"`.
- `saveSMBPassword/loadSMBPassword/deleteSMBPassword(for serverId: UUID)` — `KeychainHelper` key `"smb:password:<uuid>"`.
- `saveSMBBooks/loadSMBBooks(serverId:)` — key prefix `"smbBooks_"`.

### Keychain layers
- **`SharedKeychainStore`** — `enve/Services/CompanionReading/SharedKeychainStore.swift`. iCloud-synchronizable keychain (`kSecAttrSynchronizable`, `kSecAttrAccessibleAfterFirstUnlock`), service `"com.enve.enve.connections"`, access group `"group.com.enve.enve"` (shared with tvOS). API: `setToken/token/deleteToken(forConnectionId:)`, same for `password`, `plexHomeUserToken`, `plexOwnerToken`, `setCustomHeaderValue/customHeaderValue(headerName:forConnectionId:)`.
- **`KeychainHelper`** — `enve/Utilities/KeychainHelper.swift` (device-local). Used for: refresh tokens (`"abs_refresh_<connId>"`, `"booklore_refresh_<connId>"`), per-provider passwords (`"storyteller_password_<id>"`, `"abs_password_<id>"`, `"<providerRaw>_password_<id>"`), Hardcover API key (`"hardcoverApiKey"`), SMB passwords, MTLS pending cert.
- **`PlexAuthStore`** — `enve/Services/Plex/PlexAuthStore.swift` — Plex.tv account token (`loadToken/saveToken`), server URL, server access token.
- **`MTLSManager`** — `enve/Services/Network/MTLSManager.swift` — PKCS12 import: `storePendingCertData(_:)`, `validatePKCS12(_:password:)`, `storePendingCert(data:password:)`, `promotePendingCert(to: connectionId)`, `deleteCert(for:)`.
- Other sibling stores: `LocalLibraryStorageStore` (local folder libraries + security-scoped bookmarks), `SettingsManager` (Hardcover key et al.).

---

## 3. PluginRegistry + LibraryProvider

### `PluginRegistry` — `enve/Plugins/PluginRegistry.swift`
`@MainActor final class PluginRegistry { static let shared }`
- `typealias LibraryProviderFactory = (ServerConnection) -> LibraryProvider`
- `register(libraryProviderFactory:for: ProviderType)`, `makeLibraryProvider(for: ServerConnection) -> LibraryProvider?`, `registeredProviderTypes`
- `register(sink: any SyncSink)` / `unregister(sinkId:)` / `sinks(applicableTo: Book)`
- `register(syncStrategy: any ProviderSyncStrategy)` / `unregister(syncStrategyId:)` / `syncStrategies`

**Bootstrap (must be replicated exactly): `enve/App/EnveApp.swift` `bootstrapPlugins()` (line 27)**
- Sinks: `ProviderSyncSink.shared`, `BookloreKoreaderSink.shared`, `CloudKitProgressSync.shared`
- Provider factories: `.audiobookshelf→AudiobookshelfProvider`, `.plex→PlexProvider`, `.jellyfin→JellyfinProvider`, `.emby→EmbyProvider`, `.webdav→WebDAVProvider`, `.premiumize→WebDAVProvider`, `.realdebrid→RealDebridProvider`, `.booklore→BookloreProvider`, `.komga→KomgaProvider`, `.kavita→KavitaProvider`, `.opds→OPDSProvider`, `.storyteller→StorytellerProvider`, `.bookOrbit→BookOrbitProvider` (no factory for `.local`)
- Sync strategies: `StorytellerSyncStrategy`, `BookloreEbookSyncStrategy`, `BookloreAudiobookSyncStrategy`, `BookOrbitSyncStrategy`

Provider implementations live in `enve/Networking/Providers/` (one file per backend + `JellyfinProvider+Auth.swift`, `WebDAV/` subfolder, `RSSPodcastParser.swift`, `iTunesPodcastProvider.swift`).

### `protocol LibraryProvider: AnyObject` — `enve/Networking/LibraryProvider.swift`
```swift
var connection: ServerConnection { get set }
func validateConnection() async throws -> Bool
func fetchLibraries() async throws -> [Library]
func fetchBooks(libraryId: String) async throws -> [Book]
func fetchBookBatches(libraryId: String) -> AsyncThrowingStream<LibraryFetchBatchResult, Error>  // default adapts fetchBooks
func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book]
func fetchBooksDelta(libraryId: String, since: Date) async throws -> (books: [Book], cursor: Date)?  // default nil
func fetchCollections(libraryId: String?) async throws -> [Collection]
func fetchSeries(libraryId: String) async throws -> [Series]
func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress]
func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book
func getAudioURL(for: Book) -> URL?
func getStreamingHeaders() -> [String: String]
func startPlaybackSession(for: Book) async throws -> PlaybackSessionInfo   // {sessionId, audioTracks: [AudioTrackInfo], chapters, serverCurrentTime}
func updatePlaybackProgress(book:sessionId:currentTime:isFinished:timeListened:) async throws
func downloadEbook(for: Book, onProgress: (@Sendable (Double) -> Void)?) async throws -> URL
func updateEbookProgress(for: Book, progress: Double, epubLocator: String?) async throws
func fetchEbookProgress(for: Book) async throws -> (progress, locator, updatedAt, isAbandoned)?
func fetchAudiobookProgress(for: Book) async throws -> (positionSeconds, percentage, trackIndex, updatedAt, isAbandoned)?
func fetchPageCount(for: Book) async throws -> Int          // comic page streaming
func fetchPage(_ pageNumber: Int, for: Book) async throws -> Data
var capabilities: ProviderCapabilities { get }              // default []
```
`ProviderFactory.create(for:)` = thin wrapper over registry. `ProviderError` enum (invalidURL/unauthorized/serverError/.../noCFI).
`ProviderCapabilities` (`enve/Plugins/ProviderCapabilities.swift`): OptionSet — `fullImport, pagedImport, streamingImport, deltaImport, recentBooks, series, collections, audiobookProgressPull/Push, ebookProgressPull/Push, downloads, coverAuthHeader, coverAuthQuery, serverPageStreaming, backgroundOperation`. Matrix documented in `docs/architecture/provider-capability-matrix.md`.

---

## 4. Connection-setup UI flow (the part a rebuild must replicate)

### Entry points
- **`enve/Screens/Sources/AddSourceScreen.swift`** presents file, server, and network-storage sources.
- **`enve/Screens/Settings/SettingsScreen.swift`** and **`SourceDetailScreen.swift`** list and manage saved connections.

### The unified login system (modern path)
- **`enve/Screens/Sources/ConnectionCapability.swift`** — `struct ConnectionCapability` declares per-provider form features: `supportsUsernamePassword/Token/OIDC/QuickConnect/WebLogin`, `credentialsOptional`, `supportsBrowserSignIn/CustomHeaders/ServiceTokens/MTLS/LibrarySelection/WebDAVPresets`, `serverURLPlaceholder`, `credentialLabels`. Static presets: `.emby, .jellyfin, .audiobookshelf, .storyteller, .webdav, .booklore, .komga, .kavita, .opds, .bookOrbit`; `capability(for:)` returns **nil for `.plex, .premiumize, .realdebrid, .local`** (Plex keeps its own PIN flow). `UnifiedWebDAVPreset` (generic/torbox/premiumize/realdebrid) with preset URLs and field labels.
- **`SourcesProviderFormScreen.swift`** — generic form: scheme picker (http/https) + host field + optional connection name; auth-method picker from capability (`UnifiedAuthMethod`: usernamePassword/token/quickConnect/oidc/webLogin); advanced section: Cloudflare browser sign-in (`BrowserSessionLoginView` captures the `CF_Authorization` cookie), CF service tokens (Client ID/Secret), custom headers, mTLS (.p12/.pfx file import + password validation via `MTLSManager`). On Connect: dispatch to the delegate; then optional `fetchLibraries` → `LibrarySelectionView` (Jellyfin/Emby only); finishes with `onSuccess(ServerConnection)`. Grimmory OIDC redirect-URI picker (presets from `AppAuthRedirectURI.grimmoryPresetOptions`).
- **`LoginDelegates.swift`** — `protocol UnifiedLoginDelegate` with methods:
  `authenticate(serverURL:username:password:customHeaders:) -> ServerConnection`, `authenticateWithToken(...)`, `startQuickConnect(...) -> (code, secret)`, `pollQuickConnect(secret:serverURL:customHeaders:)`, `authenticateWithOIDC(serverURL:redirectURIOverride:customHeaders:)`, `authenticateWithWebLogin(...)`, `fetchLibraries(connection:) -> [LibraryMetadata]`.
- **`LoginComponents.swift`** — reusable cards (`LoginServerCard`, `LoginCredentialsCard`, `LoginTokenCard`, `LoginQuickConnectCard`, `LoginAdvancedOptions`, `LoginMTLSCard`, `LoginConnectButton`, banners).

### Per-provider add-flow contract

| Provider | Inputs | Auth flow + exact service calls | Post-auth |
|---|---|---|---|
| **Audiobookshelf** | URL (+ optional subdirectory in legacy form), username/password OR OIDC; CF headers; mTLS | u/p: `AudiobookshelfService.shared.login(username:password:serverURL:customHeaders:) -> ABSUser` (token = `accessToken ?? token`). OIDC (HTTPS only): PKCE S256 + state → `AudiobookshelfService.shared.preflightOIDC(serverURL:challenge:redirectURI:state:customHeaders:)` → `ASWebAuthenticationSession` (scheme `enveapp`, redirect `enveapp://oauth/abs`) → `AudiobookshelfService.shared.loginWithOIDC(serverURL:code:verifier:state:cookies:customHeaders:)`. Legacy form also checks `getServerInfo(serverURL:preventAutoLogin:true)` for `authMethods` containing `"openid"` + auto-launch. | refresh token → `KeychainHelper` `"abs_refresh_<id>"`; `userId` from ABSUser; launch re-auth via `AppState.refreshAudiobookshelfAuthOnLaunch()` |
| **Plex** | nothing (PIN) or manual `X-Plex-Token`; server picked from account | `POST https://plex.tv/api/v2/pins?strong=true` with `X-Plex-Product=Enve`, `X-Plex-Client-Identifier` (= `identifierForVendor` or `StorageService.loadDeviceUUID()`), device headers → show 4-char code + open `https://app.plex.tv/auth#?clientID=...&code=...` → poll `GET /api/v2/pins/{id}` every 2s (30-min timeout) until `authToken` → `PlexAuthStore.shared.saveToken(token)` → `PlexService().getPlexHomeUsers(token:)` → optional `PlexHomeUserPickerView` (switch user; non-admin → `PlexService.resolveServerAccessToken(userToken:serverUrl:ownerToken:switchedUserId:)`) → `PlexService().getPlexServers(token:ownerToken:switchedUserId:)` → probe each connection URI with `GET {uri}/identity?X-Plex-Token=` (5s timeout, first success wins) → `verifyAndAdd()` | Connection stores `plexOwnerToken`, plexHomeUser* block. All in `SourceConnectionView.plexLoginLayout` (AddLibrarySourceView.swift lines 590–760, 1402–1661) |
| **Jellyfin** | URL, username/password OR Quick Connect; CF; mTLS; library picker | u/p: `POST {url}/Users/AuthenticateByName` body `{Username, Pw}` with `MediaBrowser Client="Enve", Device=..., DeviceId=..., Version="1.0"` in `Authorization`/`X-Emby-Authorization` → `(AccessToken, User.Id)`. Quick Connect: `JellyfinQuickConnectService.shared.isQuickConnectEnabled` → `.initiateQuickConnect` → `(Code, Secret)` → `.pollForAuthentication(secret:...cancellationCheck:)` → `.authenticateWithQuickConnect`. Libraries: `GET {url}/Users/{userId}/Views`. URL normalization: `:8920`→https, `:8096`→http, LAN IP→http | `userId` mandatory; `supportsLibrarySelection: true` → `LibrarySelectionView` → `selectedLibraryIds` |
| **Emby** | URL, username/password; CF; mTLS; library picker | `EmbyProvider.normalizeServerURL` → `EmbyProvider.shared.authenticate(serverURL:username:password:) -> token` → `EmbyService.shared.validateToken(backend:)` + `getCurrentUser(backend:) -> userId` → libraries `EmbyService.shared.getLibraries(backend:userId:)` (filtered to audiobooks/books types) | |
| **Grimmory (booklore)** | URL, username/password OR token OR OIDC; CF (browser/service tokens); mTLS; redirect-URI picker | u/p or token → `AppState.validateConnection` (→ `BookloreProvider.validateConnection()`). OIDC: `GET {url}/api/v1/public-settings` (oidcEnabled + provider {clientId, issuerUri, scopes}); `GET {url}/api/v1/auth/oidc/state`; OIDC discovery `{issuer}/.well-known/openid-configuration`; PKCE S256 + nonce; redirect default `booklore://oauth2-callback` (per-connection override persisted in `grimmoryOIDCRedirectURI`); `POST {url}/api/v1/auth/oidc/callback` body `{code, codeVerifier, redirectUri, nonce, state}`; `GET {url}/api/v1/users/me` for username. All via `InsecureURLSession.shared` | refresh token → `"booklore_refresh_<id>"`; launch re-auth `AppState.refreshBookloreAuthOnLaunch()` |
| **Komga** | URL + username/password, API key, or OAuth2/OIDC; browser/service headers; mTLS | Password/API key validation uses `KomgaProvider` (`Basic` or `X-API-Key`). SSO discovers `GET /api/v1/oauth2/providers`, opens `{url}/oauth2/authorization/{registrationId}`, captures the returned `KOMGA-SESSION` cookie, verifies `GET /api/v2/users/me`, and persists the provider id for reauthentication. Quick Connect auto-launches SSO when providers are advertised. | Session cookie → secret `Cookie` custom header in Keychain; expired sessions are marked for interactive reauthentication. |
| **Kavita / OPDS / BookOrbit** | URL + username/password or token (OPDS: credentials optional; BookOrbit: u/p only) | `ValidatedConnectionLoginDelegate` (generic): builds temp `ServerConnection` → `appState.validateConnection(tempConnection)` → `PluginRegistry.makeLibraryProvider` → `provider.validateConnection()` | |
| **Storyteller** | URL, username-or-email/password OR Web Login | u/p: `StorytellerProvider(connection:).loginWithCredentials(usernameOrEmail:password:) -> token` then `fetchCurrentUser()` for `userId`. Web login: open `{url}/api/v2/token/app` in `ASWebAuthenticationSession` (callback scheme `storyteller`), short token from `?token=` → `provider.exchangeAppToken(shortToken) -> longToken` → `fetchCurrentUser()` | Standalone `StorytellerLoginView` (legacy, `onSuccess: (BackendConfig) -> Void`) also exists |
| **WebDAV (generic / TorBox)** | preset picker; URL (locked for presets); username/password (TorBox: email/password) | validate via `appState.validateConnection` → `WebDAVProvider.validateConnection()` | also writes `WebDAVServerConfig` via `RemoteImportService.shared.saveWebDAVServer(...)`; then **root folder picker** `WebDAVBrowserView(selectionMode: .rootPicker)` → sets `connection.rootPath` + `refreshConnectionLibraries` |
| **Premiumize** | WebDAV preset `https://webdav.premiumize.me`; Customer ID + API Key/PIN as basic auth | same WebDAV path (factory maps `.premiumize → WebDAVProvider`) | |
| **Real-Debrid** | preset URL `https://api.real-debrid.com/rest/1.0`; API token only | type forced to `.realdebrid` (`ValidatedConnectionLoginDelegate.inferredProviderType` / `verifyAndAdd`); `RealDebridProvider.validateConnection()` | then `CloudFolderBrowserView` root-folder picker → `rootPath` |
| **SMB** | `SMBConnectView` (hostname, port, share, username, password, folder path) | `SMBLibraryService.shared.saveSource(source, password:)` + `scanLibrary(source, mode: .quick)`; persisted via `ServerConfigStore` SMB keys | not a `ServerConnection`; separate `SMBLibrarySource` list |
| **Files / iCloud** | document pickers (file / book / folder / multiple books) | `RemoteImportService.shared.importFromFilesApp(urls:audioSelectionMode:)` + `LocalLibraryStorageStore`/`LocalLibraryService.scanLibrary` | |
| **Google Drive / Dropbox / iCloud as cloud source** | `CloudSourceConnectionView(provider:)` with `GoogleDriveProvider` / `DropboxProvider` / `iCloudDriveProvider` | OAuth via provider object | |

### Common save path (all server providers)
`SourceConnectionView.verifyAndAdd()` / `handleUnifiedSuccess(connection:)` (AddLibrarySourceView.swift lines 1663–2095):
1. `appState.validateConnection(temp)` → `(Bool, ServerConnection)` (`enve/Models/Application/AppState.swift:2414`; also auto-corrects Emby↔Jellyfin via `GET /System/Info/Public` ProductName sniffing).
2. Set `isConnected = true`, `lastVerified = Date()`; persist refresh tokens / per-provider password to `KeychainHelper`.
3. `appState.connections.append(finalConnection)` (didSet does persistence + provider creation).
4. `importAndSyncConnection`: `await appState.refreshConnectionLibraries(providerId:)` then `await SyncCoordinator.shared.runRecentlyPlayedSync(trigger: .appLaunch)`.

### Edit/manage: `enve/Screens/Sources/SourceDetailScreen.swift` (`ServerSettingsView(connection: Binding<ServerConnection>)`)
Editable: name, URL, username, password/token (single secure field), `authMode` picker, mTLS toggle + cert import/validate, Cloudflare client id/secret/single-header + browser login, **Libraries multi-select** (`selectedLibraryIds`, nil = all, via `provider.fetchLibraries()`), Plex account section + Home-user switching, SSO re-authenticate, per-connection Booklore↔KOReader sync section (`koreaderUsername/password/enabled` + auth test), **Archive** (`isArchived = true`, keeps settings, removes books), **Unarchive**, **Delete** (removes from `appState.connections`, clears `PlexAuthStore` URL for Plex, `MTLSManager.deleteCert`). Saving writes back through the binding into `appState.connections`.

Provider administration screens live under `enve/Screens/Admin/`; provider-specific source flows live under `enve/Screens/Sources/`.

OAuth constants: `enum AppAuthRedirectURI` in `enve/Services/Network/OAuthManager.swift` — `absScheme="enveapp"`, `audiobookshelf="enveapp://oauth/abs"`, `grimmory="booklore://oauth2-callback"`, `grimmoryNew="grimmory://oauth2-callback"`, `grimmoryEnveSpecific="enveapp://oauth/grimmory"`, `grimmoryPresetOptions`. `OAuthManager.shared` is the `ASWebAuthenticationPresentationContextProviding`.

---

## 5. Launch / fetch pipeline (connection → provider → books)

`AppState.init()` (`enve/Models/Application/AppState.swift:453`):
1. `loadConnections()` → `connections.didSet` → `syncProviders()` (line 742): builds/repairs `private var providers: [UUID: LibraryProvider]` from non-archived connections via `ProviderFactory.create`, wires `onTokenUpdated` callbacks (`setupProviderCallbacks`).
2. Async startup task: `loadCachedBooks()` (SwiftData `BookStoreRepository` via `bookStore` — **books come from cache at launch, not network**), migrations, `startupCacheLoaded = true`, then after a 5s delay → `SyncCoordinator.shared.runRecentlyPlayedSync(trigger: .appLaunch)`.
3. `SplashScreenView.onAppear` / scene-active: `appState.refreshAudiobookshelfAuthOnLaunch()` (parallel token re-validation with 10s/connection timeout) + `refreshBookloreAuthOnLaunch()`; `ServerConnectionCloudKitSync.shared.bootstrap()` from `enveApp`.

Network refresh paths:
- `refreshConnectionLibraries(providerId: UUID) async` (line 1558): provider → `fetchLibraries()` → append/prune `appState.libraries` → filter by `selectedLibraryIds` → `refreshSingleLibrary(...)` per library (streaming/paged import into `allBooks` + bookStore) → `saveMetadataAsync()`. Skips connections in `connectionsNeedingReauth`; marks them on Cloudflare rejection. Publishes `isRefreshing` + `libraryImportProgress` (observable struct: providerName, loadedCount, phase).
- `refreshLibrary() async` (line 1009): full refresh — loops every provider via `refreshProvider`, then local libraries, posts `.libraryDidFinishSync` / `.collectionsDidChange`, `allBooksChanged.send(())`.

---

## 6. Sync surface a UI touches

### `SyncCoordinator` — `enve/Services/Sync/SyncCoordinator.swift` (`@MainActor @Observable`, `.shared`)
Observable state bound by Settings/Sync Center: `isSyncing`, `lastSyncDate`, `lastSyncDeviceName`, `syncEnabled` (UserDefaults `"crossDeviceSyncEnabled"`), `isCloudKitAvailable`, `pendingSyncCount` (forwards `PendingSyncQueueStore.shared.count`).
UI-callable: `manualSync()` (= `refreshFromCloud()` + `runRecentlyPlayedSync(trigger: .homePullToRefresh)` + `KOReaderSyncService.shared.pullAllAndMerge()` + `flushPendingSyncs()`), `runRecentlyPlayedSync(trigger: ServerStatusSyncTrigger) -> ServerStatusSyncResult` (cancellable; suppressed while ebook reader open unless pull-to-refresh), `flushPendingSyncs()`, `resolveEbookConflict(bookStableId:useServer:)` (conflict UI hook — consumed in `enve/Screens/Reader/ReaderScreen.swift` via `EbookConflictStore`).
`ServerStatusSyncTrigger` = `.appLaunch | .homePullToRefresh`; `ServerStatusSyncResult {attemptedBackendCount, pulledItemCount, pushedItemCount, failedBackends, wasCancelled, mergedItemCount, hasFailures}` (`enve/Services/Sync/RecentlyPlayedSyncService.swift`).

The same coordinator owns per-book sink fan-out: `pullOnOpen(book:)` (pull from `PluginRegistry.sinks(applicableTo:)`, pick freshest `SyncSnapshot {progress, positionSeconds, locator, lastUpdate, isFinished, source}`, conflict-resolve → apply / push / enqueue `EbookSyncConflict` into `EbookConflictStore`), `pushProgress(book:forceImmediate:)` (2s debounce), and `SyncEvent` streams (`enve/Services/Sync/SyncEvent.swift`). Hardcover threshold push lives here too. CloudKit-specific record matching and notification handling remain in `CloudProgressService` behind the coordinator.

### Plug-in contracts
- `SyncSink` (`enve/Plugins/SyncSink.swift`): `id`, `displayName`, `isApplicable(to: Book)`, `pull(book:) async -> SyncSnapshot?`, `push(_: ProgressUpdate) async throws`. `ProgressUpdate {book, positionSeconds, progress, locator, isFinished, timeListened}`. Conformers: `ProviderSyncSink` (the active provider's own endpoint), `BookloreKoreaderSink`, `CloudKitProgressSync`/`CloudKitSink`.
- `ProviderSyncStrategy` (`enve/Plugins/ProviderSyncStrategy.swift`): `id`, `displayName`, `sync(force:launchOptimized:) async -> ProviderSyncResult {pulled, pushed}`; each owns its own ≥60s throttle. ABS/Jellyfin/Emby batch sync runs inline in `RecentlyPlayedSyncService` (shared `getAllProgress` shape) — keep that detail; the strategies cover Storyteller/Booklore/BookOrbit.
- Memory note: registering a strategy is not enough — `RecentlyPlayedSyncService`'s early-return guard must also recognize the provider's connections or it never runs.

### Sync Center UI — `enve/Screens/Settings/SyncScreen.swift`
Reads `progressSync.isSyncing/lastSyncDate/isCloudKitAvailable/syncEnabled/pendingSyncCount`; lists non-archived `appState.connections` as `SyncProviderRow`; pending-queue "flush" button → `progressSync.flushPendingSyncs()`; `BookloreExperimentalSyncStore.shared` toggles.

---

## 7. Hardcover / KOReader settings surfaces

### Hardcover — `enve/Screens/Settings/HardcoverScreen.swift`
- Single input: **API key**, stored via `SettingsManager.shared.hardcoverApiKey` (get/set → `KeychainHelper` key `"hardcoverApiKey"`; never UserDefaults).
- Validate: `HardcoverService.shared.getCurrentUser()` (GraphQL; auth-failure detection via `HardcoverError.isAuthenticationFailure` auto-clears the key with `SettingsManager.shared.clearHardcoverAccess(reason:)`).
- Connected state shows `@username`, stats from `HardcoverSyncService.shared.getSyncStats()` (started/completed) and `SettingsManager.shared.getAllHardcoverMatches().count`; Disconnect = `clearHardcoverAccess` + `HardcoverSyncService.shared.clearSyncTracking()`.
- Sync settings section (when connected) + tutorial sheet (`HardcoverTutorialView`). Auto-matching: `HardcoverAutoMatcher` / per-book matches in SettingsManager; push threshold `AppConstants.Sync.hardcoverSyncThreshold` used by `SyncCoordinator`.

### KOReader (KOSync) — `enve/Screens/Settings/KOReaderScreen.swift`
- Fields: `serverURL`, `username`, `password`, `autoSync` toggle.
- Service: `KOReaderSyncService.shared` (`enve/Services/KOReader/KOReaderSyncService.swift`) — `config: KOReaderConfig {serverURL, username, autoSyncEnabled, isConfigured, baseURL}` ; `updateConfig(serverURL:username:plaintextPassword:autoSync:)`, `authorize()` (Connect button; password cleared from UI after), `register(username:plaintextPassword:serverURL:)` (create account), `clearConfig()` (disconnect), `pullAllAndMerge() -> Int` (Sync Now; also invoked by `manualSync()`).
- Companion views in the same file: `KOReaderLinksView` (per-ebook link list) and a hash editor — manual partial-MD5 document hash entry or compute from file via `KOReaderSyncService.computePartialMD5(fileURL:)`; BookBridge mapping import section.
- Separate per-connection Booklore↔KOReader credentials live in `ServerSettingsView` (koreader* fields) backed by `BookloreKoreaderSink`.

---

### Invariants worth preserving verbatim
- `ProviderType` raw values and the `booklore`/`grimmory` decode aliasing; `ServerConnection` CodingKeys and the encode-strips-secrets/decode-hydrates keychain dance; UserDefaults key `"enve_server_connections"`.
- `connections.didSet` side effects (save + keychain mirror + CloudKit push + provider rebuild + prune + `connectionsChanged`).
- Keychain key formats: `"abs_refresh_<uuid>"`, `"booklore_refresh_<uuid>"`, `"<type>_password_<uuid>"`, `"storyteller_password_<uuid>"`, `"abs_password_<uuid>"`, `"smb:password:<uuid>"`, `"hardcoverApiKey"`; SharedKeychainStore service/access-group strings.
- `selectedLibraryIds == nil` ⇒ all libraries; archived connections keep settings but get no provider.
- Tokens in streaming and cover URLs, `NSAllowsArbitraryLoads`, and `InsecureURLSession` support user-configured LAN servers and self-signed certificates.
- Add-connection completion must call `refreshConnectionLibraries(providerId:)` then `runRecentlyPlayedSync(trigger: .appLaunch)`, and WebDAV/Real-Debrid must show their root-folder pickers before finishing.
