import Foundation

public struct Bookmark: Identifiable, Codable, Equatable {
    public let id: String
    public let bookId: String
    public let title: String
    public let position: TimeInterval
    public let timestamp: Date
    public let note: String?
    public let locator: String?
    public let mediaType: AppMediaType
    public let chapterTitle: String?
    public let remoteID: Int?
    public let isRemotePlaceholder: Bool

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        position: TimeInterval,
        title: String,
        note: String? = nil,
        timestamp: Date = Date(),
        locator: String? = nil,
        mediaType: AppMediaType = .audiobook,
        chapterTitle: String? = nil,
        remoteID: Int? = nil,
        isRemotePlaceholder: Bool = false
    ) {
        self.id = id
        self.bookId = bookId
        self.position = position
        self.title = title
        self.note = note
        self.timestamp = timestamp
        self.locator = locator
        self.mediaType = mediaType
        self.chapterTitle = chapterTitle
        self.remoteID = remoteID
        self.isRemotePlaceholder = isRemotePlaceholder
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        title = try container.decode(String.self, forKey: .title)
        position = try container.decode(TimeInterval.self, forKey: .position)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        locator = try container.decodeIfPresent(String.self, forKey: .locator)
        mediaType = try container.decodeIfPresent(AppMediaType.self, forKey: .mediaType) ?? .audiobook
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
        remoteID = try container.decodeIfPresent(Int.self, forKey: .remoteID)
        isRemotePlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isRemotePlaceholder) ?? false
    }

    public var formattedTime: String {
        if isRemotePlaceholder {
            return "Synced"
        }
        if mediaType == .ebook {
            return "\(Int(position * 100))%"
        }
        return formatTime(position)
    }

    public var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

private func formatTime(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds) / 3600
    let minutes = Int(seconds) / 60 % 60
    let secs = Int(seconds) % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    } else {
        return String(format: "%d:%02d", minutes, secs)
    }
}
