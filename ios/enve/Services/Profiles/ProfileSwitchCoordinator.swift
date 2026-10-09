import Foundation
#if canImport(WebKit)
import WebKit
#endif

enum ProfileAccessError: Error {
    case parentAuthorizationRequired
    case profileUnavailable
    case operationInProgress
    case removeOtherProfilesFirst
    case cannotRemoveActiveProfile
}

struct ProfileDownloadImportCandidate: Identifiable {
    let sourceProfileID: String
    let sourceBook: Book
    fileprivate let completedTask: BookDownloadTask
    fileprivate var linkedBook: Book? = nil
    fileprivate var linkedTask: BookDownloadTask? = nil
    var id: String { "\(sourceProfileID):\(sourceBook.uniqueId)" }
}

@MainActor
@Observable
final class ProfileSwitchCoordinator {
    static let shared = ProfileSwitchCoordinator()

    private var catalog: FamilyProfileStore?
    private let pinStore: AdultPINStore
    private let defaults: UserDefaults
    private let sessionFactory: (FamilyProfile) throws -> ProfileSession
    private var inactiveSessions: [String: ProfileSession] = [:]
    private var serverSyncOverrides: [String: Bool] = [:]
    private var authorizationTask: Task<Void, Never>?
    private var authorizationDeadline: ContinuousClock.Instant?
    private let enabledKey = "familyProfiles.enabled"
    private let selectedKey = "familyProfiles.selected"

    private(set) var isEnabled: Bool
    private(set) var activeSession: ProfileSession
    private(set) var isSwitching = false
    private(set) var isLocked = false
    private(set) var errorMessage: String?
    private(set) var hasPIN = false
    private(set) var isParentAuthorized = false

    var profiles: [FamilyProfile] { catalog?.profiles ?? [] }
    var activeProfile: FamilyProfile {
        profiles.first(where: { $0.id == activeSession.profile.id }) ?? activeSession.profile
    }
    var isParentAuthorizationRequired: Bool { profiles.contains(where: { $0.role == .child }) }

    private init() {
        defaults = .standard
        sessionFactory = { try ProfileSession(profile: $0) }
        pinStore = .shared
        let enabled = defaults.bool(forKey: enabledKey)
        isEnabled = enabled
        do {
            let catalog = try FamilyProfileStore(pinStore: pinStore)
            self.catalog = catalog
            hasPIN = try pinStore.isConfigured()
            if enabled, let selectedID = defaults.string(forKey: selectedKey) {
                guard let profile = catalog.profiles.first(where: { $0.id == selectedID }) else {
                    throw ProfileAccessError.profileUnavailable
                }
                activeSession = profile.id == FamilyProfile.ownerID ? .owner : try ProfileSession(profile: profile)
            } else {
                activeSession = .owner
            }
            isLocked = isEnabled && activeProfile.role == .adult && isParentAuthorizationRequired
        } catch {
            catalog = nil
            activeSession = .owner
            isEnabled = true
            isLocked = true
            errorMessage = "Profiles could not be opened. Your saved data has been kept."
        }
        if isLocked { activeSession.revokeSystemAccess() }
    }

    init(
        catalog: FamilyProfileStore,
        pinStore: AdultPINStore,
        defaults: UserDefaults,
        initialSession: ProfileSession,
        sessionFactory: @escaping (FamilyProfile) throws -> ProfileSession
    ) throws {
        self.catalog = catalog
        self.pinStore = pinStore
        self.defaults = defaults
        self.sessionFactory = sessionFactory
        activeSession = initialSession
        isEnabled = defaults.bool(forKey: enabledKey)
        hasPIN = try pinStore.isConfigured()
        isLocked = isEnabled && activeProfile.role == .adult && isParentAuthorizationRequired
    }

