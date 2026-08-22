import Foundation
import SwiftData

@Model
final class BookmarkRecord {
    var id: String = ""
    var bookStableId: String = ""
    var title: String = ""
    var position: Double = 0
    var timestamp: Date = Date()
    var note: String?
    var locator: String?
    var mediaType: String = "audiobook"
    var chapterTitle: String?
    var remoteID: Int?
    var isRemotePlaceholder: Bool = false

    init() {}

    init(
        id: String,
        bookStableId: String,
        title: String,
        position: Double,
        timestamp: Date,
        note: String?,
        locator: String?,
        mediaType: String,
        chapterTitle: String?,
        remoteID: Int?,
        isRemotePlaceholder: Bool
    ) {
        self.id = id
        self.bookStableId = bookStableId
        self.title = title
        self.position = position
        self.timestamp = timestamp
        self.note = note
        self.locator = locator
        self.mediaType = mediaType
        self.chapterTitle = chapterTitle
        self.remoteID = remoteID
        self.isRemotePlaceholder = isRemotePlaceholder
    }
}

struct BookmarkSnapshot: Sendable {
    let id: String
    let bookStableId: String
    let title: String
    let position: Double
    let timestamp: Date
    let note: String?
    let locator: String?
    let mediaType: String
    let chapterTitle: String?
    let remoteID: Int?
    let isRemotePlaceholder: Bool
}
