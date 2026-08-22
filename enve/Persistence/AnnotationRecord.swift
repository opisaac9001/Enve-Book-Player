import Foundation
import SwiftData

@Model
final class AnnotationRecord {
    var id: String = ""
    var bookStableId: String = ""
    var locator: String?
    var position: Double = 0
    var text: String = ""
    var note: String?
    var colorHex: String = "#FFF59D"
    var style: String = "highlight"
    var chapterTitle: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var remoteID: Int?
    var isRemotePlaceholder: Bool = false

    init() {}

    init(
        id: String,
        bookStableId: String,
        locator: String?,
        position: Double,
        text: String,
        note: String?,
        colorHex: String,
        style: String,
        chapterTitle: String?,
        createdAt: Date,
        updatedAt: Date,
        remoteID: Int?,
        isRemotePlaceholder: Bool
    ) {
        self.id = id
        self.bookStableId = bookStableId
        self.locator = locator
        self.position = position
        self.text = text
        self.note = note
        self.colorHex = colorHex
        self.style = style
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remoteID = remoteID
        self.isRemotePlaceholder = isRemotePlaceholder
    }
}

struct AnnotationSnapshot: Sendable {
    let id: String
    let bookStableId: String
    let locator: String?
    let position: Double
    let text: String
    let note: String?
    let colorHex: String
    let style: String
    let chapterTitle: String?
    let createdAt: Date
    let updatedAt: Date
    let remoteID: Int?
    let isRemotePlaceholder: Bool
}
