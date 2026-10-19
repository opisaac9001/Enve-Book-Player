import Foundation

nonisolated struct ComicSeriesVolume: Identifiable, Equatable, Sendable {
    let id: String
    let title: String?
    let order: Double?
    let books: [Book]

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let order { return "Volume \(order.formatted())" }
        return "Volume"
    }
}

nonisolated struct ComicSeriesSectionGroup: Identifiable, Equatable, Sendable {
    let section: ComicSection
    let looseBooks: [Book]
    let volumes: [ComicSeriesVolume]

    var id: ComicSection { section }

    var bookCount: Int {
        looseBooks.count + volumes.reduce(0) { $0 + $1.books.count }
    }

    var orderedBooks: [Book] {
        looseBooks + volumes.flatMap(\.books)
    }
}

nonisolated struct ComicSeriesGrouping: Equatable, Sendable {
    let sections: [ComicSeriesSectionGroup]

    init(books: [Book]) {
        struct VolumeAccumulator {
            let volumeID: String
            var title: String?
            var order: Double?
            var books: [(offset: Int, book: Book)] = []
        }
        struct SectionAccumulator {
            var loose: [(offset: Int, book: Book)] = []
            var volumes: [String: VolumeAccumulator] = [:]
        }

        var seen = Set<String>()
        var accumulators: [ComicSection: SectionAccumulator] = [:]
        for (offset, book) in books.enumerated() where seen.insert(book.uniqueId).inserted {
            let metadata = book.comicMetadata
            let section = metadata?.section ?? .issues
            var accumulator = accumulators[section, default: SectionAccumulator()]
            if let volumeID = metadata?.volumeID {
                var volume = accumulator.volumes[volumeID, default: VolumeAccumulator(volumeID: volumeID)]
                if volume.title == nil { volume.title = metadata?.volumeTitle }
                if volume.order == nil { volume.order = metadata?.volumeOrder }
                volume.books.append((offset, book))
                accumulator.volumes[volumeID] = volume
            } else {
                accumulator.loose.append((offset, book))
            }
            accumulators[section] = accumulator
        }

        sections = accumulators
            .sorted { $0.key.sortOrder < $1.key.sortOrder }
            .map { entry in
                let section = entry.key
                let accumulator = entry.value
                let volumes = accumulator.volumes.values
                    .sorted { lhs, rhs in
                        switch (lhs.order, rhs.order) {
                        case let (l?, r?) where l != r: return l < r
                        case (_?, nil): return true
                        case (nil, _?): return false
                        default:
                            let lhsFirst = lhs.books.first?.offset ?? 0
                            let rhsFirst = rhs.books.first?.offset ?? 0
                            return lhsFirst < rhsFirst
                        }
                    }
                    .map {
                        ComicSeriesVolume(
                            id: "\(section.rawValue)/\($0.volumeID)",
                            title: $0.title,
                            order: $0.order,
                            books: Self.issueOrdered($0.books)
                        )
                    }
                return ComicSeriesSectionGroup(
                    section: section,
                    looseBooks: Self.issueOrdered(accumulator.loose),
                    volumes: volumes
                )
            }
    }

    var bookCount: Int {
        sections.reduce(0) { $0 + $1.bookCount }
    }

    var orderedBooks: [Book] {
        sections.flatMap(\.orderedBooks)
    }

    var nextUnread: Book? {
        orderedBooks.first { !$0.isCompleted }
    }

    // Unnumbered entries keep the server's order after the numbered ones.
    private static func issueOrdered(_ books: [(offset: Int, book: Book)]) -> [Book] {
        books
            .sorted { lhs, rhs in
                switch (lhs.book.comicMetadata?.issueOrder, rhs.book.comicMetadata?.issueOrder) {
                case let (l?, r?) where l != r: return l < r
                case (_?, nil): return true
                case (nil, _?): return false
                default: return lhs.offset < rhs.offset
                }
            }
            .map(\.book)
    }
}

nonisolated enum ComicSeriesFormat {
    static func issueCount(_ count: Int) -> String {
        count == 1 ? "1 issue" : "\(count.formatted()) issues"
    }

    static func summary(total: Int, unread: Int) -> String {
        let status = unread == 0 ? "All read" : "\(unread.formatted()) unread"
        return "\(issueCount(total)) · \(status)"
    }
}
