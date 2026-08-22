import Logging
import SwiftUI

@main
struct EnveTVApp: App {
    @State private var appState = AppState.shared
    @StateObject private var themeManager = ThemeManager.shared

    @Environment(\.scenePhase) private var scenePhase
    @State private var hasHandledInitialActivePhase = false

    private let settingsManager = SettingsManager.shared

    private static func bootstrapPlugins(
        providerConnections: ProviderConnectionStore,
        bookStore: any BookStoreRepository
    ) {
        PluginRegistry.shared.register(sink: ProviderSyncSink(providerResolver: providerConnections))
        PluginRegistry.shared.register(sink: BookloreKoreaderSink.shared)
        PluginRegistry.shared.register(sink: CloudKitProgressSync.shared)

        let registry = PluginRegistry.shared
        registry.register(libraryProviderFactory: { AudiobookshelfProvider(connection: $0) }, for: .audiobookshelf)
        registry.register(libraryProviderFactory: { PlexProvider(connection: $0) }, for: .plex)
        registry.register(libraryProviderFactory: { JellyfinProvider(connection: $0) }, for: .jellyfin)
        registry.register(libraryProviderFactory: { EmbyProvider(connection: $0) }, for: .emby)
        registry.register(libraryProviderFactory: { WebDAVProvider(connection: $0) }, for: .webdav)
        registry.register(libraryProviderFactory: { WebDAVProvider(connection: $0) }, for: .premiumize)
        registry.register(libraryProviderFactory: { RealDebridProvider(connection: $0) }, for: .realdebrid)
        registry.register(libraryProviderFactory: { BookloreProvider(connection: $0) }, for: .booklore)
        registry.register(libraryProviderFactory: { KomgaProvider(connection: $0) }, for: .komga)
        registry.register(libraryProviderFactory: { KavitaProvider(connection: $0) }, for: .kavita)
        registry.register(libraryProviderFactory: { OPDSProvider(connection: $0) }, for: .opds)
        registry.register(libraryProviderFactory: { StorytellerProvider(connection: $0) }, for: .storyteller)

        registry.register(
            syncStrategy: StorytellerSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                catalogRepository: bookStore
            )
        )
        registry.register(
            syncStrategy: BookloreEbookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                progressRepository: bookStore
            )
        )
        registry.register(
            syncStrategy: BookloreAudiobookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore
            )
        )
    }

    private static func disableCoreDataDebugLogging() {
        let keys = [
            "com.apple.CoreData.SQLDebug",
            "com.apple.CoreData.Logging.stderr",
            "com.apple.CoreData.ConcurrencyDebug",
            "com.apple.CoreData.MigrationDebug",
            "com.apple.CoreData.CloudKitDebug",
            "com.apple.CoreData.Debug",
        ]
        for key in keys {
            unsetenv(key)
            setenv(key, "0", 1)
            UserDefaults.standard.set(0, forKey: key)
        }
    }

    init() {
        Self.disableCoreDataDebugLogging()
        StorageMigrationHelper.migrateIfNeeded()
        SyncMigrationManager.runIfNeeded()
        ReaderDataMigration.runIfNeeded()
        AppLogger.bootstrap()
        Self.bootstrapPlugins(
            providerConnections: AppState.shared.providerConnections,
            bookStore: AppState.shared.bookStore
        )
        Task { @MainActor in
            AppState.shared.providerConnections.syncProviders()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView_tvOS()
                .environment(appState)
                .environment(LibraryCatalogCoordinator.shared)
                .environmentObject(themeManager)
                .environment(PlayerViewModel.shared)
                .onAppear {
                    Task {
                        await ListeningStatsTracker.shared.startTracking()
                        await AppCache.shared.runMaintenance()
                        await ServerConnectionCloudKitSync.shared.bootstrap()

                        if !appState.providerConnections.connections.isEmpty {
                            await LibraryCatalogCoordinator.shared.refreshLibrary()
                        }
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        AppLogger.general.info("[tvOS scenePhase] → active (initial=\(!hasHandledInitialActivePhase))")
                        if hasHandledInitialActivePhase {
                            Task.detached(priority: .utility) {
                                await appState.providerConnections.refreshAudiobookshelfAuthentication()
                            }
                        } else {
                            hasHandledInitialActivePhase = true
                        }
                    } else if newPhase == .background {
                        AppLogger.general.info("[tvOS scenePhase] → background")
                        appState.persistStartupCachesImmediately()
                        Task {
                            await PlayerViewModel.shared.saveProgressOnBackground()
                            await ListeningStatsTracker.shared.endSession()
                            await ReadingStatsTracker.shared.endSession()
                        }
                    }
                }
        }
    }
}
