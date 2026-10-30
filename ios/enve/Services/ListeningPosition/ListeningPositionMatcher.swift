import Foundation

struct ListeningPositionCandidate: Identifiable, Equatable, Sendable {
    enum Signal: Equatable, Sendable {
        case sameIdentifier
        case sameTitle
        case sameAuthor
        case sameLength
        case sameNarrator
    }

    enum Warning: Equatable, Sendable {
        case titleDiffers
        case authorDiffers
        case lengthDiffers(minutes: Int)
        case lengthUnknown
        case narratorDiffers
        case seriesPositionDiffers
        case positionBeyondEnd
        case formatDiffers
        case pageCountDiffers
    }

    let book: Book
    /// Ordering weight only; it is not a calibrated probability and is never shown as one.
    let score: Double
    let hasCredibleIdentity: Bool
    let signals: [Signal]
    let warnings: [Warning]

    var id: String { book.uniqueId }
    var canApply: Bool { !warnings.contains(.positionBeyondEnd) }
}

// Title, authors and identifiers establish identity; recording metadata ranks matching copies.
enum ListeningPositionMatcher {
    static let credibleTitleScore = 0.85
    static let credibleAuthorScore = 0.8
    static let lengthToleranceSeconds: TimeInterval = 120

    private static func mediaTypes(for payload: ListeningPositionPayload) -> [String] {
        payload.readingLocation == nil ? [AppMediaType.audiobook.rawValue, AppMediaType.podcast.rawValue] : [AppMediaType.ebook.rawValue]
    }

    static func suggestions(for payload: ListeningPositionPayload, in store: any BookQuerying) async -> [ListeningPositionCandidate] {
        var books: [Book] = []
        for mediaType in mediaTypes(for: payload) {
            books += await store.searchBooks(query: titleNeedle(payload.title), mediaType: mediaType, limit: 60)
            if let word = longestTitleWord(payload.title) {
                books += await store.searchBooks(query: word, mediaType: mediaType, limit: 60)
            }
            if !payload.authors.isEmpty {
                books += await store.books(byAuthorNames: payload.authors, mediaType: mediaType, limit: 120)
            }
            if let series = payload.series {
                books += await store.books(bySeriesNames: [series], mediaType: mediaType, limit: 60)
            }
        }
        return rank(books, for: payload).filter(\.hasCredibleIdentity)
    }

