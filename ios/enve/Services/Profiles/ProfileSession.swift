import Foundation
#if canImport(WebKit)
import WebKit
#endif

@MainActor
final class ProfileSession {
    static let owner: ProfileSession = {
        do {
            return try ProfileSession(profile: FamilyProfile(id: FamilyProfile.ownerID, name: "Adult", role: .adult))
        } catch {
            fatalError("Unable to open owner profile: \(error)")
        }
    }()

    let profile: FamilyProfile
    let storage: ProfileStorageLocations
    let defaults: UserDefaults
    private let allowsSystemIntegrations: Bool
    let libraryDatabase: BookStoreManager
    let playbackQueue: PlaybackQueueStore
    let playbackState: PlaybackStateManager
    let keychain: SharedKeychainStore
    let legacyKeychain: KeychainHelper
    let tokenStorage: SecureTokenStorage
    let transport: InsecureURLSession
    let mtls: MTLSManager
    let serverConfig: ServerConfigStore
    let sessionManager: SessionManager
    let plexAuth: PlexAuthStore
    let oauth: OAuthManager
    let providerConnections: ProviderConnectionStore
    let appState: AppState
    let localStorage: LocalStorageManager
    let ebooks: LocalEbookImporter
    let localLibraryService: LocalLibraryService
    let groupingOverrides: AudiobookGroupingOverrideStore
    let localLibrary: LocalLibraryStorageStore
    let preferences: LibraryDisplayPreferencesStore
    let playerState: PlayerStateStore
    let storageService: StorageService
    let playbackSpeed: PlaybackSpeedMemory
    let rejectedContent: RejectedContentStore
    let authenticationFailures: AuthenticationFailureStore
    let pendingSync: PendingSyncQueueStore
    let readerArtifacts: ReaderArtifactsStore
    let bookProgress: BookProgressStore
    let userCollections: UserCollectionStore
    let smartCollections: SmartCollectionStore
    let savedBooks: SavedBooksStore
    let dismissedShelves: HearthDismissedShelfStore
    let lastOpened: LastOpenedBookStore
    let workOverrides: WorkOverrideStore
    let seriesAliases: SeriesAliasStore
    let podcastSubscriptions: PodcastSubscriptionStore
    let deletedBooks: DeletedBooksTombstoneStore
    let catalogCheckpoints: CatalogImportCheckpointStore
    let catalogRefreshGate = CatalogRefreshGate()
    let catalogMapping: CatalogMappingRevisionStore
    let remoteLibraryBrowse: RemoteLibraryBrowseStore
    let siloReaderArtifacts: SiloReaderArtifactIDStore
    let mirrorCheckpoints: ServerMirrorCheckpointStore
    let opdsProgressionEndpoints: OPDSProgressionEndpointStore
    let opdsAuthentication: OPDSAuthenticationStore
    let metadataStorage: MetadataStorage
    let metadataManager: MetadataManager
    let appCache: AppCache
    let imageCache: DiskImageCache
    let matchQueue: MatchQueueStorage
    let historyStore: HistorySessionStore
    let listeningStore: ABSLocalListeningStore
    let crossProviderHistory: CrossProviderHistorySessionSync
    let historySync: ProviderHistorySessionSync
    let listeningStats: ListeningStatsTracker
    let readingStats: ReadingStatsTracker
    let downloads: UnifiedDownloadService
    let downloadActivity: ProfileDownloadActivity
    let registry: PluginRegistry
    let autoSaver = ProgressAutoSaver()
    let narratedPositions: NarratedAudioPositionStore
    let rewindTracker: RemoteRewindTracker
    let ebookConflicts: EbookConflictStore
    private var artworkOperations: [UUID: Task<Void, Never>] = [:]
    private var hasStarted = false
    private var retirementTask: Task<Void, Never>?
    private(set) var isRetired = false
    private(set) var allowsSystemAccess = false
    private var hasSystemAccessAuthority = false