    func enable(ownerName: String, pin: String? = nil) throws {
        try requireIdle()
        let catalog = try availableCatalog()
        guard activeProfile.id == FamilyProfile.ownerID else { throw ProfileAccessError.parentAuthorizationRequired }
        if let pin {
            guard !hasPIN else { throw ProfileAccessError.parentAuthorizationRequired }
            try pinStore.configure(pin)
            hasPIN = true
        }
        try catalog.rename(profileID: FamilyProfile.ownerID, name: ownerName)
        defaults.set(true, forKey: enabledKey)
        defaults.set(FamilyProfile.ownerID, forKey: selectedKey)
        isEnabled = true
    }

    func disable() throws {
        try requireIdle()
        try requireParentAuthorization()
        guard profiles.count == 1, activeProfile.id == FamilyProfile.ownerID else {
            throw ProfileAccessError.removeOtherProfilesFirst
        }
        defaults.set(false, forKey: enabledKey)
        defaults.removeObject(forKey: selectedKey)
        isEnabled = false
        isLocked = false
        revokeParentAuthorization()
    }

    func configurePIN(_ pin: String) throws {
        try requireIdle()
        try requireParentAuthorization()
        guard !hasPIN else { throw ProfileAccessError.parentAuthorizationRequired }
        try pinStore.configure(pin)
        hasPIN = true
    }