    // Manual selection includes copies below the suggestion threshold.
    static func search(_ query: String, for payload: ListeningPositionPayload, in store: any BookQuerying) async -> [ListeningPositionCandidate] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var books: [Book] = []
        for mediaType in mediaTypes(for: payload) {
            books += await store.searchBooks(query: needle, mediaType: mediaType, limit: 100)
        }
        return rank(books, for: payload)
    }

    static func rank(_ books: [Book], for payload: ListeningPositionPayload) -> [ListeningPositionCandidate] {
        var seen = Set<String>()
        return books
            .filter { mediaTypes(for: payload).contains($0.mediaType.rawValue) && seen.insert($0.uniqueId).inserted }
            .map { evaluate($0, against: payload) }
            .sorted {
                if $0.hasCredibleIdentity != $1.hasCredibleIdentity { return $0.hasCredibleIdentity }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.book.title.localizedStandardCompare($1.book.title) == .orderedAscending
            }
    }

    static func evaluate(_ book: Book, against payload: ListeningPositionPayload) -> ListeningPositionCandidate {
        var signals: [ListeningPositionCandidate.Signal] = []
        var warnings: [ListeningPositionCandidate.Warning] = []

        let identifierMatches =
            (payload.asin != nil && book.asin.flatMap(ListeningPositionPayload.normalizedASIN) == payload.asin)
            || (payload.isbn != nil && book.isbn.flatMap(ListeningPositionPayload.normalizedISBN) == payload.isbn)
        if identifierMatches { signals.append(.sameIdentifier) }

        let sharedIdentity = CanonicalBookIdentity(title: payload.title, author: payload.authors.first, duration: payload.duration)
        let localIdentity = CanonicalBookIdentity(title: book.title, author: nil, duration: book.duration)
        let titleScore =
            sharedIdentity.normalizedTitle == localIdentity.normalizedTitle && !localIdentity.normalizedTitle.isEmpty
            ? 1
            // Score both directions so a subtitle on either side is dropped before comparing.
            : max(
                MatchingUtils.calculateTitleScore(queryTitle: payload.title, bookTitle: book.title),
                MatchingUtils.calculateTitleScore(queryTitle: book.title, bookTitle: payload.title)
            )
        if titleScore >= credibleTitleScore { signals.append(.sameTitle) }

        let bookAuthors = book.authors.flatMap { $0.isEmpty ? nil : $0 } ?? [book.author].compactMap { $0 }
        let authorsKnown = !payload.authors.isEmpty && !bookAuthors.isEmpty
        let authorScore =
            authorsKnown
            ? payload.authors.map { MatchingUtils.calculateAuthorScore(queryAuthor: $0, bookAuthors: bookAuthors) }.max() ?? 0
            : 0.5
        if authorsKnown && authorScore >= credibleAuthorScore { signals.append(.sameAuthor) }

        let hasCredibleIdentity =
            identifierMatches || (titleScore >= credibleTitleScore && (!authorsKnown || authorScore >= credibleAuthorScore))
        if !hasCredibleIdentity {
            if titleScore < credibleTitleScore { warnings.append(.titleDiffers) }
            if authorsKnown && authorScore < credibleAuthorScore { warnings.append(.authorDiffers) }
        }

        let lengthScore: Double
        var narratorScore = 0.5
        if let reading = payload.readingLocation {
            lengthScore = 0
            let format = ListeningPositionReadingLocation.format(for: book)
            if reading.format != format { warnings.append(.formatDiffers) }
            if reading.format == format, let count = ListeningPositionReadingLocation.pageCount(for: book) {
                if let sharedCount = reading.pageCount, sharedCount != count { warnings.append(.pageCountDiffers) }
                if let page = reading.page, page > count { warnings.append(.positionBeyondEnd) }
            }
        } else {
            let localDuration = book.duration ?? 0
            if localDuration > 0 {
                lengthScore = MatchingUtils.calculateDurationScore(
                    localDurationSeconds: payload.duration,
                    audibleDurationSeconds: localDuration
                )
                let difference = abs(localDuration - payload.duration)
                if difference <= lengthToleranceSeconds {
                    signals.append(.sameLength)
                } else {
                    warnings.append(.lengthDiffers(minutes: max(1, Int((difference / 60).rounded()))))
                }
                if payload.position > localDuration { warnings.append(.positionBeyondEnd) }
            } else {
                lengthScore = MatchScore.DEFAULT_DURATION_SCORE_MISSING_INFO
                warnings.append(.lengthUnknown)
            }
            if let narrator = book.narrator, !narrator.isEmpty, !payload.narrators.isEmpty {
                let localNarrators = narrator.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "&" }).map(String.init)
                let best = payload.narrators.map { MatchingUtils.calculateAuthorScore(queryAuthor: $0, bookAuthors: localNarrators) }.max() ?? 0
                if best >= credibleAuthorScore {
                    narratorScore = 1
                    signals.append(.sameNarrator)
                } else {
                    narratorScore = 0
                    warnings.append(.narratorDiffers)
                }
            }
        }

        var seriesPenalty = 0.0
        if let sharedSeries = payload.series, let sharedSequence = payload.seriesSequence,
            let localSeries = book.series, let localSequence = book.seriesSequence ?? book.seriesNumber.map(String.init),
            MatchingUtils.normalize(sharedSeries) == MatchingUtils.normalize(localSeries),
            sequenceValue(sharedSequence) != sequenceValue(localSequence)
        {
            seriesPenalty = 0.3
            warnings.append(.seriesPositionDiffers)
        }

        let weighted = payload.readingLocation == nil
            ? 0.55 * titleScore + 0.25 * authorScore + 0.15 * lengthScore + 0.05 * narratorScore
            : 0.7 * titleScore + 0.3 * authorScore
        let score = min(1, max(0, weighted + (identifierMatches ? 0.2 : 0) - seriesPenalty))

        return ListeningPositionCandidate(
            book: book,
            score: score,
            hasCredibleIdentity: hasCredibleIdentity,
            signals: signals,
            warnings: warnings
        )
    }

    // The store matches a lowercased substring of the raw metadata, so keep punctuation and diacritics.
    private static func titleNeedle(_ title: String) -> String {
        var core = title
        if let colon = core.firstIndex(of: ":") {
            core = String(core[..<colon])
        } else if let dash = core.range(of: " - ") {
            core = String(core[..<dash.lowerBound])
        }
        return core.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func longestTitleWord(_ title: String) -> String? {
        let words = title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let word = words.max(by: { $0.count < $1.count }).map(String.init),
            word.count >= 4, word != titleNeedle(title)
        else { return nil }
        return word
    }

    private static func sequenceValue(_ sequence: String) -> String {
        let trimmed = sequence.trimmingCharacters(in: .whitespaces)
        return Double(trimmed).map { String($0) } ?? trimmed.lowercased()
    }
}