    private var didCreateNetworkSession = false
    lazy var networkSession: URLSession = {
        didCreateNetworkSession = true
        return transport.makeSession(configuration: isOwner ? .default : .ephemeral)
    }()
    lazy var bookOrbitArtifacts = BookOrbitReaderArtifactSync(
        defaults: defaults, artifacts: readerArtifacts, bookStore: bookStore
    )
    lazy var cloudKit = CloudKitProgressSync(
        isSyncEnabled: { [unowned self] in sync.syncEnabled },
        isSyncAvailable: { [unowned self] in sync.isCloudKitAvailable },
        userProgress: progress,
        bookProgress: bookProgress
    )
    private var didCreateCloudProgress = false
    lazy var cloudProgress: CloudProgressService = {
        precondition(isOwner)
        didCreateCloudProgress = true
        return CloudProgressService(libraryCache: appState.libraryCache, connectionStore: providerConnections,
            bookRepository: bookStore, playbackState: playback.composition.controller, cloudKit: cloudKit, profileSession: self)
    }()
    private var didCreateKoreaderSink = false
    lazy var koreaderSink: BookloreKoreaderSink = {
        didCreateKoreaderSink = true
        return BookloreKoreaderSink(providerConnections: providerConnections, profileSession: self)
    }()
    private var didCreateOPDSBulkImport = false
    lazy var opdsBulkImport: OPDSBulkImportService = {
        didCreateOPDSBulkImport = true
        return OPDSBulkImportService(profileSession: self)
    }()
    private var didCreateOPDSLogin = false
    lazy var opdsLogin: OPDSAuthenticationService = {
        didCreateOPDSLogin = true
        return OPDSAuthenticationService(store: opdsAuthentication, certificateTransport: transport, ephemeralBrowser: !isOwner)
    }()
    lazy var currentPlaybackPersister = CurrentPlaybackPersister(playbackState: playback.composition.controller, coordinator: sync, cloudSync: cloudKit)
    #if os(iOS)
    private var didCreateWidgetBridge = false
    lazy var widgetBridge: BookWidgetBridge = {
        didCreateWidgetBridge = true
        return BookWidgetBridge(playback: playback.composition.controller, profileSession: self)
    }()
    private var didCreateWatchBridge = false
    lazy var watchBridge: WatchSessionBridge = {
        didCreateWatchBridge = true
        return WatchSessionBridge(providerResolver: providerConnections, connectionAccess: providerConnections,
            bookQuerying: bookStore, libraryCache: appState.libraryCache,
            playback: playback.composition.controller, profileSession: self)
    }()
    #endif
    #if canImport(WebKit)
    lazy var websiteDataStore: WKWebsiteDataStore = isOwner ? .default() : WKWebsiteDataStore(forIdentifier: UUID(uuidString: profile.id)!)
    #endif
    lazy var metadataLayering = MetadataLayeringManager(playbackStateManager: playbackState, localStorage: localStorage, providerConnections: providerConnections)
    lazy var embyProvider = EmbyProvider(connection: ServerConnection(name: "Emby", url: "", type: .emby), profileSession: self)
    lazy var embyService = EmbyService(profileSession: self)
    lazy var jellyfinQuickConnect = JellyfinQuickConnectService(session: networkSession)
    lazy var theme = ThemeManager(defaults: defaults)
    #if os(iOS)
    lazy var ambientColors = AmbientColorStore(imageCache: imageCache)
    #endif
    lazy var absService = AudiobookshelfService(session: networkSession)

    #if os(iOS)
    private var storyAlignServiceStorage: AnyObject?
    @available(iOS 26.0, *)
    var storyAlignService: StoryAlignService {
        precondition(isOwner)
        if let service = storyAlignServiceStorage as? StoryAlignService { return service }
        let service = StoryAlignService(libraryCache: appState.libraryCache, bookRepository: bookStore, profileSession: self)
        storyAlignServiceStorage = service
        return service
    }

