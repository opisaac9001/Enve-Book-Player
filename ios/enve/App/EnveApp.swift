import Logging
import SwiftUI

#if os(iOS)
import AppIntents
import BackgroundTasks
#endif

struct EnveApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CarPlayAppDelegate.self) var carPlayDelegate
    #endif

    @State private var appState = AppState.shared
    @StateObject private var themeManager = ThemeManager.shared
    @State private var hasHandledInitialActivePhase = false

    @Environment(\.scenePhase) private var scenePhase

    private static func bootstrapPlugins(
        providerConnections: ProviderConnectionStore,
        bookStore: any BookStoreRepository
    ) {
        PluginRegistry.shared.register(sink: ProviderSyncSink(providerResolver: providerConnections))
        PluginRegistry.shared.register(sink: BookloreKoreaderSink.shared)
        if PlatformRuntime.cloudKitEnabled {
            PluginRegistry.shared.register(sink: CloudKitProgressSync.shared)
        }

        let registry = PluginRegistry.shared
        registry.register(libraryProviderFactory: { AudiobookshelfProvider(connection: $0) }, for: .audiobookshelf)
        registry.register(libraryProviderFactory: { PlexProvider(connection: $0) }, for: .plex)
        registry.register(libraryProviderFactory: { JellyfinProvider(connection: $0) }, for: .jellyfin)
        registry.register(libraryProviderFactory: { EmbyProvider(connection: $0) }, for: .emby)
        registry.register(libraryProviderFactory: { WebDAVProvider(connection: $0) }, for: .webdav)
        registry.register(libraryProviderFactory: { WebDAVProvider(connection: $0) }, for: .torbox)

        registry.register(libraryProviderFactory: { WebDAVProvider(connection: $0) }, for: .premiumize)
        registry.register(libraryProviderFactory: { RealDebridProvider(connection: $0) }, for: .realdebrid)
        registry.register(libraryProviderFactory: { BookloreProvider(connection: $0) }, for: .booklore)
        registry.register(libraryProviderFactory: { KomgaProvider(connection: $0) }, for: .komga)
        registry.register(libraryProviderFactory: { KavitaProvider(connection: $0) }, for: .kavita)
        registry.register(libraryProviderFactory: { OPDSProvider(connection: $0) }, for: .opds)
        registry.register(libraryProviderFactory: { StorytellerProvider(connection: $0) }, for: .storyteller)
        registry.register(libraryProviderFactory: { BookOrbitProvider(connection: $0) }, for: .bookOrbit)
        registry.register(libraryProviderFactory: { SiloProvider(connection: $0) }, for: .silo)

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
        registry.register(
            syncStrategy: KomgaEbookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore
            )
        )
        registry.register(
            syncStrategy: BookOrbitSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore
            )
        )
        registry.register(
            syncStrategy: SiloActivitySyncStrategy(
                providerConnections: providerConnections,
                books: bookStore
            )
        )
        registry.register(
            syncStrategy: SiloEbookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                progressRepository: bookStore
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
        AppLogger.general.info("Enve source provenance: \(EnveProvenance.identifier)")

        Self.bootstrapPlugins(
            providerConnections: AppState.shared.providerConnections,
            bookStore: AppState.shared.bookStore
        )
        #if os(iOS)
        EnveAppShortcuts.updateAppShortcutParameters()
        #endif
        Task { @MainActor in
            AppState.shared.providerConnections.syncProviders()
        }

        #if os(iOS)

        WatchSessionBridge.shared.start()
        RuntimeDiagnosticsCollector.shared.start()
        #endif
        AutoSleepService.shared.start()

        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.enve.enve.storyalign", using: .main) { task in
                guard let task = task as? BGContinuedProcessingTask else { return }
                StoryAlignService.shared.handleContinuedProcessingTask(task)
            }
            StoryAlignService.shared.loadPausedConversion()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appState)
                .environment(EnveEngine.shared)
                .environmentObject(themeManager)
                .environment(PlayerViewModel.shared)
                .onAppear {
                    #if os(iOS)
                    BookWidgetBridge.shared.start()
                    #endif
                    Task {
                        await ListeningStatsTracker.shared.startTracking()
                        await AppCache.shared.runMaintenance()
                        if PlatformRuntime.cloudKitEnabled {
                            await ServerConnectionCloudKitSync.shared.bootstrap()
                        }
                    }

                    #if os(iOS)
                    FileSharingImportCoordinator.shared.startWatching()
                    FileSharingImportCoordinator.shared.scheduleRefresh(reason: "app-launch")
                    #endif
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        #if os(iOS)
                        FileSharingImportCoordinator.shared.startWatching()
                        #endif
                        if hasHandledInitialActivePhase {
                            #if os(iOS)
                            FileSharingImportCoordinator.shared.scheduleRefresh(reason: "scene-active")
                            #endif
                            Task.detached(priority: .utility) {
                                await appState.providerConnections.refreshAudiobookshelfAuthentication()
                                await appState.providerConnections.refreshBookloreAuthentication()
                            }
                        } else {
                            hasHandledInitialActivePhase = true
                        }
                    } else if newPhase == .background {
                        #if os(iOS)
                        FileSharingImportCoordinator.shared.stopWatching()
                        #endif
                        appState.persistStartupCachesImmediately()
                        Task {
                            await PlayerViewModel.shared.saveProgressOnBackground()
                            await ListeningStatsTracker.shared.endSession()
                            await ReadingStatsTracker.shared.endSession()
                        }
                    } else {
                        #if os(iOS)
                        FileSharingImportCoordinator.shared.stopWatching()
                        #endif
                    }
                }
        }
        .enveCatalystCommands()
    }
}

private extension Scene {
    @SceneBuilder
    func enveCatalystCommands() -> some Scene {
        #if targetEnvironment(macCatalyst)
        commands { EnveCatalystCommands() }
        #else
        self
        #endif
    }
}

#if targetEnvironment(macCatalyst)
private struct EnveCatalystCommands: Commands {
    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(HearthTab.allCases.enumerated()), id: \.element) { index, tab in
                Button(tab.title) {
                    NotificationCenter.default.post(
                        name: .enveCatalystSelectTab,
                        object: tab.rawValue
                    )
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .enveCatalystShowSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
#endif
