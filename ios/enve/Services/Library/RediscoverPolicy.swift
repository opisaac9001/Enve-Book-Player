import Foundation

nonisolated struct RediscoverPick: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case paused(days: Int)
        case waiting
        case nextInSeries

        var label: String {
            switch self {
            case .paused(let days):
                let weeks = days / 7
                if weeks < 9 { return weeks == 1 ? "Paused 1 week" : "Paused \(weeks) weeks" }
                let months = days / 30
                return months < 12 ? "Paused \(months) months" : "Paused over a year"
            case .waiting:
                return "Waiting on your shelf"
            case .nextInSeries:
                return "Next in series"
            }
        }

        var glyph: String {
            switch self {
            case .paused: "pause.circle"
            case .waiting: "books.vertical"
            case .nextInSeries: "arrow.forward.circle"
            }
        }
    }

    let book: Book
    let reason: Reason

    var id: String { book.stableId }
}

nonisolated enum RediscoverPolicy {
    struct Exclusions: Sendable {
        var stableIds: Set<String> = []
        var libraryKeys: Set<String> = []
    }

    static let pausedDays = 21
    static let waitingDays = 30
    static let defaultLimit = 8

    static func picks(
        from books: [Book],
        now: Date,
        calendar: Calendar,
        exclusions: Exclusions = Exclusions(),
        limit: Int = defaultLimit
    ) -> [RediscoverPick] {
        let pool = books.filter { isEligible($0, exclusions: exclusions) }
        // Finished or started copies of a work keep its other formats and sources from resurfacing as unread.
        let engagedKeys = Set(books.filter { isStarted($0) || isCompleted($0) }.flatMap(crossFormatKeys))
        let pausedCutoff = calendar.date(byAdding: .day, value: -pausedDays, to: now) ?? now
        let waitingCutoff = calendar.date(byAdding: .day, value: -waitingDays, to: now) ?? now

        var paused: [RediscoverPick] = []
        var waiting: [RediscoverPick] = []
        for book in pool where !isCompleted(book) {
            if isStarted(book) {
                guard !book.hideFromContinue, book.lastUpdate <= pausedCutoff else { continue }
                let days = calendar.dateComponents([.day], from: book.lastUpdate, to: now).day ?? pausedDays
                paused.append(RediscoverPick(book: book, reason: .paused(days: days)))
            } else if let addedAt = book.addedAt, addedAt <= waitingCutoff,
                engagedKeys.isDisjoint(with: crossFormatKeys(book))
            {
                waiting.append(RediscoverPick(book: book, reason: .waiting))
            }
        }
        let series = nextInSeries(pool, engagedKeys: engagedKeys).map { RediscoverPick(book: $0, reason: .nextInSeries) }
        let seriesIds = Set(series.map(\.id))
        waiting.removeAll { seriesIds.contains($0.id) }

        let day = calendar.ordinality(of: .day, in: .era, for: now) ?? 0
        let buckets = [series, paused, waiting].map { dailyOrder($0, day: day) }
        return interleave(buckets, limit: limit)
    }

    private static func isEligible(_ book: Book, exclusions: Exclusions) -> Bool {
        (book.mediaType == .audiobook || book.mediaType == .ebook)
            && !book.isPodcastEpisode
            && !book.isComic
            && !book.isReadAloudBook
            && !exclusions.stableIds.contains(book.stableId)
            && !exclusions.libraryKeys.contains("\(book.providerId.uuidString)_\(book.libraryId)")
    }

    static func isStarted(_ book: Book) -> Bool {
        book.mediaType == .ebook ? book.canonicalEbookProgress > 0.001 : book.currentTime > 0
    }

    static func isCompleted(_ book: Book) -> Bool {
        book.isCompleted || book.canonicalProgress >= Book.finishedProgressThreshold
    }

    private static func nextInSeries(_ pool: [Book], engagedKeys: Set<String>) -> [Book] {
        var groups: [String: [(number: Double, book: Book)]] = [:]
        for book in pool {
            guard let series = book.series, let number = seriesNumber(book) else { continue }
            guard !TextNormalizer.normalizeSeries(series).isEmpty else { continue }
            let key = seriesKey(book)
            groups[key, default: []].append((number, book))
        }

        var picks: [Book] = []
        for members in groups.values {
            let finished = members.filter { isCompleted($0.book) }
            guard let last = finished.max(by: { $0.number < $1.number }) else { continue }
            let later = members.filter { $0.number > last.number }
            // Progress past the last finished volume means the reader has already moved on.
            guard !later.contains(where: { isStarted($0.book) || isCompleted($0.book) }),
                let nextNumber = later.map({ $0.number }).min(),
                nextNumber <= last.number.rounded(.down) + 1
            else { continue }
            let candidates = later
                .filter { $0.number == nextNumber && engagedKeys.isDisjoint(with: crossFormatKeys($0.book)) }
                .map { $0.book }
                .sorted { lhs, rhs in
                    let lhsMatches = lhs.mediaType == last.book.mediaType
                    let rhsMatches = rhs.mediaType == last.book.mediaType
                    if lhsMatches != rhsMatches { return lhsMatches }
                    return lhs.stableId < rhs.stableId
                }
            if let next = candidates.first {
                picks.append(next)
            }
        }
        return picks
    }

    private static func seriesNumber(_ book: Book) -> Double? {
        if let sequence = book.seriesSequence?.trimmingCharacters(in: .whitespaces),
            let value = Double(sequence), value > 0
        {
            return value
        }
        if let number = book.seriesNumber, number > 0 { return Double(number) }
        return nil
    }

    private static func dailyOrder(_ picks: [RediscoverPick], day: Int) -> [RediscoverPick] {
        picks
            .map { (score: stableHash("\(day)|\($0.id)"), pick: $0) }
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.pick.id < $1.pick.id }
            .map { $0.pick }
    }

    private static func interleave(_ buckets: [[RediscoverPick]], limit: Int) -> [RediscoverPick] {
        var cursors = Array(repeating: 0, count: buckets.count)
        var usedKeys = Set<String>()
        var result: [RediscoverPick] = []
        while result.count < limit {
            var advanced = false
            for index in buckets.indices where result.count < limit {
                while cursors[index] < buckets[index].count {
                    let pick = buckets[index][cursors[index]]
                    cursors[index] += 1
                    let keys = identityKeys(pick.book)
                    guard usedKeys.isDisjoint(with: keys) else { continue }
                    usedKeys.formUnion(keys)
                    result.append(pick)
                    advanced = true
                    break
                }
            }
            if !advanced { break }
        }
        return result
    }

    private static func identityKeys(_ book: Book) -> Set<String> {
        var keys = Set(crossFormatKeys(book))
        keys.insert("id:\(book.stableId)")
        let work = WorkIdentity.workKey(for: book)
        if !work.isEmpty { keys.insert(work) }
        if book.series != nil, let number = seriesNumber(book) {
            keys.insert("series:\(seriesKey(book))#\(number)")
        }
        return keys
    }

    private static func crossFormatKeys(_ book: Book) -> [String] {
        var keys = ["dedup:\(book.deduplicationKey)", "id:\(book.stableId)"]
        let title = TextNormalizer.normalizeTitle(book.title)
        let author = TextNormalizer.normalizeAuthor(book.canonicalAuthorKey)
        if !title.isEmpty, !author.isEmpty { keys.append("title-author:\(title)|\(author)") }
        if let linked = book.linkedAudiobookStableId { keys.append("id:\(linked)") }
        return keys
    }

    private static func seriesKey(_ book: Book) -> String {
        "\(TextNormalizer.normalizeSeries(book.series ?? ""))|\(TextNormalizer.normalizeAuthor(book.canonicalAuthorKey))"
    }

    // FNV-1a keeps the daily shuffle identical across launches, unlike Hasher.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