    #else
    var storyAlignService: StoryAlignService { .shared }
    #endif
    var isOwner: Bool { profile.id == FamilyProfile.ownerID }
    var serverSyncEnabled: Bool {
        ProfileServerSyncPreferences(defaults: defaults, isOwner: isOwner).isEnabled
    }
    var bookStore: BookStoreRepository { appState.bookStore }
    private var didCreatePlayback = false
    lazy var playback: ProfilePlaybackSession = {
        didCreatePlayback = true
        return ProfilePlaybackSession(profileSession: self)
    }()
    #if os(iOS)
    private var didCreateFileSharing = false
    lazy var fileSharing: FileSharingImportCoordinator = {
        didCreateFileSharing = true
        return FileSharingImportCoordinator(profileSession: self)
    }()
    #endif
    private var didCreateRemoteImport = false
    lazy var remoteImport: RemoteImportService = {
        didCreateRemoteImport = true
        return RemoteImportService(profileSession: self)
    }()
    #if os(iOS)
    lazy var podcastsModel = PodcastsModel(profileSession: self)
    lazy var journalListening = JournalListeningStatsModel(profileSession: self)
    lazy var journalReading = JournalReadingStatsModel(profileSession: self)
    lazy var journalHub = JournalHubModel(profileSession: self, journal: engine.journal, providerConnections: providerConnections)
    lazy var journalLibraryStats = JournalLibraryStatsModel(library: bookStore)
    lazy var journalInsights = JournalInsightsModel(library: bookStore)
    lazy var achievements = EnveAchievementsModel(journal: engine.journal, books: bookStore, history: historyStore)
    lazy var libraryModel = LibraryModel(profileSession: self)
    #endif
    private var didCreateEngine = false
    lazy var engine: EnveEngine = {
        didCreateEngine = true
        return EnveEngine(profileSession: self)
    }()
    var linkedProgress: LinkedBookProgressCoordinator { playback.linkedProgress }
    lazy var ebookLinker = EbookAudiobookLinker(libraryCache: appState.libraryCache, bookRepository: bookStore, profileSession: self)
    lazy var ebookChapters = EbookChapterSyncService(importer: ebooks)
    lazy var ebookLinks = EbookLinkStore(library: appState.libraryCache, repository: bookStore, books: bookStore)
    lazy var annotationSync = AnnotationSyncService(defaults: defaults, providerResolver: providerConnections, readerArtifacts: readerArtifacts)
    private var didCreateProgress = false
    lazy var progress: UserProgressStore = {
        didCreateProgress = true
        return UserProgressStore(
        library: appState.libraryCache, session: appState, bookStore: bookStore,
        providerConnections: providerConnections,
        progressFileURL: storage.documentsDirectory.appendingPathComponent("enve_user_progress.json"),
        progressCache: bookProgress, defaults: defaults, pendingSync: pendingSync,
        smartCollections: smartCollections, annotationSync: annotationSync,
        syncCoordinator: { [unowned self] in sync },
        playbackState: { [unowned self] in playback.composition.controller }
    )
    }()
    private var didCreateCatalog = false
    lazy var catalog: LibraryCatalogCoordinator = {
        didCreateCatalog = true
        return LibraryCatalogCoordinator(
        library: appState.libraryCache, session: appState, presentation: appState.presentation,
        bookStore: bookStore, providerConnections: providerConnections, progress: progress,
        mirrorCheckpoints: mirrorCheckpoints,
        metadataFileURL: storage.documentsDirectory.appendingPathComponent("enve_metadata.json"), profileSession: self
    )
    }()
    private var didCreateRecovery = false
    lazy var recovery: LibraryRecoveryCoordinator = {
        didCreateRecovery = true
        return LibraryRecoveryCoordinator(
        library: appState.libraryCache, session: appState, presentation: appState.presentation,
        startup: appState, catalog: catalog, progress: progress, bookStore: bookStore,
        providerConnections: providerConnections, stores: .live(profileSession: self),
        defaults: defaults, profileSession: self
    )
    }()
    private var didCreateSync = false
    lazy var sync: SyncCoordinator = {
        didCreateSync = true
        return SyncCoordinator(
        providerResolver: providerConnections,
        pendingSyncFlusher: PendingSyncQueueFlusher(
            store: pendingSync,
            transport: ProviderPendingSyncTransport(providerResolver: providerConnections,
                bookLookup: { [bookStore] in await bookStore.book(stableId: $0) },
                serverSyncEnabled: { [unowned self] in !isRetired && serverSyncEnabled })
        ),
        recentlyPlayedSync: RecentlyPlayedSyncService(
            playbackState: playback.composition.controller, providerConnections: providerConnections,
            bookQuerying: bookStore, bookWriting: bookStore, progressRepository: bookStore,
            progressAPI: AudiobookshelfRecentlyPlayedProgressAPI(service: absService),
            progressCache: bookProgress, libraryCache: appState, ebookLinks: ebookLinks, strategyRegistry: registry
        ), profileSession: self
    )
    }()

