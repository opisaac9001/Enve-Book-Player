import Foundation
import SwiftData

@Model
final class MediaProgressRecord {
    var bookUniqueId: String = ""
    var stableId: String = ""
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var ebookProgress: Double?
    var epubLocator: String?
    var isFinished: Bool = false
    var lastUpdate: Date = Date()
    var hideFromContinue: Bool = false

    init() {}

    init(
        bookUniqueId: String,
        stableId: String,
        currentTime: TimeInterval,
        duration: TimeInterval,
        ebookProgress: Double?,
        epubLocator: String?,
        isFinished: Bool,
        lastUpdate: Date,
        hideFromContinue: Bool
    ) {
        self.bookUniqueId = bookUniqueId
        self.stableId = stableId
        self.currentTime = currentTime
        self.duration = duration
        self.ebookProgress = ebookProgress
        self.epubLocator = epubLocator
        self.isFinished = isFinished
        self.lastUpdate = lastUpdate
        self.hideFromContinue = hideFromContinue
    }
}
