import Foundation

struct ReaderSessionSnapshot: Equatable {
    var progress: Double?
    var visiblePageRange: ClosedRange<Int>?
    var sectionTitle: String?
    var tocEntryId: String?
    var minutesLeftInChapter: Int?
    var minutesLeftInBook: Int?
    var readingSpeedDisplay: String?
}