    init(profile: FamilyProfile, storage suppliedStorage: ProfileStorageLocations? = nil, defaults suppliedDefaults: UserDefaults? = nil) throws {
        self.profile = profile
        allowsSystemIntegrations = suppliedStorage == nil
        let storage = suppliedStorage ?? ProfileStorageLocations(profileID: profile.id)
        precondition(storage.profileID == profile.id)
        self.storage = storage
        let defaults = try suppliedDefaults ?? storage.openPreferences()
        self.defaults = defaults
        libraryDatabase = profile.id == FamilyProfile.ownerID && suppliedStorage == nil ? .shared : try BookStoreManager(storage: storage, defaults: defaults)
        playbackQueue = try PlaybackQueueStore(storage: storage)
        playbackState = try PlaybackStateManager(storage: storage)
        let keychain = SharedKeychainStore(profileID: profile.id)
        self.keychain = keychain
        let legacyKeychain = KeychainHelper(profileID: profile.id)
        self.legacyKeychain = legacyKeychain
        tokenStorage = SecureTokenStorage(profileID: profile.id)
        let mtls = MTLSManager(keychain: legacyKeychain)
        self.mtls = mtls
        let serverConfig = ServerConfigStore(profileID: profile.id, defaults: defaults, keychain: legacyKeychain)
        self.serverConfig = serverConfig
        sessionManager = SessionManager(defaults: defaults, startAutomatically: false)
        plexAuth = PlexAuthStore(defaults: defaults, keychain: legacyKeychain)
        oauth = OAuthManager(session: URLSession(configuration: .ephemeral), ephemeralBrowser: true)
        rejectedContent = RejectedContentStore(defaults: defaults)
        let authenticationFailures = AuthenticationFailureStore(defaults: defaults)
        self.authenticationFailures = authenticationFailures
        let pendingSync = PendingSyncQueueStore(defaults: defaults)
        self.pendingSync = pendingSync
        let registry = profile.id == FamilyProfile.ownerID && suppliedStorage == nil ? PluginRegistry.shared : PluginRegistry()
        self.registry = registry
        providerConnections = ProviderConnectionStore(
            profileID: profile.id, defaults: defaults, keychain: keychain, serverConfig: serverConfig,
            authenticationFailures: authenticationFailures, pendingSync: pendingSync,
            providerFactory: { registry.makeLibraryProvider(for: $0) }
        )
        let appState = AppState(bookStore: libraryDatabase.repository, providerConnections: providerConnections)
        self.appState = appState
        let activity = ProfileDownloadActivity()
        downloadActivity = activity
        localStorage = try LocalStorageManager(storage: storage, isDownloadActive: { activity.isActive($0) })
        ebooks = try LocalEbookImporter(storage: storage)
        localLibrary = LocalLibraryStorageStore(defaults: defaults, storage: storage)
        groupingOverrides = AudiobookGroupingOverrideStore(defaults: defaults)
        localLibraryService = LocalLibraryService(storage: storage, localLibrary: localLibrary, ebooks: ebooks, groupingOverrides: groupingOverrides)
        preferences = LibraryDisplayPreferencesStore(defaults: defaults)
        playerState = PlayerStateStore(defaults: defaults)
        storageService = StorageService(defaults: defaults, preferencesDomain: storage.preferencesDomain ?? Bundle.main.bundleIdentifier!)
        playbackSpeed = PlaybackSpeedMemory(defaults: defaults)
        readerArtifacts = ReaderArtifactsStore(defaults: defaults)
        bookProgress = BookProgressStore(defaults: defaults)
        userCollections = UserCollectionStore(defaults: defaults)
        smartCollections = SmartCollectionStore(defaults: defaults)
        savedBooks = SavedBooksStore(defaults: defaults)
        dismissedShelves = HearthDismissedShelfStore(defaults: defaults)
        lastOpened = LastOpenedBookStore(defaults: defaults)
        workOverrides = WorkOverrideStore(defaults: defaults)
        seriesAliases = SeriesAliasStore(defaults: defaults)
        podcastSubscriptions = PodcastSubscriptionStore(defaults: defaults)
        deletedBooks = DeletedBooksTombstoneStore(defaults: defaults)
        catalogCheckpoints = CatalogImportCheckpointStore(storage: storage)
        catalogMapping = CatalogMappingRevisionStore(defaults: defaults)
        remoteLibraryBrowse = RemoteLibraryBrowseStore(defaults: defaults)
        siloReaderArtifacts = SiloReaderArtifactIDStore(defaults: defaults)
        mirrorCheckpoints = ServerMirrorCheckpointStore(defaults: defaults)
        opdsProgressionEndpoints = OPDSProgressionEndpointStore(defaults: defaults)
        opdsAuthentication = OPDSAuthenticationStore(defaults: defaults, tokens: KeychainOPDSTokenStore(storage: tokenStorage))
        metadataStorage = try MetadataStorage(storage: storage)
        metadataManager = MetadataManager(storage: metadataStorage)
        appCache = AppCache(storage: storage, defaults: defaults)
        imageCache = DiskImageCache(cacheDirectory: storage.cachesDirectory.appendingPathComponent("BookCovers"))
        matchQueue = MatchQueueStorage(defaults: defaults)
        narratedPositions = NarratedAudioPositionStore(defaults: defaults)
        rewindTracker = RemoteRewindTracker()
        ebookConflicts = EbookConflictStore()
        historyStore = try HistorySessionStore(directory: storage.historyDirectory)
        listeningStore = ABSLocalListeningStore(defaults: defaults)
        crossProviderHistory = CrossProviderHistorySessionSync(defaults: defaults, bookQuerying: appState.bookStore, providerResolver: providerConnections, historyStore: historyStore, listeningStore: listeningStore, serverSyncEnabled: { ProfileServerSyncPreferences(defaults: defaults, isOwner: profile.id == FamilyProfile.ownerID).isEnabled }, historyUploadAllowed: { ProfileServerSyncPreferences(defaults: defaults, isOwner: profile.id == FamilyProfile.ownerID).allowsHistoryUpload(startedAt: $0.startTime) })
        historySync = ProviderHistorySessionSync(defaults: defaults, bookQuerying: appState.bookStore, providerResolver: providerConnections, historyStore: historyStore, crossProviderSync: crossProviderHistory, serverSyncEnabled: { ProfileServerSyncPreferences(defaults: defaults, isOwner: profile.id == FamilyProfile.ownerID).isEnabled }, historyUploadAllowed: { ProfileServerSyncPreferences(defaults: defaults, isOwner: profile.id == FamilyProfile.ownerID).allowsHistoryUpload(startedAt: $0.startTime) })
        listeningStats = try ListeningStatsTracker(storage: storage, historyStore: historyStore, historySync: historySync)
        readingStats = try ReadingStatsTracker(storage: storage, historyStore: historyStore, historySync: historySync)
        let connections = providerConnections
        let clientCertificate: @Sendable (String) async -> URLCredential? = { host in
            await MainActor.run {
                guard let connection = connections.connections.first(where: { URL(string: $0.url)?.host == host }),
                    let identity = mtls.identity(for: connection.id)
                else { return nil }
                return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
            }
        }
        transport = InsecureURLSession(clientCertificate: clientCertificate)
        let manager = BookDownloadManager(storage: localStorage, activity: activity, clientCertificate: clientCertificate)
        downloads = try UnifiedDownloadService(
            storage: storage, defaults: defaults, storageManager: localStorage, ebookImporter: ebooks,
            localLibrary: localLibrary, preferences: preferences, readerArtifacts: readerArtifacts,
            downloadManager: manager, providerConnections: connections, presentation: appState.presentation,
            bookQuerying: appState.bookStore, bookWriting: appState.bookStore, libraryCache: appState,
            clientCertificate: clientCertificate
        )
        appState.bind(to: self)
        configureProviderFactories()
        providerConnections.syncProviders()
    }

