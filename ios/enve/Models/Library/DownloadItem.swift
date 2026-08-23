import Foundation

struct DownloadItem: Identifiable, Codable, Sendable {
    enum ItemType: String, Codable {
        case bookFile
        case bookMetadata
    }

    enum Status: String, Codable {
        case pending
        case downloading
        case paused
        case completed
        case failed
        case cancelled
    }

    let id: String
    let bookId: String
    let title: String
    let type: ItemType
    let remoteURL: URL
    let destinationPath: String
    var status: Status = .pending
    var bytesDownloaded: Int64 = 0
    var totalBytes: Int64 = 0
    var errorDescription: String?
    var lastUpdated: Date = Date()
    var createdAt: Date = Date()

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }

    var isActive: Bool {
        status == .downloading || status == .pending
    }

    var displayProgress: String {
        let percent = Int(progress * 100)
        if totalBytes > 0 {
            let downloaded = formatBytes(bytesDownloaded)
            let total = formatBytes(totalBytes)
            return "\(percent)% (\(downloaded) / \(total))"
        }
        return "\(percent)%"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func newBook(
        bookId: String,
        title: String,
        remoteURL: URL,
        destinationPath: String
    ) -> DownloadItem {
        return DownloadItem(
            id: UUID().uuidString,
            bookId: bookId,
            title: title,
            type: .bookFile,
            remoteURL: remoteURL,
            destinationPath: destinationPath
        )
    }

    static func newMetadataBatch(
        title: String,
        destinationPath: String
    ) -> DownloadItem {
        return DownloadItem(
            id: UUID().uuidString,
            bookId: "metadata-batch",
            title: title,
            type: .bookMetadata,
            remoteURL: URL(string: "about:blank")!,
            destinationPath: destinationPath
        )
    }
}

struct DownloadQueue: Codable {
    var items: [DownloadItem] = []
    var lastModified: Date = Date()

    mutating func addItem(_ item: DownloadItem) {
        items.append(item)
        lastModified = Date()
    }

    mutating func removeItem(withId id: String) {
        items.removeAll { $0.id == id }
        lastModified = Date()
    }

    mutating func updateItem(_ item: DownloadItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
            lastModified = Date()
        }
    }

    var activeItems: [DownloadItem] {
        items.filter { $0.isActive }
    }

    var completedItems: [DownloadItem] {
        items.filter { $0.status == .completed }
    }
}
