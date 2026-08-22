import Foundation
import Observation

@MainActor
@Observable
final class AdminSiloModel {
    let connection: ServerConnection
    private let service: SiloAdminService

    var me: SiloMeUser?
    var users: [SiloAdminUser] = []
    var libraries: [SiloAdminLibrary] = []
    var stats: SiloAdminStats?
    var playbackHistory: [SiloPlaybackEntry] = []
    var scans: [SiloScan] = []
    var libraryCounts: [Int: LibraryCounts] = [:]
    var personalProgress: [UserMediaProgress] = []
    var personalBooks: [String: Book] = [:]

    var isAuthorized = false
    var isLoading = false
    var hasLoaded = false
    var error: String?
    var successMessage: String?

    private(set) var inFlightScanLibraryID: Int?

    struct LibraryCounts {
        var audiobooks = 0
        var ebooks = 0
    }

    init(connection: ServerConnection) {
        self.connection = connection
        self.service = SiloAdminService(connection: connection)
    }

    func refreshAll() async {
        isLoading = true
        error = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            users = try await service.fetchAdminUsers()
            isAuthorized = true
        } catch SiloAdminError.unauthorized {
            isAuthorized = false
            me = try? await service.fetchMe()
            await loadPersonalReading()
            return
        } catch {
            isAuthorized = false
            self.error = "Could not reach the server. Check the connection and try again."
            return
        }

        me = try? await service.fetchMe()
        await loadPersonalReading()

        async let statsTask = try? service.fetchStats()
        async let librariesTask = try? service.fetchLibraries()
        async let historyTask = try? service.fetchPlaybackHistory(limit: 25)
        async let scansTask = try? service.fetchRecentScans(limit: 20)

        stats = await statsTask
        libraries = await librariesTask ?? []
        playbackHistory = await historyTask ?? []
        scans = await scansTask ?? []

        await loadCatalogCounts()
    }

    private func loadPersonalReading() async {
        guard let provider = AppState.shared.getProvider(connection.id) as? SiloProvider,
            let progress = try? await provider.fetchUserMediaProgress(libraryId: "")
        else {
            return
        }
        personalProgress = progress.filter { $0.duration > 0 || $0.isFinished }
        personalBooks = await AppState.shared.bookStore.booksByAnyIds(Set(personalProgress.map(\.uniqueId)))
    }

    private func loadCatalogCounts() async {
        var counts: [Int: LibraryCounts] = [:]
        for library in libraries where library.isReadingLibrary {
            var entry = LibraryCounts()
            if library.countsAudiobooks {
                entry.audiobooks = (try? await service.catalogTotal(libraryId: library.id, type: "audiobook")) ?? 0
            }
            if library.countsEbooks {
                entry.ebooks = (try? await service.catalogTotal(libraryId: library.id, type: "ebook")) ?? 0
            }
            counts[library.id] = entry
        }
        libraryCounts = counts
    }

    func scanLibrary(_ library: SiloAdminLibrary) async {
        inFlightScanLibraryID = library.id
        defer { inFlightScanLibraryID = nil }
        do {
            try await service.scanLibrary(id: library.id)
            successMessage = "A scan is queued for \(library.name)."
            scans = (try? await service.fetchRecentScans(limit: 20)) ?? scans
        } catch SiloAdminError.unauthorized {
            error = "You are not allowed to scan this library."
        } catch {
            self.error = "The scan could not be started for \(library.name)."
        }
    }

    func isLibraryScanning(_ library: SiloAdminLibrary) -> Bool {
        inFlightScanLibraryID == library.id
    }

    var readingLibraries: [SiloAdminLibrary] { libraries.filter(\.isReadingLibrary) }
    var totalAudiobooks: Int { libraryCounts.values.reduce(0) { $0 + $1.audiobooks } }
    var totalEbooks: Int { libraryCounts.values.reduce(0) { $0 + $1.ebooks } }

    var historyTotalSeconds: Double {
        playbackHistory.reduce(0) { $0 + ($1.watchedSeconds ?? 0) }
    }

    var historyCompleted: Int {
        playbackHistory.filter { $0.completed == true }.count
    }

    var historyInProgress: Int {
        playbackHistory.filter { $0.completed != true }.count
    }

    var historyListeners: Int {
        Set(playbackHistory.compactMap { $0.username }).count
    }

    var personalFinished: Int { personalProgress.filter(\.isFinished).count }

    var personalInProgress: [UserMediaProgress] {
        personalProgress
            .filter { !$0.isFinished && $0.progress > 0 }
            .sorted { $0.lastUpdate > $1.lastUpdate }
    }

    var personalSeconds: Double {
        personalProgress.reduce(0) { $0 + $1.currentTime }
    }
}
