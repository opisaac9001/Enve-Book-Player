import Foundation
import Darwin
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

    @Test func obsoletePlaybackFilesDoNotBlockProfilesOrActivePersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let legacyDirectory = fixture.root.appendingPathComponent("ApplicationSupport")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFiles = ["default.store", "default.store-wal", "default.store-shm"]
            .map { legacyDirectory.appendingPathComponent($0) }
        let preserved = Data("obsolete playback fixture".utf8)
        for file in legacyFiles { try preserved.write(to: file) }
        let profile = FamilyProfile(id: FamilyProfile.ownerID, name: "Owner", role: .adult)
        let session = try fixture.session(profile)
        let book = Book(id: "fixture", title: "Saved book", backendId: "local", source: .local)
        await session.bookStore.upsertBooks([book])
        await session.bookStore.updateProgress(uniqueId: book.uniqueId, currentTime: 123, isFinished: false, lastUpdate: Date())
        session.bookProgress.saveProgress(for: book, progress: 123, duration: 600)
        let bookmark = Bookmark(bookId: book.stableId, position: 90, title: "Saved passage", note: "Keep this", mediaType: .audiobook)
        session.readerArtifacts.saveBookmarks(bookId: book.stableId, bookmarks: [bookmark])
        try await session.metadataStorage.saveMetadata(BookMetadata(bookId: book.stableId, file: FileMetadataLayer(title: book.title)))
        try await session.metadataStorage.updateUserOverrides(bookId: book.stableId, overrides: UserOverridesLayer(customTitle: "Custom title"))
        session.playbackQueue.addLast(book)
        await session.retire()
        let reopened = try fixture.session(profile)
        #expect(await reopened.bookStore.book(uniqueId: book.uniqueId)?.currentTime == 123)
        #expect(reopened.bookProgress.loadProgress(for: book)?.progress == 123)
        #expect(reopened.readerArtifacts.loadBookmarks(bookId: book.stableId).first?.id == bookmark.id)
        #expect(reopened.readerArtifacts.loadBookmarks(bookId: book.stableId).first?.note == "Keep this")
        #expect(try await reopened.metadataStorage.loadMetadata(bookId: book.stableId)?.userOverrides?.customTitle == "Custom title")
        #expect(reopened.playbackQueue.entries.map(\.book.id) == [book.id])
        for file in legacyFiles { #expect(try Data(contentsOf: file) == preserved) }
        await reopened.retire()
    }

    @Test(.enabled(if: ProfileSwitchCoordinator.supportsMultipleProfileStorage))
    func capturedGraphKeepsLibraryProgressAndArtworkIndependentAfterReopen() async throws {
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

    @Test(.enabled(if: ProfileSwitchCoordinator.supportsMultipleProfileStorage))
    func coordinatorRequiresParentPINAndJoinsRetirementBeforePublishingDestination() async throws {
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
            defaults: coordinatorDefaults, initialSession: initial, sessionFactory: { try fixture.session($0, libraryDatabase: $1) })
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

    @Test(.enabled(if: ProfileSwitchCoordinator.supportsMultipleProfileStorage), .timeLimit(.minutes(1)))
    func parentAuthorizationCannotUnlockRetiringSessionWhileReturningToOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try FamilyProfileStore(fileURL: fixture.root.appendingPathComponent("catalog.json"), pinStore: fixture.pin)
        try fixture.pin.configure("291746")
        let other = try catalog.addAdult(name: "Other adult")
        _ = try catalog.addChild(name: "Child")
        let initial = try fixture.session(other)
        let provider = HeldCatalogProvider(connection: ServerConnection(name: "Held retirement", url: "https://held.invalid", type: .opds))
        provider.holdsRetirement = true
        initial.providerConnections[provider.connection.id] = provider
        let defaults = try fixture.defaults("coordinator")
        defaults.set(true, forKey: "familyProfiles.enabled")
        let coordinator = try ProfileSwitchCoordinator(catalog: catalog, pinStore: fixture.pin,
            defaults: defaults, initialSession: initial, sessionFactory: { try fixture.session($0, libraryDatabase: $1) })
        #expect(coordinator.isLocked)
        try coordinator.authorizeParent(pin: "291746")
        #expect(!coordinator.isLocked)

        // Releases a retirement the test never reaches, so a failure cannot hang the suite.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            provider.isReleased = true
        }
        let returning = Task { try await coordinator.switchProfile(id: FamilyProfile.ownerID) }
        while !provider.isRetiring && !provider.isReleased {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.isRetiring && !provider.isReleased, "Retirement never reached the held provider")
        #expect(coordinator.isSwitching)
        #expect(coordinator.activeSession === initial)
        #expect(initial.isRetired)
        coordinator.onBackground()
        #expect(coordinator.isLocked)
        do {
            try coordinator.authorizeParent(pin: "291746")
            Issue.record("Parent authorization unlocked a retiring session")
        } catch ProfileAccessError.operationInProgress { }
        #expect(coordinator.isLocked)
        #expect(!coordinator.isParentAuthorized)
        #expect(coordinator.activeSession === initial)

        provider.isReleased = true
        watchdog.cancel()
        await watchdog.value
        do {
            try await returning.value
            Issue.record("Owner opened after its authorization was revoked mid-switch")
        } catch ProfileAccessError.parentAuthorizationRequired { }
        #expect(coordinator.activeProfile.id == FamilyProfile.ownerID)
        #expect(coordinator.isLocked)
        #expect(!coordinator.isSwitching)
        try coordinator.authorizeParent(pin: "291746")
        let owner = coordinator.activeSession
        #expect(!coordinator.isLocked)
        #expect(!owner.isRetired)
        owner.start()

        try await coordinator.switchProfile(id: other.id)
        #expect(owner.isRetired)
        try coordinator.authorizeParent(pin: "291746")
        try await coordinator.switchProfile(id: FamilyProfile.ownerID)
        #expect(coordinator.activeProfile.id == FamilyProfile.ownerID)
        #expect(!coordinator.isLocked)
        #expect(!coordinator.activeSession.isRetired)
        await coordinator.activeSession.retire()
    }

    @Test(.enabled(if: ProfileSwitchCoordinator.supportsMultipleProfileStorage))
    func coordinatorReusesDatabasesAndReleasesRemovedProfiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try FamilyProfileStore(fileURL: fixture.root.appendingPathComponent("catalog.json"), pinStore: fixture.pin)
        let other = try catalog.addAdult(name: "Other")
        let initial = try fixture.session(catalog.profiles[0])
        let defaults = try fixture.defaults("coordinator")
        defaults.set(true, forKey: "familyProfiles.enabled")
        let coordinator = try ProfileSwitchCoordinator(catalog: catalog, pinStore: fixture.pin,
            defaults: defaults, initialSession: initial,
            sessionFactory: { try fixture.session($0, libraryDatabase: $1) })
        try await coordinator.switchProfile(id: other.id)
        weak let retiredSession = coordinator.activeSession
        weak let otherDatabase = coordinator.activeSession.libraryDatabase
        #expect(otherDatabase !== initial.libraryDatabase)
        try await coordinator.switchProfile(id: FamilyProfile.ownerID)
        await Task.yield()
        #expect(retiredSession == nil)
        #expect(coordinator.activeSession !== initial)
        #expect(coordinator.activeSession.libraryDatabase === initial.libraryDatabase)
        try await coordinator.switchProfile(id: other.id)
        #expect(coordinator.activeSession.libraryDatabase === otherDatabase)
        try await coordinator.switchProfile(id: FamilyProfile.ownerID)
        try await coordinator.removeProfile(id: other.id)
        await Task.yield()
        #expect(otherDatabase == nil)
        #expect(!coordinator.profiles.contains { $0.id == other.id })
        #expect(coordinator.activeSession.libraryDatabase === initial.libraryDatabase)
        await coordinator.activeSession.retire()
    }

    @Test func unsupportedSystemRejectsSetupBeforeChangingOwnerDataOrPIN() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogURL = fixture.root.appendingPathComponent("catalog.json")
        let catalog = try FamilyProfileStore(fileURL: catalogURL, pinStore: fixture.pin)
        try catalog.rename(profileID: FamilyProfile.ownerID, name: "Owner")
        let savedCatalog = try Data(contentsOf: catalogURL)
        let owner = try fixture.session(catalog.profiles[0])
        let defaults = try fixture.defaults("coordinator")
        defaults.set(FamilyProfile.ownerID, forKey: "familyProfiles.selected")
        var createdSessions = 0
        let coordinator = try ProfileSwitchCoordinator(catalog: catalog, pinStore: fixture.pin,
            defaults: defaults, initialSession: owner, supportsMultipleProfiles: false,
            sessionFactory: { profile, database in
                createdSessions += 1
                return try fixture.session(profile, libraryDatabase: database)
            })
        do {
            try coordinator.enable(ownerName: "Changed", pin: "291746")
            Issue.record("Profiles were enabled on an unsupported system")
        } catch ProfileAccessError.systemUpdateRequired { }
        do {
            _ = try coordinator.addProfile(name: "Other", role: .adult)
            Issue.record("A profile was added on an unsupported system")
        } catch ProfileAccessError.systemUpdateRequired { }
        #expect(!coordinator.isEnabled)
        #expect(!coordinator.isLocked)
        #expect(!coordinator.hasPIN)
        #expect(try !fixture.pin.isConfigured())
        #expect(defaults.string(forKey: "familyProfiles.selected") == FamilyProfile.ownerID)
        #expect(!defaults.bool(forKey: "familyProfiles.enabled"))
        #expect(try Data(contentsOf: catalogURL) == savedCatalog)
        #expect(createdSessions == 0)
        let book = Book(id: "owner", title: "Owner remains available", backendId: "local", source: .local)
        await owner.bookStore.upsertBooks([book])
        #expect(await owner.bookStore.book(stableId: book.stableId)?.title == book.title)
        await owner.retire()
    }

    @Test func unsupportedSystemKeepsSavedChildSelectionAndRequiresPINForOwner() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalogURL = fixture.root.appendingPathComponent("catalog.json")
        let catalog = try FamilyProfileStore(fileURL: catalogURL, pinStore: fixture.pin)
        try fixture.pin.configure("291746")
        let child = try catalog.addChild(name: "Child")
        let savedCatalog = try Data(contentsOf: catalogURL)
        let owner = try fixture.session(catalog.profiles[0])
        let defaults = try fixture.defaults("coordinator")
        defaults.set(true, forKey: "familyProfiles.enabled")
        defaults.set(child.id, forKey: "familyProfiles.selected")
        var createdSessions = 0
        let coordinator = try ProfileSwitchCoordinator(catalog: catalog, pinStore: fixture.pin,
            defaults: defaults, initialSession: owner, supportsMultipleProfiles: false,
            sessionFactory: { profile, database in
                createdSessions += 1
                return try fixture.session(profile, libraryDatabase: database)
            })
        #expect(coordinator.isLocked)
        #expect(coordinator.hasPIN)
        do {
            try await coordinator.switchProfile(id: FamilyProfile.ownerID)
            Issue.record("Owner opened without the saved child profile's PIN gate")
        } catch ProfileAccessError.parentAuthorizationRequired { }
        #expect(coordinator.isLocked)
        try coordinator.authorizeParent(pin: "291746")
        try await coordinator.switchProfile(id: FamilyProfile.ownerID)
        #expect(!coordinator.isLocked)
        #expect(coordinator.activeSession === owner)
        do {
            try await coordinator.switchProfile(id: child.id)
            Issue.record("Child storage opened on an unsupported system")
        } catch ProfileAccessError.systemUpdateRequired { }
        do {
            _ = try await coordinator.importCandidates(from: child.id)
            Issue.record("Inactive profile storage opened for import")
        } catch ProfileAccessError.systemUpdateRequired { }
        do {
            try await coordinator.removeProfile(id: child.id)
            Issue.record("Saved profile data was removed on an unsupported system")
        } catch ProfileAccessError.systemUpdateRequired { }
        #expect(createdSessions == 0)
        #expect(!owner.isRetired)
        #expect(coordinator.activeSession === owner)
        #expect(defaults.string(forKey: "familyProfiles.selected") == child.id)
        #expect(defaults.bool(forKey: "familyProfiles.enabled"))
        #expect(try Data(contentsOf: catalogURL) == savedCatalog)
        try fixture.pin.verify("291746")
        await owner.retire()
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

    @Test(.timeLimit(.minutes(1)))
    func retirementCancelsStartupCatalogWorkBeforeJoiningAppState() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = FamilyProfile(id: UUID().uuidString, name: "Child", role: .child)
        var session: ProfileSession? = try fixture.session(profile)
        weak let retiredSession = session
        let connection = ServerConnection(name: "Held catalog", url: "https://held.invalid", type: .opds)
        let encoder = JSONEncoder()
        encoder.userInfo[ServerConnection.keychainUserInfoKey] = session?.keychain
        session?.defaults.set(try encoder.encode([connection]), forKey: "enve_server_connections")
        session?.providerConnections.refresh()
        let provider = HeldCatalogProvider(connection: connection)
        session?.providerConnections[connection.id] = provider
        session?.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while provider.fetchCount == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(provider.fetchCount == 1, "Startup never requested the uncached catalog")
        let book = Book(id: "pending-write", title: "Saved before switching", backendId: "local", source: .local)
        session?.appState.libraryCache.persist([book])
        // Releases the fetch if retirement waits on startup work instead of cancelling it.
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            provider.isReleased = true
        }
        await session?.retire()
        watchdog.cancel()
        await watchdog.value
        #expect(provider.outcome == .cancelled)
        #expect(!provider.isFetching)
        session = nil
        await Task.yield()
        #expect(retiredSession == nil)
        let reopened = try fixture.session(profile)
        #expect(await reopened.bookStore.book(stableId: book.stableId)?.title == book.title)
        let other = try fixture.session(FamilyProfile(id: UUID().uuidString, name: "Other", role: .child))
        #expect(await other.bookStore.book(stableId: book.stableId) == nil)
        #expect(other.providerConnections.connections.isEmpty)
        await reopened.retire()
        await other.retire()
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

    @Test(.enabled(if: ProfileSwitchCoordinator.supportsMultipleProfileStorage && ProcessInfo.processInfo.environment["ENVE_PROFILE_SOAK"] == "1"))
    func repeatedSwitchesPreserveProfileBooksWithoutGrowingOpenFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let catalog = try FamilyProfileStore(fileURL: fixture.root.appendingPathComponent("catalog.json"), pinStore: fixture.pin)
        let other = try catalog.addAdult(name: "Other")
        let initial = try fixture.session(catalog.profiles[0])
        let defaults = try fixture.defaults("coordinator")
        defaults.set(true, forKey: "familyProfiles.enabled")
        let coordinator = try ProfileSwitchCoordinator(catalog: catalog, pinStore: fixture.pin,
            defaults: defaults, initialSession: initial, sessionFactory: { try fixture.session($0, libraryDatabase: $1) })
        let book = Book(id: "switch-fixture", title: "Owner", backendId: "fixture", source: .smb)
        await initial.bookStore.upsertBooks([book])
        try await coordinator.switchProfile(id: other.id)
        var otherBook = book
        otherBook.title = "Other"
        await coordinator.activeSession.bookStore.upsertBooks([otherBook])
        try await coordinator.switchProfile(id: FamilyProfile.ownerID)

        func openFileCount() -> Int {
            (0..<getdtablesize()).count { fcntl($0, F_GETFD) != -1 }
        }
        let baseline = openFileCount()
        for iteration in 1...100 {
            try await coordinator.switchProfile(id: other.id)
            #expect(await coordinator.activeSession.bookStore.book(uniqueId: book.uniqueId)?.title == "Other")
            await coordinator.activeSession.bookStore.updateProgress(uniqueId: book.uniqueId, currentTime: Double(iteration), isFinished: false, lastUpdate: Date())
            try await coordinator.switchProfile(id: FamilyProfile.ownerID)
            #expect(await coordinator.activeSession.bookStore.book(uniqueId: book.uniqueId)?.title == "Owner")
            #expect(await coordinator.activeSession.bookStore.book(uniqueId: book.uniqueId)?.currentTime == 0)
        }
        let afterSwitching = openFileCount()
        #expect(afterSwitching <= baseline + 8)
        try await coordinator.switchProfile(id: other.id)
        #expect(await coordinator.activeSession.bookStore.book(uniqueId: book.uniqueId)?.currentTime == 100)
        await coordinator.activeSession.retire()
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

    @MainActor
    private final class HeldCatalogProvider: @MainActor LibraryProvider {
        enum Outcome { case cancelled, released }
        var connection: ServerConnection
        var capabilities: ProviderCapabilities = []
        var isReleased = false
        var holdsRetirement = false
        private(set) var fetchCount = 0
        private(set) var isFetching = false
        private(set) var isRetiring = false
        private(set) var outcome: Outcome?

        init(connection: ServerConnection) {
            self.connection = connection
        }

        func retire() async {
            isRetiring = true
            while holdsRetirement && !isReleased {
                guard (try? await Task.sleep(for: .milliseconds(10))) != nil else { return }
            }
        }

        func fetchLibraries() async throws -> [Library] {
            fetchCount += 1
            isFetching = true
            defer { isFetching = false }
            while !isReleased {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                } catch {
                    outcome = .cancelled
                    throw error
                }
            }
            outcome = .released
            return []
        }

        func validateConnection() async throws -> Bool { true }
        func fetchBooks(libraryId: String) async throws -> [Book] { [] }
        func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] { [] }
        func fetchCollections(libraryId: String?) async throws -> [Collection] { [] }
        func fetchSeries(libraryId: String) async throws -> [Series] { [] }
        func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { [] }
        func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
            throw ProviderError.notImplemented
        }
        func getAudioURL(for book: Book) -> URL? { nil }
        func getStreamingHeaders() -> [String: String] { [:] }
        func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
            throw ProviderError.notImplemented
        }
        func updatePlaybackProgress(
            book: Book,
            sessionId: String?,
            currentTime: TimeInterval,
            isFinished: Bool,
            timeListened: TimeInterval
        ) async throws {}
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

        func session(_ profile: FamilyProfile, libraryDatabase: BookStoreManager? = nil) throws -> ProfileSession {
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            return try ProfileSession(profile: profile, storage: storage, defaults: defaults(profile.id), libraryDatabase: libraryDatabase)
        }

        func remove() {
            for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: pinService] as CFDictionary)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