    func authorizeParent(pin: String) throws {
        try pinStore.verify(pin)
        authorizationTask?.cancel()
        authorizationDeadline = ContinuousClock.now.advanced(by: .seconds(300))
        isParentAuthorized = true
        authorizationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) }
            catch { return }
            self?.revokeParentAuthorization()
        }
        if activeProfile.role == .adult { isLocked = false }
    }

    func revokeParentAuthorization() {
        authorizationTask?.cancel()
        authorizationTask = nil
        authorizationDeadline = nil
        isParentAuthorized = false
    }

    func onBackground() {
        revokeParentAuthorization()
        if isEnabled && activeProfile.role == .adult && isParentAuthorizationRequired {
            activeSession.revokeSystemAccess()
            isLocked = true
        }
    }

    @discardableResult
    func addProfile(name: String, role: FamilyProfileRole, serverSyncEnabled: Bool = false) throws -> FamilyProfile {
        try requireIdle()
        try requireParentAuthorization()
        guard isEnabled else { throw ProfileAccessError.profileUnavailable }
        let catalog = try availableCatalog()
        let profile = try role == .child ? catalog.addChild(name: name) : catalog.addAdult(name: name)
        try setServerSyncEnabled(serverSyncEnabled, profileID: profile.id)
        return profile
    }

    func serverSyncEnabled(profileID: String) -> Bool {
        if let value = serverSyncOverrides[profileID] { return value }
        guard let preferences = try? syncPreferences(profileID: profileID) else { return false }
        return preferences.isEnabled
    }

    func setServerSyncEnabled(_ enabled: Bool, profileID: String) throws {
        try requireIdle()
        try requireParentAuthorization()
        let preferences = try syncPreferences(profileID: profileID)
        preferences.isEnabled = enabled
        let session = activeSession.profile.id == profileID ? activeSession : inactiveSessions[profileID]
        if let session { session.pendingSync.removeAll() }
        else { PendingSyncQueueStore(defaults: preferences.defaults).removeAll() }
        serverSyncOverrides[profileID] = enabled
    }

    private func syncPreferences(profileID: String) throws -> ProfileServerSyncPreferences {
        guard profiles.contains(where: { $0.id == profileID }) else { throw ProfileAccessError.profileUnavailable }
        let preferences: UserDefaults
        if activeSession.profile.id == profileID { preferences = activeSession.defaults }
        else if let session = inactiveSessions[profileID] { preferences = session.defaults }
        else { preferences = try ProfileStorageLocations(profileID: profileID).openPreferences() }
        return ProfileServerSyncPreferences(defaults: preferences, isOwner: profileID == FamilyProfile.ownerID)
    }

    func renameProfile(id: String, name: String) throws {
        try requireIdle()
        try requireParentAuthorization()
        try availableCatalog().rename(profileID: id, name: name)
    }

    func removeProfile(id: String) async throws {
        try requireIdle()
        try requireParentAuthorization()
        guard id != FamilyProfile.ownerID, let profile = profiles.first(where: { $0.id == id }) else {
            throw ProfileAccessError.profileUnavailable
        }
        guard id != activeProfile.id else { throw ProfileAccessError.cannotRemoveActiveProfile }
        isSwitching = true
        defer { isSwitching = false }
        let session = try session(for: profile)
        await session.retire()
        inactiveSessions.removeValue(forKey: id)
        try requireParentAuthorization()
        try session.clearCredentials()
        #if canImport(WebKit)
        // Removing the store identifier crashes WebKit on iOS 27 Simulator.
        await session.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        #endif
        try requireParentAuthorization()
        try availableCatalog().remove(profileID: id)
        let locations = session.storage
        if let domain = locations.preferencesDomain { defaults.removePersistentDomain(forName: domain) }
        let root = locations.documentsDirectory.deletingLastPathComponent()
        for directory in [root, locations.cachesDirectory] where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func switchProfile(id: String) async throws {
        try requireIdle()
        guard isEnabled, let profile = profiles.first(where: { $0.id == id }) else {
            throw ProfileAccessError.profileUnavailable
        }
        if profile.role == .adult { try requireParentAuthorization() }
        isSwitching = true
        defer { isSwitching = false }
        if id == activeProfile.id {
            isLocked = false
            activeSession.start()
            return
        }
        let destination = try session(for: profile)
        await activeSession.retire()
        let canEnter = profile.role == .child || !isParentAuthorizationRequired ||
            (isParentAuthorized && authorizationDeadline.map { ContinuousClock.now < $0 } == true)
        inactiveSessions.removeValue(forKey: id)
        revokeParentAuthorization()
        activeSession = destination
        defaults.set(id, forKey: selectedKey)
        isLocked = !canEnter
        guard canEnter else { throw ProfileAccessError.parentAuthorizationRequired }
        destination.start()
    }

    func changePIN(currentPIN: String, newPIN: String) throws {
        try requireIdle()
        try pinStore.change(newPIN, currentPIN: currentPIN)
        revokeParentAuthorization()
    }

    func resetPIN(newPIN: String) async throws {
        try requireIdle()
        isSwitching = true
        defer { isSwitching = false }
        try await pinStore.reset(newPIN)
        hasPIN = true
        revokeParentAuthorization()
    }

    func importCandidates(from sourceProfileID: String) async throws -> [ProfileDownloadImportCandidate] {
        try requireIdle()
        try requireParentAuthorization()
        guard let profile = profiles.first(where: { $0.id == sourceProfileID }) else {
            throw ProfileAccessError.profileUnavailable
        }
        isSwitching = true
        defer { isSwitching = false }
        let source = try session(for: profile)
        let books = await source.bookStore.allBooks()
        try requireParentAuthorization()
        let completed = source.downloads.completedTasks
        return books.compactMap { book in
            guard let task = completed.first(where: {
                $0.bookId == book.downloadKey && $0.source == book.source
            }) else { return nil }
            let companion = books.first { other in
                other.stableId != book.stableId && (
                    book.linkedAudiobookStableId == other.stableId ||
                    other.linkedAudiobookStableId == book.stableId ||
                    book.readAloudSourceStableId == other.stableId ||
                    other.readAloudSourceStableId == book.stableId
                )
            }
            let linkedTask = companion.flatMap { linked in
                completed.first { $0.bookId == linked.downloadKey && $0.source == linked.source }
            }
            guard companion == nil || linkedTask != nil else { return nil }
            return ProfileDownloadImportCandidate(sourceProfileID: sourceProfileID, sourceBook: book,
                completedTask: task, linkedBook: companion, linkedTask: linkedTask)
        }
        .sorted { $0.sourceBook.title.localizedStandardCompare($1.sourceBook.title) == .orderedAscending }
    }

    func importCompleted(_ candidate: ProfileDownloadImportCandidate, into destinationProfileID: String) async throws -> Book {
        try requireIdle()
        try requireParentAuthorization()
        guard candidate.sourceProfileID != destinationProfileID,
            let sourceProfile = profiles.first(where: { $0.id == candidate.sourceProfileID }),
            let destinationProfile = profiles.first(where: { $0.id == destinationProfileID })
        else { throw ProfileAccessError.profileUnavailable }
        isSwitching = true
        defer { isSwitching = false }
        let source = try session(for: sourceProfile)
        let destination = try session(for: destinationProfile)
        var entries = [(book: candidate.sourceBook, completedTask: candidate.completedTask)]
        if let linkedBook = candidate.linkedBook, let linkedTask = candidate.linkedTask {
            entries.append((book: linkedBook, completedTask: linkedTask))
        }
        let freshBooks = await source.bookStore.allBooks()
        for entry in entries {
            guard source.downloads.completedTasks.contains(where: { $0.id == entry.completedTask.id && $0.status == .completed }),
                let fresh = freshBooks.first(where: { $0.uniqueId == entry.book.uniqueId }),
                fresh.linkedAudiobookStableId == entry.book.linkedAudiobookStableId,
                fresh.readAloudSourceStableId == entry.book.readAloudSourceStableId
            else { throw ProfileDownloadImportError.incompleteDownload }
        }
        let importer = ProfileDownloadImportService(source: source.localStorage, destination: destination.localStorage,
            sourceEbooks: source.ebooks, destinationEbooks: destination.ebooks)
        let imported = try await importer.importLinkedDownloads(entries) { imported in
            var books: [Book] = []
            for book in imported {
                if var existing = await destination.bookStore.book(uniqueId: book.uniqueId) {
                    existing.linkedAudiobookStableId = book.linkedAudiobookStableId
                    existing.linkedAudiobookChapterOffset = book.linkedAudiobookChapterOffset
                    existing.readAloudSourceStableId = book.readAloudSourceStableId
                    books.append(existing)
                } else { books.append(book) }
            }
            try self.requireParentAuthorization()
            await destination.bookStore.upsertBooks(books)
            for book in books {
                destination.downloads.recordCompletedImport(book)
                if destination === self.activeSession { destination.appState.ensureBookInMemory(book) }
            }
            destination.ebookLinker.invalidateCache()
            return books
        }
        return imported[0]
    }

    func handleBackgroundSession(identifier: String, completionHandler: @escaping () -> Void) {
        guard let id = UnifiedDownloadService.profileID(forBackgroundSessionIdentifier: identifier),
            let profile = profiles.first(where: { $0.id == id })
        else { completionHandler(); return }
        do { try session(for: profile).downloads.handleBackgroundSession(identifier: identifier) }
        catch { completionHandler() }
    }

    private func session(for profile: FamilyProfile) throws -> ProfileSession {
        if activeSession.profile.id == profile.id && !activeSession.isRetired { return activeSession }
        if let session = inactiveSessions[profile.id], !session.isRetired { return session }
        let session = try sessionFactory(profile)
        inactiveSessions[profile.id] = session
        return session
    }

    private func availableCatalog() throws -> FamilyProfileStore {
        guard let catalog else { throw ProfileAccessError.profileUnavailable }
        return catalog
    }

    func authorizeChanges(in session: ProfileSession) throws {
        guard activeSession === session, !session.isRetired, !isLocked else {
            throw ProfileAccessError.profileUnavailable
        }
        try requireParentAuthorization()
    }

    private func requireIdle() throws {
        _ = try availableCatalog()
        guard !isSwitching else { throw ProfileAccessError.operationInProgress }
    }

    private func requireParentAuthorization() throws {
        _ = try availableCatalog()
        guard !isParentAuthorizationRequired || (isParentAuthorized && authorizationDeadline.map { ContinuousClock.now < $0 } == true) else {
            revokeParentAuthorization()
            throw ProfileAccessError.parentAuthorizationRequired
        }
    }
}
