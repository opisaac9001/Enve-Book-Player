import Foundation

extension ProfileSession {
    func configureProviderFactories() {
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return AudiobookshelfProvider(connection: connection, profileSession: self)
        }, for: .audiobookshelf)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return PlexProvider(connection: connection, profileSession: self)
        }, for: .plex)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return JellyfinProvider(connection: connection, profileSession: self)
        }, for: .jellyfin)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return EmbyProvider(connection: connection, profileSession: self)
        }, for: .emby)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return WebDAVProvider(connection: connection, profileSession: self)
        }, for: .webdav)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return WebDAVProvider(connection: connection, profileSession: self)
        }, for: .torbox)

        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return WebDAVProvider(connection: connection, profileSession: self)
        }, for: .premiumize)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return RealDebridProvider(connection: connection, profileSession: self)
        }, for: .realdebrid)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return BookloreProvider(connection: connection, profileSession: self)
        }, for: .booklore)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return KomgaProvider(connection: connection, profileSession: self)
        }, for: .komga)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return KavitaProvider(connection: connection, profileSession: self)
        }, for: .kavita)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return OPDSProvider(connection: connection, profileSession: self)
        }, for: .opds)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return StorytellerProvider(connection: connection, profileSession: self)
        }, for: .storyteller)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return BookOrbitProvider(connection: connection, profileSession: self)
        }, for: .bookOrbit)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return SiloProvider(connection: connection, profileSession: self)
        }, for: .silo)
        registry.register(libraryProviderFactory: { [weak self] connection in
            guard let self else { return nil }
            return OneDriveProvider(connection: connection, profileSession: self)
        }, for: .oneDrive)

    }

    func configureSyncPlugins() {
        registry.register(sink: ProviderSyncSink(providerResolver: providerConnections))
        registry.register(sink: koreaderSink)
        if isOwner && PlatformRuntime.cloudKitEnabled {
            registry.register(sink: cloudKit)
        }

        let playbackState = playback.composition.controller
        // Sync and the progress/catalog owners are lazy; resolving them here would construct them during registration.
        let isEbookReaderOpen: @MainActor () -> Bool = { [unowned self] in sync.isEbookReaderOpen }
        let progressStore: @MainActor () -> UserProgressStore = { [unowned self] in progress }
        let catalogCoordinator: @MainActor () -> LibraryCatalogCoordinator = { [unowned self] in catalog }

        let nativeProgressSources: [(ProviderType, Book.BookSource)] = [
            (.jellyfin, .jellyfin), (.emby, .emby), (.plex, .plex), (.kavita, .kavita),
        ]
        for (type, source) in nativeProgressSources {
            registry.register(
                syncStrategy: NativeProgressSyncStrategy(
                    providerType: type, source: source,
                    connections: providerConnections, books: bookStore,
                    progressRepository: bookStore, libraryCache: appState,
                    progressCache: bookProgress, playbackState: playbackState,
                    pendingSyncs: pendingSync
                )
            )
        }

        registry.register(
            syncStrategy: StorytellerSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                catalogRepository: bookStore,
                playbackState: playbackState,
                pendingSync: pendingSync,
                mirrorCheckpoints: mirrorCheckpoints,
                lastOpened: lastOpened,
                storytellerPositions: playback.storytellerPositions,
                isEbookReaderOpen: isEbookReaderOpen,
                progress: progressStore,
                catalog: catalogCoordinator
            )
        )
        registry.register(
            syncStrategy: BookloreEbookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                progressRepository: bookStore,
                libraryCache: appState,
                playbackState: playbackState,
                bookProgress: bookProgress,
                pendingSync: pendingSync,
                conflicts: ebookConflicts,
                ebookLinks: ebookLinks
            )
        )
        registry.register(
            syncStrategy: BookloreAudiobookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                libraryCache: appState,
                playbackState: playbackState,
                bookProgress: bookProgress,
                pendingSync: pendingSync
            )
        )
        registry.register(
            syncStrategy: KomgaEbookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                libraryCache: appState,
                playbackState: playbackState,
                bookProgress: bookProgress,
                pendingSync: pendingSync
            )
        )
        registry.register(
            syncStrategy: BookOrbitSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                libraryCache: appState.libraryCache,
                playbackState: playbackState,
                pendingSync: pendingSync,
                mirrorCheckpoints: mirrorCheckpoints,
                lastOpened: lastOpened,
                historySync: historySync,
                readerArtifacts: bookOrbitArtifacts,
                isEbookReaderOpen: isEbookReaderOpen,
                progress: progressStore
            )
        )
        registry.register(
            syncStrategy: SiloActivitySyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                playbackState: playbackState,
                pendingSync: pendingSync,
                mirrorCheckpoints: mirrorCheckpoints,
                progress: progressStore
            )
        )
        registry.register(
            syncStrategy: SiloEbookSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                bookWriter: bookStore,
                progressRepository: bookStore,
                libraryCache: appState,
                playbackState: playbackState,
                pendingSync: pendingSync,
                conflicts: ebookConflicts,
                ebookLinks: ebookLinks
            )
        )
        registry.register(
            syncStrategy: OPDSProgressionSyncStrategy(
                providerConnections: providerConnections,
                books: bookStore,
                progressRepository: bookStore,
                libraryCache: appState,
                progressCache: bookProgress,
                playbackState: playbackState,
                reauthentication: providerConnections,
                pendingSyncs: pendingSync,
                conflicts: ebookConflicts,
                rewinds: rewindTracker
            )
        )
    }
}
