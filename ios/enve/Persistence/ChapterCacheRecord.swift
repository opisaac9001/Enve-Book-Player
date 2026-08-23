import Foundation
import SwiftData

@Model
final class ChapterCacheRecord {
    var bookStableId: String = ""
    var chaptersJSON: Data = Data()
    var lastUpdate: Date = Date()

    init() {}

    init(bookStableId: String, chapters: [Chapter]) {
        self.bookStableId = bookStableId
        self.chaptersJSON = (try? JSONEncoder().encode(chapters)) ?? Data()
        self.lastUpdate = Date()
    }

    func toChapters() -> [Chapter]? {
        try? JSONDecoder().decode([Chapter].self, from: chaptersJSON)
    }
}
