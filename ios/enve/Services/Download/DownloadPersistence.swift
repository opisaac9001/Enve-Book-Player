import Foundation

final class DownloadPersistence: Sendable {
    static let shared = DownloadPersistence()

    private let fileManager: FileManager
    private let metadataQueueURL: URL
    private let rejectsUnreadableStorage: Bool

    init(
        fileURL: URL = ProfileStorageLocations.owner.documentsDirectory
            .appendingPathComponent("DownloadQueues/metadata_downloads.json"),
        fileManager: FileManager = .default
    ) {
        metadataQueueURL = fileURL
        self.fileManager = fileManager
        rejectsUnreadableStorage = false
    }

    init(storage: ProfileStorageLocations, fileManager: FileManager = .default) throws {
        metadataQueueURL = storage.documentsDirectory
            .appendingPathComponent("DownloadQueues/metadata_downloads.json")
        self.fileManager = fileManager
        rejectsUnreadableStorage = storage.profileID != FamilyProfile.ownerID
        if rejectsUnreadableStorage, fileManager.fileExists(atPath: metadataQueueURL.path) {
            _ = try JSONDecoder().decode(DownloadQueue.self, from: Data(contentsOf: metadataQueueURL))
        }
    }

    func loadMetadataDownloadQueue() -> DownloadQueue {
        guard let data = try? Data(contentsOf: metadataQueueURL),
            let queue = try? JSONDecoder().decode(DownloadQueue.self, from: data)
        else {
            return DownloadQueue()
        }
        return queue
    }

    func saveMetadataDownloadQueue(_ queue: DownloadQueue) throws {
        if rejectsUnreadableStorage, fileManager.fileExists(atPath: metadataQueueURL.path) {
            _ = try JSONDecoder().decode(DownloadQueue.self, from: Data(contentsOf: metadataQueueURL))
        }
        let data = try JSONEncoder().encode(queue)
        try fileManager.createDirectory(
            at: metadataQueueURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: metadataQueueURL, options: .atomic)
    }
}
