import Foundation
import SwiftData

@Model
final class PlaybackState {
    var bookId: String
    var currentPosition: TimeInterval = 0
    var playbackSpeed: Double = 1.0
    var currentChapterIndex: Int = 0
    var lastPlayedDate: Date?
    var totalPlayTime: TimeInterval = 0

    @Relationship(deleteRule: .cascade, inverse: \AudiobookBookmark.playbackState)
    var bookmarks: [AudiobookBookmark] = []

    init(bookId: String) {
        self.bookId = bookId
        self.lastPlayedDate = Date()
    }
}

@Model
final class AudiobookBookmark: Identifiable {
    var id: UUID = UUID()
    var timestamp: TimeInterval
    var title: String
    var notes: String = ""
    var createdDate: Date = Date()
    var playbackState: PlaybackState?

    init(timestamp: TimeInterval, title: String, notes: String = "") {
        self.timestamp = timestamp
        self.title = title
        self.notes = notes
    }
}

@Model
final class MetadataOverride {
    var bookId: String
    var customTitle: String?
    var customAuthor: String?
    var customNarrator: String?
    var customDescription: String?
    var customSeries: String?
    var customSeriesNumber: Int?
    var customGenres: [String] = []
    var customNotes: String = ""
    var lastModified: Date = Date()

    init(bookId: String) {
        self.bookId = bookId
    }
}

@Model
final class SyncedPlaybackState {
    var bookId: String
    var deviceId: String
    var lastSyncDate: Date
    var currentPosition: TimeInterval
    var playbackSpeed: Double
    var currentChapterIndex: Int
    var lastPlayedDate: Date?

    init(
        bookId: String,
        deviceId: String,
        currentPosition: TimeInterval,
        playbackSpeed: Double,
        currentChapterIndex: Int,
        lastPlayedDate: Date?
    ) {
        self.bookId = bookId
        self.deviceId = deviceId
        self.lastSyncDate = Date()
        self.currentPosition = currentPosition
        self.playbackSpeed = playbackSpeed
        self.currentChapterIndex = currentChapterIndex
        self.lastPlayedDate = lastPlayedDate
    }
}
