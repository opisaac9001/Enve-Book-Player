import Foundation

struct AudiobookClip: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bookId: String
    let bookmarkId: String
    var startTime: TimeInterval
    var endTime: TimeInterval
    let createdAt: Date
    var transcript: String?

    init(
        id: String,
        bookId: String,
        bookmarkId: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        createdAt: Date = Date(),
        transcript: String? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.bookmarkId = bookmarkId
        self.startTime = startTime
        self.endTime = endTime
        self.createdAt = createdAt
        self.transcript = transcript
    }

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}
