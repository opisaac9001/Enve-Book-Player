import Foundation
import SwiftData

@Model
final class LinkedBookPairRecord {
    var ebookStableId: String = ""
    var audiobookStableId: String = ""
    var chapterOffset: Int = 0
    var lastUpdate: Date = Date()

    init() {}

    init(ebookStableId: String, audiobookStableId: String, chapterOffset: Int) {
        self.ebookStableId = ebookStableId
        self.audiobookStableId = audiobookStableId
        self.chapterOffset = chapterOffset
        self.lastUpdate = Date()
    }
}