    func start() {
        precondition(!isRetired)
        guard !hasStarted else { return }
        hasStarted = true
        playback.autoSleep.start()
        downloads.start()
        configureSyncPlugins()
        appState.start()
        sessionManager.start()
        sync.startAppIntegration()
    }

    func retire() async {
        if let retirementTask {
            await retirementTask.value
            return
        }
        guard !isRetired else { return }
        isRetired = true
        if hasSystemAccessAuthority { revokeSystemAccess() }
        let task = Task { await performRetirement() }
        retirementTask = task
        await task.value
        retirementTask = nil
    }

    private func performRetirement() async {
        #if os(iOS)
        if didCreateWidgetBridge { await widgetBridge.retire() }
        if didCreateWatchBridge { await watchBridge.retire() }
        #endif
        #if os(iOS)
        if #available(iOS 26.0, *), let service = storyAlignServiceStorage as? StoryAlignService { await service.retire() }
        #endif
        await autoSaver.retire()
        if didCreateCloudProgress { await cloudProgress.retire() }
        if didCreateKoreaderSink { koreaderSink.retire() }
        sessionManager.retire()
        oauth.retire()
        if didCreateOPDSBulkImport { await opdsBulkImport.retire() }
        if didCreateOPDSLogin { await opdsLogin.retire() }
        #if os(iOS)
        if didCreateFileSharing { await fileSharing.retire() }
        #endif
        if didCreateEngine { await engine.retire() }
        if didCreateRemoteImport { remoteImport.retire() }
        if didCreateNetworkSession { networkSession.invalidateAndCancel() }
        await downloads.retire()
        await providerConnections.retire()
        await appState.retire()
        if didCreatePlayback { await playback.retire() }
        if didCreateSync { await sync.retire() }
        if didCreateProgress { await progress.retire() }
        if didCreateRecovery { await recovery.retire() }
        if didCreateCatalog { await catalog.retire() }
        for task in Array(artworkOperations.values) { await task.value }
        await listeningStats.flush()
        await readingStats.flush()
        await appState.libraryCache.retire()
        registry.retire()
    }

