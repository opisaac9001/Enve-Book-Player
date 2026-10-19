import CryptoKit
import Foundation

struct GrimmoryCatalogCheckpoint: Codable {
    let version: Int
    let connectionId: UUID
    let libraryId: String
    let serverIdentity: String
    let totalPages: Int
    let totalElements: Int
    let pageSize: Int
    let firstPageFingerprint: String
    var completedPages: Set<Int>
    var committedPages: Set<Int>?
    var reconciliationGeneration: Int?
    var existingCountBefore: Int?
    var committedBookCount: Int?
    var updatedAt: Date
}

struct GrimmoryCatalogCheckpointStore {
    private let root: URL

    init(root: URL = ProfileStorageLocations.owner.applicationSupportDirectory) {
        self.root = root.appendingPathComponent("GrimmoryCatalogCheckpoints", isDirectory: true)
    }
    private let version = 1
    private let manifestFilename = "manifest.json"

    func prepare(
        connectionId: UUID,
        libraryId: String,
        serverIdentity: String,
        totalPages: Int,
        totalElements: Int,
        pageSize: Int,
        firstPageFingerprint: String,
        firstPageData: Data
    ) throws -> (checkpoint: GrimmoryCatalogCheckpoint, resumed: Bool) {
        let directory = directoryURL(connectionId: connectionId, libraryId: libraryId)
        let existing = loadManifest(at: directory)
        let canResume = existing.map {
            $0.version == version
                && $0.connectionId == connectionId
                && $0.libraryId == libraryId
                && $0.serverIdentity == serverIdentity
                && $0.totalPages == totalPages
                && $0.totalElements == totalElements
                && $0.pageSize == pageSize
                && $0.firstPageFingerprint == firstPageFingerprint
        } ?? false

        if !canResume {
            try? FileManager.default.removeItem(at: directory)
        }
        try createDirectoryIfNeeded(directory)

        var checkpoint: GrimmoryCatalogCheckpoint
        if canResume, let existing {
            checkpoint = existing
        } else {
            checkpoint = GrimmoryCatalogCheckpoint(
                version: version,
                connectionId: connectionId,
                libraryId: libraryId,
                serverIdentity: serverIdentity,
                totalPages: totalPages,
                totalElements: totalElements,
                pageSize: pageSize,
                firstPageFingerprint: firstPageFingerprint,
                completedPages: [],
                committedPages: [],
                reconciliationGeneration: nil,
                existingCountBefore: nil,
                committedBookCount: 0,
                updatedAt: Date()
            )
        }
        try firstPageData.write(to: pageURL(0, in: directory), options: .atomic)
        checkpoint.completedPages.insert(0)
        checkpoint.updatedAt = Date()
        try saveManifest(checkpoint, at: directory)
        return (checkpoint, canResume)
    }

    func pageData(connectionId: UUID, libraryId: String, page: Int) throws -> Data {
        try Data(contentsOf: pageURL(page, in: directoryURL(connectionId: connectionId, libraryId: libraryId)))
    }

    func recordPage(
        _ data: Data,
        page: Int,
        checkpoint: inout GrimmoryCatalogCheckpoint
    ) throws {
        let directory = directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        try data.write(to: pageURL(page, in: directory), options: .atomic)
        checkpoint.completedPages.insert(page)
        checkpoint.updatedAt = Date()
        try saveManifest(checkpoint, at: directory)
    }

    func discardPage(page: Int, checkpoint: inout GrimmoryCatalogCheckpoint) {
        let directory = directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        try? FileManager.default.removeItem(at: pageURL(page, in: directory))
        checkpoint.completedPages.remove(page)
        checkpoint.updatedAt = Date()
        try? saveManifest(checkpoint, at: directory)
    }

    func bindReconciliation(
        _ reconciliation: ReconciliationStart,
        checkpoint: inout GrimmoryCatalogCheckpoint
    ) throws {
        checkpoint.reconciliationGeneration = reconciliation.generation
        checkpoint.existingCountBefore = reconciliation.existingCount
        checkpoint.committedPages = []
        checkpoint.committedBookCount = 0
        checkpoint.updatedAt = Date()
        try saveManifest(
            checkpoint,
            at: directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        )
    }

    func markCommitted(
        pages: [Int],
        bookCount: Int,
        checkpoint: inout GrimmoryCatalogCheckpoint
    ) throws {
        var committed = checkpoint.committedPages ?? []
        committed.formUnion(pages)
        checkpoint.committedPages = committed
        checkpoint.committedBookCount = (checkpoint.committedBookCount ?? 0) + bookCount
        checkpoint.updatedAt = Date()
        try saveManifest(
            checkpoint,
            at: directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        )
    }

    func clear(connectionId: UUID, libraryId: String) {
        try? FileManager.default.removeItem(at: directoryURL(connectionId: connectionId, libraryId: libraryId))
    }

    func pendingConnectionIds() -> Set<UUID> {
        let root = root
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result = Set<UUID>()
        for case let url as URL in enumerator where url.lastPathComponent == manifestFilename {
            guard let data = try? Data(contentsOf: url),
                let checkpoint = try? JSONDecoder().decode(GrimmoryCatalogCheckpoint.self, from: data),
                checkpoint.version == version
            else { continue }
            result.insert(checkpoint.connectionId)
        }
        return result
    }

    private func loadManifest(at directory: URL) -> GrimmoryCatalogCheckpoint? {
        let url = directory.appendingPathComponent(manifestFilename, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GrimmoryCatalogCheckpoint.self, from: data)
    }

    private func saveManifest(_ checkpoint: GrimmoryCatalogCheckpoint, at directory: URL) throws {
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: directory.appendingPathComponent(manifestFilename, isDirectory: false), options: .atomic)
    }

    private func createDirectoryIfNeeded(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }


    private func directoryURL(connectionId: UUID, libraryId: String) -> URL {
        let digest = SHA256.hash(data: Data("\(connectionId.uuidString):\(libraryId)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return root.appendingPathComponent(digest, isDirectory: true)
    }

    private func pageURL(_ page: Int, in directory: URL) -> URL {
        directory.appendingPathComponent("page-\(page).json", isDirectory: false)
    }
}
