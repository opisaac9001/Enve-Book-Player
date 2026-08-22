import Foundation

struct BookNotesPayload: Sendable, Codable, Equatable {
    struct BookMeta: Sendable, Codable, Equatable {
        var id: String
        var title: String
        var authors: [String]
        var narrator: String?
        var series: String?
        var seriesNumber: String?
        var publishedYear: Int?
        var publisher: String?
        var isbn: String?
        var asin: String?
        var language: String?
        var genres: [String]
        var mediaType: String
        var coverPath: String?
        var progress: Double
    }

    struct HighlightItem: Sendable, Codable, Equatable {
        var id: String
        var text: String
        var note: String?
        var colorHex: String
        var style: String
        var position: Double
        var chapterTitle: String?
        var createdAt: Date
        var updatedAt: Date
    }

    struct AudiobookNote: Sendable, Codable, Equatable {
        var id: String
        var title: String
        var note: String?
        var timestampSeconds: Double
        var formattedTime: String
        var chapterTitle: String?
        var createdAt: Date
    }

    struct EbookBookmarkItem: Sendable, Codable, Equatable {
        var id: String
        var title: String
        var chapterTitle: String?
        var progress: Double
        var note: String?
        var createdAt: Date
    }

    var book: BookMeta
    var highlights: [HighlightItem]
    var audiobookNotes: [AudiobookNote]
    var ebookBookmarks: [EbookBookmarkItem]
    var chapters: [String]
    var exportedAt: Date
    var lastSyncedAt: Date?
}

extension BookNotesPayload {
    var jsonData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}
