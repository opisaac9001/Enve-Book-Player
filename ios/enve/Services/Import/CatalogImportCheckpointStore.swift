import CryptoKit
import Foundation

struct CatalogImportCheckpoint: Codable {
    let version: Int
    let connectionId: UUID
    let libraryId: String
    let providerType: ProviderType
    let snapshotIdentifier: String
    let reconciliationGeneration: Int
    let existingCountBefore: Int
    var resumeToken: String?
    var committedBookCount: Int
    var completedSnapshot: Bool
    var updatedAt: Date

    var reconciliation: ReconciliationStart {
        ReconciliationStart(
            generation: reconciliationGeneration,
            existingCount: existingCountBefore
        )
    }
}

struct CatalogImportCheckpointStore {
    static let shared = CatalogImportCheckpointStore()
    private let root: URL
    static func load(connectionId: UUID, libraryId: String) -> CatalogImportCheckpoint? { shared.load(connectionId: connectionId, libraryId: libraryId) }
    static func start(connection: ServerConnection, libraryId: String, snapshotIdentifier: String, reconciliation: ReconciliationStart) throws -> CatalogImportCheckpoint { try shared.start(connection: connection, libraryId: libraryId, snapshotIdentifier: snapshotIdentifier, reconciliation: reconciliation) }
    static func markCommitted(_ batch: LibraryCatalogBatch, checkpoint: inout CatalogImportCheckpoint) throws { try shared.markCommitted(batch, checkpoint: &checkpoint) }
    static func clear(connectionId: UUID, libraryId: String) { shared.clear(connectionId: connectionId, libraryId: libraryId) }
    static var pendingConnectionIds: Set<UUID> { shared.pendingConnectionIds }


    init(storage: ProfileStorageLocations = .owner) {
        root = storage.applicationSupportDirectory.appendingPathComponent("CatalogImportCheckpoints", isDirectory: true)
    }
    private let version = 1
    private let manifestFilename = "manifest.json"

    func load(connectionId: UUID, libraryId: String) -> CatalogImportCheckpoint? {
        let url = manifestURL(connectionId: connectionId, libraryId: libraryId)
        guard let data = try? Data(contentsOf: url),
            let checkpoint = try? JSONDecoder().decode(CatalogImportCheckpoint.self, from: data),
            checkpoint.version == version,
            checkpoint.connectionId == connectionId,
            checkpoint.libraryId == libraryId
        else { return nil }
        return checkpoint
    }

    func start(
        connection: ServerConnection,
        libraryId: String,
        snapshotIdentifier: String,
        reconciliation: ReconciliationStart
    ) throws -> CatalogImportCheckpoint {
        let checkpoint = CatalogImportCheckpoint(
            version: version,
            connectionId: connection.id,
            libraryId: libraryId,
            providerType: connection.type,
            snapshotIdentifier: snapshotIdentifier,
            reconciliationGeneration: reconciliation.generation,
            existingCountBefore: reconciliation.existingCount,
            resumeToken: nil,
            committedBookCount: 0,
            completedSnapshot: false,
            updatedAt: Date()
        )
        try save(checkpoint)
        return checkpoint
    }

    func markCommitted(
        _ batch: LibraryCatalogBatch,
        checkpoint: inout CatalogImportCheckpoint
    ) throws {
        checkpoint.resumeToken = batch.resumeToken
        checkpoint.committedBookCount += batch.books.count
        checkpoint.completedSnapshot = batch.completesSnapshot
        checkpoint.updatedAt = Date()
        try save(checkpoint)
    }

    func clear(connectionId: UUID, libraryId: String) {
        try? FileManager.default.removeItem(
            at: directoryURL(connectionId: connectionId, libraryId: libraryId)
        )
    }

    var pendingConnectionIds: Set<UUID> {
        let root = rootDirectoryURL()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result = Set<UUID>()
        for case let url as URL in enumerator where url.lastPathComponent == manifestFilename {
            guard let data = try? Data(contentsOf: url),
                let checkpoint = try? JSONDecoder().decode(CatalogImportCheckpoint.self, from: data),
                checkpoint.version == version
            else { continue }
            result.insert(checkpoint.connectionId)
        }
        return result
    }

    private func save(_ checkpoint: CatalogImportCheckpoint) throws {
        let directory = directoryURL(connectionId: checkpoint.connectionId, libraryId: checkpoint.libraryId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: directory.appendingPathComponent(manifestFilename), options: .atomic)
    }

    private func rootDirectoryURL() -> URL { root }

    private func directoryURL(connectionId: UUID, libraryId: String) -> URL {
        let digest = SHA256.hash(data: Data("\(connectionId.uuidString):\(libraryId)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootDirectoryURL().appendingPathComponent(digest, isDirectory: true)
    }

    private func manifestURL(connectionId: UUID, libraryId: String) -> URL {
        directoryURL(connectionId: connectionId, libraryId: libraryId)
            .appendingPathComponent(manifestFilename)
    }
}
