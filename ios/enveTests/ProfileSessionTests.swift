import Foundation
import Security
import Testing

@testable import enve

@MainActor
struct ProfileSessionTests {
    @Test func downloadDetectionRejectsOtherProfilesAndSiblingDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "First", role: .adult))
        let second = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Second", role: .child))
        let root = first.ebooks.serverEbooksRoot
        let sibling = URL(fileURLWithPath: root.path + "-other", isDirectory: true)
        for directory in [root, sibling] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([1]).write(to: directory.appendingPathComponent("fixture.epub"))
        }
        var book = Book(id: "download-fixture", title: "Downloaded", source: .booklore, mediaType: .ebook)
        book.ebookFileURL = sibling.appendingPathComponent("fixture.epub")
        #expect(!first.engine.downloads.hasPermanentEbookDownload(book))
        book.ebookFileURL = root.appendingPathComponent("fixture.epub")
        #expect(first.engine.downloads.isLibraryDownloaded(book))
        #expect(!second.engine.downloads.isLibraryDownloaded(book))
        await first.retire()
        await second.retire()
    }

    @Test func cloudSinkUsesItsInjectedAvailabilityAndSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Cloud test", role: .adult))
        let settings = CloudSinkSettings()
        let sink = CloudKitProgressSync(
            isSyncEnabled: { settings.enabled }, isSyncAvailable: { settings.available },
            userProgress: session.progress, bookProgress: session.bookProgress
        )
        let book = Book(id: "cloud-fixture", title: "Cloud", source: .local)
        #expect(sink.isApplicable(to: book, domain: .audiobook))
        settings.enabled = false
        #expect(!sink.isApplicable(to: book, domain: .audiobook))
        settings.enabled = true
        settings.available = false
        #expect(!sink.isApplicable(to: book, domain: .audiobook))
        await session.retire()
    }

    @Test func legacyReaderArtifactsMigrateOnlyWithinTheirProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "First", role: .adult))
        let second = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Second", role: .child))
        let book = Book(id: "shared-id", title: "Remote", mediaType: .ebook, backendId: "fixture", source: .booklore)
        #expect(book.stableId != book.id)
        let annotation = ReaderAnnotation(bookId: book.id, text: "Legacy")
        let bookmark = Bookmark(bookId: book.id, position: 0.2, title: "Legacy", mediaType: .ebook)
        for session in [first, second] {
            session.readerArtifacts.saveAnnotations(bookId: book.id, annotations: [annotation])
            session.readerArtifacts.saveBookmarks(bookId: book.id, bookmarks: [bookmark])
        }
        let adapter = ReaderArtifactsAdapter(book: book, store: second.readerArtifacts, profileSession: second)
        adapter.loadAnnotations()
        adapter.loadBookmarks()
        #expect(adapter.annotations.map(\.id) == [annotation.id])
        #expect(adapter.bookmarks.map(\.id) == [bookmark.id])
        #expect(second.readerArtifacts.loadAnnotations(bookId: book.id).isEmpty)
        #expect(second.readerArtifacts.loadBookmarks(bookId: book.id).isEmpty)
        #expect(first.readerArtifacts.loadAnnotations(bookId: book.id).count == 1)
        #expect(first.readerArtifacts.loadBookmarks(bookId: book.id).count == 1)
        await first.retire()
        await second.retire()
    }

    @Test func legacyServicesResolveToTheOwnerGraph() {
        #expect(EnveEngine.shared === ProfileSession.owner.engine)
        #expect(UnifiedDownloadService.shared === ProfileSession.owner.downloads)
        #expect(SyncCoordinator.shared === ProfileSession.owner.sync)
        #expect(CloudKitProgressSync.shared === ProfileSession.owner.cloudKit)
        #expect(UserProgressStore.shared === ProfileSession.owner.progress)
        #expect(PendingSyncQueueStore.shared === ProfileSession.owner.pendingSync)
        #expect(EbookConflictStore.shared === ProfileSession.owner.ebookConflicts)
        #expect(ServerMirrorCheckpointStore.shared === ProfileSession.owner.mirrorCheckpoints)
        #expect(LastOpenedBookStore.shared === ProfileSession.owner.lastOpened)
        #expect(ActivePlayback.controller === ProfileSession.owner.playback.composition.controller)
        #expect(PlaybackManager.shared === ProfileSession.owner.playback.manager)
        #expect(AudioProcessor.shared === ProfileSession.owner.playback.manager.audioProcessor)
    }

    private final class CloudSinkSettings {
        var enabled = true
        var available = true
    }

    @Test func capturedGraphKeepsLibraryProgressAndArtworkIndependentAfterReopen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstProfile = FamilyProfile(id: UUID().uuidString, name: "First", role: .adult)
        let secondProfile = FamilyProfile(id: UUID().uuidString, name: "Second", role: .child)
        let first = try fixture.session(firstProfile)
        let second = try fixture.session(secondProfile)
        let book = Book(id: "same-book", title: "First title", backendId: "local", source: .local)
        await first.bookStore.upsertBooks([book])
        first.bookProgress.saveProgress(for: book, progress: 23, duration: 100)
        first.libraryModel.selectLayout(.grid)
        await first.appCache.setCoverData(Data([1, 2]), for: book)
        #expect(await second.bookStore.book(stableId: book.stableId) == nil)
        #expect(second.bookProgress.loadProgress(for: book) == nil)
        #expect(await second.appCache.getCoverData(for: book) == nil)
        #expect(second.libraryModel.layout == .list)
        var secondBook = book
        secondBook.title = "Second title"
        await second.bookStore.upsertBooks([secondBook])
        second.bookProgress.saveProgress(for: book, progress: 71, duration: 100)
        await second.appCache.setCoverData(Data([3, 4]), for: book)
        async let firstRetirement: Void = first.retire()
        async let concurrentRetirement: Void = first.retire()
        _ = await (firstRetirement, concurrentRetirement)
        await first.retire()
        await second.retire()
        #expect(first.isRetired)
        #expect(second.isRetired)
        let reopenedFirst = try fixture.session(firstProfile)
        let reopenedSecond = try fixture.session(secondProfile)
        #expect(await reopenedFirst.bookStore.book(stableId: book.stableId)?.title == "First title")
        #expect(await reopenedSecond.bookStore.book(stableId: book.stableId)?.title == "Second title")
        #expect(reopenedFirst.bookProgress.loadProgress(for: book)?.progress == 23)
        #expect(reopenedSecond.bookProgress.loadProgress(for: book)?.progress == 71)
        #expect(reopenedFirst.libraryModel.layout == .grid)
        #expect(reopenedSecond.libraryModel.layout == .list)
        #expect(await reopenedFirst.appCache.getCoverData(for: book) == Data([1, 2]))
        #expect(await reopenedSecond.appCache.getCoverData(for: book) == Data([3, 4]))
        await reopenedFirst.retire()
        await reopenedSecond.retire()
    }

    @Test func capturedAdultAndChildHaveIndependentRegistriesAndConnectionCatalogs() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Adult", role: .adult))
        let child = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Child", role: .child))
        #expect(owner.registry !== PluginRegistry.shared)
        #expect(child.registry !== owner.registry)
        #expect(owner.providerConnections.connections.isEmpty)
        #expect(child.providerConnections.connections.isEmpty)
        let connection = ServerConnection(name: "Fixture", url: "https://example.invalid", type: .opds)
        let encoder = JSONEncoder()
        encoder.userInfo[ServerConnection.keychainUserInfoKey] = owner.keychain
        owner.defaults.set(try encoder.encode([connection]), forKey: "enve_server_connections")
        owner.providerConnections.refresh()
        #expect(owner.providerConnections.connections.map(\.id) == [connection.id])
        #expect(child.providerConnections.connections.isEmpty)
        owner.activateSystemAccess()
        #expect(!owner.allowsSystemAccess)
        await owner.retire()
        await child.retire()
    }

    @Test func coordinatorRequiresParentPINAndJoinsRetirementBeforePublishingDestination() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try FamilyProfileStore(fileURL: fixture.root.appendingPathComponent("catalog.json"), pinStore: fixture.pin)
        try fixture.pin.configure("291746")
        let adult = try catalog.addAdult(name: "Parent")
        let child = try catalog.addChild(name: "Child")
        let initial = try fixture.session(child)
        let coordinatorDefaults = try fixture.defaults("coordinator")
        coordinatorDefaults.set(true, forKey: "familyProfiles.enabled")
        let coordinator = try ProfileSwitchCoordinator(catalog: catalog, pinStore: fixture.pin,
            defaults: coordinatorDefaults, initialSession: initial, sessionFactory: { try fixture.session($0) })
        do {
            try coordinator.authorizeParent(pin: "111111")
            Issue.record("Wrong PIN was accepted")
        } catch { }
        #expect(!coordinator.isParentAuthorized)
        do {
            try await coordinator.switchProfile(id: adult.id)
            Issue.record("Adult profile opened without parent authorization")
        } catch ProfileAccessError.parentAuthorizationRequired { }
        #expect(coordinator.activeSession === initial)
        #expect(!initial.isRetired)
        try coordinator.authorizeParent(pin: "291746")
        try await coordinator.switchProfile(id: adult.id)
        #expect(initial.isRetired)
        #expect(coordinator.activeProfile.id == adult.id)
        #expect(!coordinator.isParentAuthorized)
        let adultSession = coordinator.activeSession
        adultSession.start()
        coordinator.onBackground()
        #expect(coordinator.isLocked)
        #expect(!adultSession.allowsSystemAccess)
        #expect(!coordinator.isParentAuthorized)
        try await coordinator.switchProfile(id: child.id)
        #expect(adultSession.isRetired)
        #expect(!coordinator.isLocked)
        #expect(coordinator.activeProfile.id == child.id)
        #expect(coordinator.activeSession.providerConnections.connections.isEmpty)
        if #available(iOS 26.0, *) {
            let alignment = coordinator.activeSession.engine.storyAlign
            #expect(!alignment.isAvailable)
            #expect(alignment.activeConversion == nil)
            #expect(alignment.pausedConversion == nil)
            #expect(throws: (any Error).self) { try alignment.cancelConversion() }
            var conversions = alignment.completedConversions().makeAsyncIterator()
            #expect(await conversions.next() == nil)
        }
        await coordinator.activeSession.retire()
    }

    @Test func retirementReleasesStartedGraphAndDrainsCapturedLibraryWrites() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = FamilyProfile(id: UUID().uuidString, name: "Child", role: .child)
        var session: ProfileSession? = try fixture.session(profile)
        weak let retiredSession = session
        let book = Book(id: "pending-write", title: "Saved before switching", backendId: "local", source: .local)
        session?.start()
        _ = session?.engine
        session?.appState.libraryCache.persist([book])
        await session?.retire()
        session = nil
        await Task.yield()
        #expect(retiredSession == nil)
        let reopened = try fixture.session(profile)
        #expect(await reopened.bookStore.book(stableId: book.stableId)?.title == book.title)
        await reopened.retire()
    }

    @Test func localLibraryScansOnlyCapturedEbookRoots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "First", role: .adult))
        let second = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Second", role: .child))
        let firstFile = first.ebooks.localEbooksRoot.appendingPathComponent("first.epub")
        try Data("first profile ebook".utf8).write(to: firstFile)
        let firstScan = try await first.localLibraryService.scanCanonicalLibrary()
        let secondScan = try await second.localLibraryService.scanCanonicalLibrary()
        #expect(firstScan.booksFound.map(\.filePath) == [firstFile.path])
        #expect(secondScan.booksFound.isEmpty)
        let secondFile = second.ebooks.localEbooksRoot.appendingPathComponent("second.epub")
        try Data("second profile ebook".utf8).write(to: secondFile)
        let populatedSecondScan = try await second.localLibraryService.scanCanonicalLibrary()
        #expect(populatedSecondScan.booksFound.map(\.filePath) == [secondFile.path])
        #expect(try Data(contentsOf: firstFile) == Data("first profile ebook".utf8))
        await first.retire()
        await second.retire()
    }

    @Test func addedProfileRequiresOptInBeforePullingOrPushingPersonalProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Reader", role: .adult))
        let sink = CountingSyncSink()
        session.registry.register(sink: sink)
        let book = Book(id: "remote-book", title: "Remote", backendId: "fixture", source: .audiobookshelf)
        #expect(!session.serverSyncEnabled)
        await session.sync.pullOnOpen(book: book, domain: .audiobook)
        await session.sync.pushProgress(book: book, forceImmediate: true, domain: .audiobook)
        #expect(sink.pulls == 0)
        #expect(sink.pushes == 0)
        session.defaults.set(true, forKey: "profileServerSyncEnabled")
        await session.sync.pullOnOpen(book: book, domain: .audiobook)
        await session.sync.pushProgress(book: book, forceImmediate: true, domain: .audiobook)
        #expect(sink.pulls == 1)
        #expect(sink.pushes == 1)
        session.defaults.set(false, forKey: "profileServerSyncEnabled")
        await session.sync.pushFinished(book: book, domain: .audiobook)
        #expect(sink.pushes == 1)
        await session.retire()
    }

    private final class CountingSyncSink: SyncSink {
        let id = "profile-test"
        let displayName = "Profile test"
        var pulls = 0
        var pushes = 0
        func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool { true }
        func pull(book: Book, domain: ProgressSyncDomain) async throws -> SyncSnapshot? {
            pulls += 1
            return nil
        }
        func push(_ update: ProgressUpdate) async throws { pushes += 1 }
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = "ProfileSessionTests.\(UUID().uuidString)"
        let pinService = "ProfileSessionTests.PIN.\(UUID().uuidString)"
        lazy var pin = AdultPINStore(service: pinService)
        private var domains: [String] = []

        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

        func defaults(_ id: String) throws -> UserDefaults {
            let domain = "\(prefix).\(id)"
            if !domains.contains(domain) { domains.append(domain) }
            return try #require(UserDefaults(suiteName: domain))
        }

        func session(_ profile: FamilyProfile) throws -> ProfileSession {
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"),
                legacyPlaybackStoreURL: root.appendingPathComponent("Playback.store"))
            return try ProfileSession(profile: profile, storage: storage, defaults: defaults(profile.id))
        }

        func remove() {
            for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: pinService] as CFDictionary)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
