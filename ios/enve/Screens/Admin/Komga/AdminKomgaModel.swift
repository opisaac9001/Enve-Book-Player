import Foundation
import Observation

@MainActor
@Observable
final class AdminKomgaModel {
    let connection: ServerConnection
    private let service: KomgaAdminService

    var serverInfo: KomgaServerInfo?
    var claim: KomgaClaim?
    var currentUser: KomgaUser?
    var announcements: [KomgaAnnouncement] = []

    var libraries: [KomgaLibraryDetail] = []
    var libraryStats: [String: AdminKomgaLibraryStats] = [:]

    var recentlyAddedSeries: [KomgaSeriesSummary] = []
    var recentlyUpdatedSeries: [KomgaSeriesSummary] = []
    var onDeck: [KomgaBookSummary] = []
    var latestBooks: [KomgaBookSummary] = []

    var readLists: [KomgaReadList] = []
    var collections: [KomgaCollectionSummary] = []

    var isAuthorized = false
    var isLoading = false
    var hasLoaded = false
    var error: String?
    var successMessage: String?

    private(set) var inFlightLibraryAction: String?

    struct AdminKomgaLibraryStats {
        var seriesCount = 0
        var bookCount = 0
    }

    init(connection: ServerConnection) {
        self.connection = connection
        self.service = KomgaAdminService(connection: connection)
    }

    var imageHeaders: [String: String] { service.imageHeaders }
    func bookThumbURL(_ id: String) -> URL? { service.bookThumbnailURL(bookId: id) }
    func seriesThumbURL(_ id: String) -> URL? { service.seriesThumbnailURL(seriesId: id) }

    func refreshAll() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            currentUser = try await service.fetchCurrentUser()
            isAuthorized = true
        } catch {
            self.error = "The server would not say who you are. Check the sign-in and try again."
            isAuthorized = false
            return
        }

        let svc = service
        async let infoTask = try? svc.fetchServerInfo()
        async let claimTask = try? svc.fetchClaim()
        async let announcementsTask = try? svc.fetchAnnouncements()
        async let recentTask = try? svc.fetchRecentlyAddedSeries(limit: 12)
        async let updatedTask = try? svc.fetchRecentlyUpdatedSeries(limit: 12)
        async let onDeckTask = try? svc.fetchOnDeck(limit: 12)
        async let latestTask = try? svc.fetchLatestBooks(limit: 12)
        async let readListsTask = try? svc.fetchReadLists(size: 50)
        async let collectionsTask = try? svc.fetchCollections(size: 50)

        if let info = await infoTask { serverInfo = info }
        if let claim = await claimTask { self.claim = claim }
        announcements = await announcementsTask ?? []
        recentlyAddedSeries = await recentTask ?? []
        recentlyUpdatedSeries = await updatedTask ?? []
        onDeck = await onDeckTask ?? []
        latestBooks = await latestTask ?? []
        readLists = await readListsTask ?? []
        collections = await collectionsTask ?? []

        if let libs = try? await svc.fetchLibraries() {
            libraries = libs

            var stats: [String: AdminKomgaLibraryStats] = [:]
            for lib in libs {
                async let seriesCount = try? svc.librarySeriesCount(libraryId: lib.id)
                async let bookCount = try? svc.libraryBookCount(libraryId: lib.id)
                stats[lib.id] = AdminKomgaLibraryStats(
                    seriesCount: await seriesCount ?? 0,
                    bookCount: await bookCount ?? 0
                )
            }
            libraryStats = stats
        }
    }

    var totalSeriesCount: Int { libraryStats.values.reduce(0) { $0 + $1.seriesCount } }
    var totalBookCount: Int { libraryStats.values.reduce(0) { $0 + $1.bookCount } }

    func scanLibrary(_ lib: KomgaLibraryDetail, deep: Bool) async {
        await adminLibraryRun(lib, label: deep ? "Deep scan" : "Scan") {
            try await self.service.scanLibrary(id: lib.id, deep: deep)
        }
    }

    func analyzeLibrary(_ lib: KomgaLibraryDetail) async {
        await adminLibraryRun(lib, label: "Analysis") {
            try await self.service.analyzeLibrary(id: lib.id)
        }
    }

    func refreshLibraryMetadata(_ lib: KomgaLibraryDetail) async {
        await adminLibraryRun(lib, label: "Metadata refresh") {
            try await self.service.refreshLibraryMetadata(id: lib.id)
        }
    }

    func emptyLibraryTrash(_ lib: KomgaLibraryDetail) async {
        await adminLibraryRun(lib, label: "Trash emptying") {
            try await self.service.emptyLibraryTrash(id: lib.id)
        }
    }

    func isLibraryBusy(_ lib: KomgaLibraryDetail) -> Bool {
        inFlightLibraryAction?.hasPrefix("\(lib.id):") == true
    }

    private func adminLibraryRun(
        _ lib: KomgaLibraryDetail,
        label: String,
        op: @escaping () async throws -> Bool
    ) async {
        inFlightLibraryAction = "\(lib.id):\(label)"
        defer { inFlightLibraryAction = nil }
        do {
            if try await op() {
                successMessage = "\(label) is queued for \(lib.name)."
            } else {
                error = "\(label) did not take for \(lib.name)."
            }
        } catch {
            self.error = "\(label) failed: \(error.localizedDescription)"
        }
    }

    func createReadList(name: String, summary: String?) async {
        guard !name.isEmpty else { return }
        do {
            try await service.createReadList(name: name, summary: summary)
            successMessage = "“\(name)” is ready."
            readLists = (try? await service.fetchReadLists(size: 50)) ?? readLists
        } catch {
            self.error = "The read list could not be created: \(error.localizedDescription)"
        }
    }

    func deleteReadList(_ list: KomgaReadList) async {
        do {
            try await service.deleteReadList(id: list.id)
            readLists.removeAll { $0.id == list.id }
            successMessage = "“\(list.name)” was deleted."
        } catch {
            self.error = "It could not be deleted: \(error.localizedDescription)"
        }
    }

    func createCollection(name: String, ordered: Bool) async {
        guard !name.isEmpty else { return }
        do {
            try await service.createCollection(name: name, ordered: ordered)
            successMessage = "“\(name)” is ready."
            collections = (try? await service.fetchCollections(size: 50)) ?? collections
        } catch {
            self.error = "The collection could not be created: \(error.localizedDescription)"
        }
    }

    func deleteCollection(_ coll: KomgaCollectionSummary) async {
        do {
            try await service.deleteCollection(id: coll.id)
            collections.removeAll { $0.id == coll.id }
            successMessage = "“\(coll.name)” was deleted."
        } catch {
            self.error = "It could not be deleted: \(error.localizedDescription)"
        }
    }
}
