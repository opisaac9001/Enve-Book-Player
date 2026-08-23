import Foundation

final class DownloadPersistence: Sendable {
    static let shared = DownloadPersistence()

    private let fileManager = FileManager.default

    private init() {}

    private var queueDirectory: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("DownloadQueues", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }

    private var metadataQueueURL: URL {
        queueDirectory.appendingPathComponent("metadata_downloads.json")
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
        let data = try JSONEncoder().encode(queue)
        try data.write(to: metadataQueueURL, options: .atomic)
    }
}
