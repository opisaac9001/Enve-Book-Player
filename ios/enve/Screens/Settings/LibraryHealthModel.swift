import Foundation
import Observation

enum LibraryHealthLevel: Equatable, Sendable {
    case ready
    case notice
    case attention
}

enum LibrarySourceHealth: Equatable, Sendable {
    case ready
    case disconnected
    case needsSignIn
}

struct LibraryHealthSourceStatus: Identifiable, Sendable {
    let id: UUID
    let name: String
    let type: ProviderType
    let health: LibrarySourceHealth
    let bookCount: Int
    let lastVerified: Date?
}

struct LibraryHealthSnapshot: Sendable {
    let level: LibraryHealthLevel
    let sources: [LibraryHealthSourceStatus]
    let totalBooks: Int
    let pendingSyncCount: Int
    let lastSyncDate: Date?
    let syncEnabled: Bool
    let activeDownloadCount: Int
    let failedDownloadCount: Int
    let orphanDownloadCount: Int
    let downloadedBytes: Int64
    let availableBytes: Int64
    let recentSystemIncidentCount: Int
    let lastSystemIncidentAt: Date?
    let lastMetricReportAt: Date?
    let checkedAt: Date
}

enum LibraryHealthPolicy {
    nonisolated static func level(
        sourceHealth: [LibrarySourceHealth],
        pendingSyncCount: Int,
        failedDownloadCount: Int,
        orphanDownloadCount: Int,
        availableBytes: Int64,
        recentSystemIncidentCount: Int
    ) -> LibraryHealthLevel {
        if sourceHealth.contains(.needsSignIn)
            || sourceHealth.contains(.disconnected)
            || failedDownloadCount > 0
            || orphanDownloadCount > 0
            || recentSystemIncidentCount > 0
        {
            return .attention
        }
        if sourceHealth.isEmpty || pendingSyncCount > 0 || availableBytes < 1_000_000_000 {
            return .notice
        }
        return .ready
    }
}

@MainActor
@Observable
final class LibraryHealthModel {
    private(set) var snapshot: LibraryHealthSnapshot?
    private(set) var isLoading = false
    private(set) var isRunningCheck = false

    private let appState: AppState
    private let engine: EnveEngine
    private let diagnostics: RuntimeDiagnosticsStore

    init(
        appState: AppState = .shared,
        engine: EnveEngine = .shared,
        diagnostics: RuntimeDiagnosticsStore = .shared
    ) {
        self.appState = appState
        self.engine = engine
        self.diagnostics = diagnostics
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        snapshot = await collectSnapshot()
    }

    func runCheck() async {
        guard !isRunningCheck else { return }
        isRunningCheck = true
        defer { isRunningCheck = false }

        await engine.library.refreshLibrary()
        await engine.sync.manualSync()
        snapshot = await collectSnapshot()
    }

    private func collectSnapshot() async -> LibraryHealthSnapshot {
        let signpost = PerfSignpost.begin("library-health-check")
        defer { PerfSignpost.end(signpost) }

        let connections = appState.providerConnections.connections.filter { !$0.isArchived }
        let reauthenticationIds = Set(appState.providerConnections.connectionsNeedingReauth.map(\.id))
        var sources: [LibraryHealthSourceStatus] = []
        sources.reserveCapacity(connections.count)

        for connection in connections {
            let health: LibrarySourceHealth
            if reauthenticationIds.contains(connection.id) {
                health = .needsSignIn
            } else if connection.isConnected {
                health = .ready
            } else {
                health = .disconnected
            }
            sources.append(
                LibraryHealthSourceStatus(
                    id: connection.id,
                    name: connection.name,
                    type: connection.type,
                    health: health,
                    bookCount: await appState.bookStore.bookCount(providerId: connection.id, mediaType: nil),
                    lastVerified: connection.lastVerified
                )
            )
        }
        sources.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        async let totalBooksRequest = appState.bookStore.bookCount()
        async let storageItemsRequest = engine.downloads.downloadedStorageItems()
        async let availableBytesRequest = Self.availableDiskBytes()
        let storageItems = await storageItemsRequest
        let availableBytes = await availableBytesRequest
        let recentCutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        let diagnosticSnapshot = diagnostics.snapshot
        let recentSystemIncidentCount = diagnosticSnapshot.recentIncidentCount(since: recentCutoff)

        let level = LibraryHealthPolicy.level(
            sourceHealth: sources.map(\.health),
            pendingSyncCount: engine.sync.pendingSyncCount,
            failedDownloadCount: engine.downloads.failedTasks.count,
            orphanDownloadCount: storageItems.count { $0.book == nil },
            availableBytes: availableBytes,
            recentSystemIncidentCount: recentSystemIncidentCount
        )

        return LibraryHealthSnapshot(
            level: level,
            sources: sources,
            totalBooks: await totalBooksRequest,
            pendingSyncCount: engine.sync.pendingSyncCount,
            lastSyncDate: engine.sync.lastSyncDate,
            syncEnabled: engine.sync.syncEnabled,
            activeDownloadCount: engine.downloads.activeTasks.count,
            failedDownloadCount: engine.downloads.failedTasks.count,
            orphanDownloadCount: storageItems.count { $0.book == nil },
            downloadedBytes: storageItems.reduce(0) { $0 + $1.sizeBytes },
            availableBytes: availableBytes,
            recentSystemIncidentCount: recentSystemIncidentCount,
            lastSystemIncidentAt: diagnosticSnapshot.lastIncidentAt,
            lastMetricReportAt: diagnosticSnapshot.lastMetricReportAt,
            checkedAt: .now
        )
    }

    private nonisolated static func availableDiskBytes() async -> Int64 {
        await Task.detached(priority: .utility) {
            guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
                let free = attributes[.systemFreeSize] as? NSNumber
            else { return Int64(0) }
            return free.int64Value
        }.value
    }
}