    func activateSystemAccess() {
        guard allowsSystemIntegrations else { return }
        hasSystemAccessAuthority = true
        #if os(iOS)
        guard isOwner, !isRetired else { revokeSystemAccess(); return }
        allowsSystemAccess = true
        widgetBridge.start()
        watchBridge.start()
        NotificationCenter.default.post(name: .profileSystemAccessChanged, object: self)
        #endif
    }

    func revokeSystemAccess() {
        allowsSystemAccess = false
        guard allowsSystemIntegrations else { return }
        #if os(iOS)
        if didCreateWidgetBridge { widgetBridge.revoke() } else { BookWidgetBridge.clearSharedSnapshot() }
        if didCreateWatchBridge { watchBridge.revoke() } else { WatchSessionBridge.clearSharedSnapshot() }
        NotificationCenter.default.post(name: .profileSystemAccessChanged, object: nil)
        #endif
    }

    func removeCachedArtwork(for book: Book) {
        guard !isRetired else { return }
        let id = UUID()
        artworkOperations[id] = Task {
            await appCache.removeCoverData(for: book)
            artworkOperations[id] = nil
        }
    }

    func clearCredentials() throws {
        precondition(!isOwner && isRetired)
        try keychain.clearProfileCredentials()
        try legacyKeychain.removeAll()
        try tokenStorage.clearAll()
    }
}

extension Notification.Name {
    static let profileSystemAccessChanged = Notification.Name("profileSystemAccessChanged")
}
