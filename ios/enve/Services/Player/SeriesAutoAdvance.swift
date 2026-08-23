import Foundation

enum SeriesAutoAdvancePolicy {
    static func nextBook(after finished: Book, in seriesBooks: [Book]) -> Book? {
        guard let currentSequence = sequenceValue(of: finished) else { return nil }

        return
            seriesBooks
            .filter {
                $0.uniqueId != finished.uniqueId
                    && $0.mediaType == .audiobook
                    && !PlaybackQueuePolicy.isFinished($0)
            }
            .compactMap { book -> (Double, Book)? in
                guard let sequence = sequenceValue(of: book), sequence > currentSequence else { return nil }
                return (sequence, book)
            }
            .min { $0.0 < $1.0 }?
            .1
    }

    static func sequenceValue(of book: Book) -> Double? {
        if let raw = book.seriesInfo?.sequence, let value = Double(raw) { return value }
        if let number = book.seriesNumber { return Double(number) }
        return nil
    }
}
