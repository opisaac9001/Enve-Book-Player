import Foundation
import Observation

struct JournalNamedCount: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let count: Int
}

struct JournalYearCount: Identifiable, Hashable, Sendable {
    var id: Int { year }
    let year: Int
    let count: Int
}

struct JournalMonthCount: Identifiable, Hashable, Sendable {
    var id: Date { date }
    let date: Date
    let count: Int
}

struct JournalCompletenessStat: Identifiable, Hashable, Sendable {
    var id: String { field }
    let field: String
    let fraction: Double
}

struct JournalLagPoint: Identifiable, Hashable, Sendable {
    var id: Int { index }
    let index: Int
    let publishedYear: Int
    let addedYear: Int
}

struct JournalSeriesProgress: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let finished: Int
    let total: Int
    nonisolated var fraction: Double { total > 0 ? Double(finished) / Double(total) : 0 }
}

struct JournalDurationBook: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let seconds: Double
}

struct JournalLibrarySnapshot: Sendable {
    var totalBooks = 0
    var totalAuthors = 0
    var totalSeries = 0
    var totalPublishers = 0
    var totalGenres = 0
    var totalLanguages = 0
    var earliestYear: Int?
    var latestYear: Int?
    var finishedCount = 0
    var inProgressCount = 0
    var avgProgress = 0.0

    var formatBreakdown: [JournalNamedCount] = []
    var topGenres: [JournalNamedCount] = []
    var languageBreakdown: [JournalNamedCount] = []
    var topAuthors: [JournalNamedCount] = []
    var topSeries: [JournalNamedCount] = []
    var decadeHistogram: [JournalNamedCount] = []
    var pubYearTimeline: [JournalYearCount] = []
    var addedOverTime: [JournalMonthCount] = []
    var completeness: [JournalCompletenessStat] = []
    var acquisitionLag: [JournalLagPoint] = []

    var totalAudioSeconds = 0.0
    var audiobookCount = 0
    var topNarrators: [JournalNamedCount] = []
    var seriesCompletion: [JournalSeriesProgress] = []
    var longestBooks: [JournalDurationBook] = []

    var peakYear: Int?
    var peakYearCount = 0
    var uniqueYears = 0
    var yearSpan = 0
    var avgPerYear = 0
}

@MainActor
@Observable
final class JournalLibraryStatsModel {
    private(set) var snapshot: JournalLibrarySnapshot?
    private(set) var isLoading = false

    private let library: any BookQuerying

    init(library: any BookQuerying = AppState.shared.bookStore) {
        self.library = library
    }

    func load(force: Bool = false) async {
        if snapshot != nil && !force { return }
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        let signpost = PerfSignpost.begin("journal-library-stats")
        defer { PerfSignpost.end(signpost) }
        let slices = await library.bookStatisticsSlices()
        snapshot = await Self.journalCompute(slices)
    }

    nonisolated static func journalCompute(_ books: [BookStatisticsSlice]) async -> JournalLibrarySnapshot {
        var snap = JournalLibrarySnapshot()
        guard !books.isEmpty else { return snap }

        var authors: [String: Int] = [:]
        var series: [String: Int] = [:]
        var seriesFinished: [String: Int] = [:]
        var narrators: [String: Int] = [:]
        var durations: [JournalDurationBook] = []
        var totalAudioSeconds = 0.0
        var audiobookCount = 0
        var publishers: Set<String> = []
        var genres: [String: Int] = [:]
        var languages: [String: Int] = [:]
        var formats: [AppMediaType: Int] = [:]
        var years: [Int: Int] = [:]
        var months: [Date: Int] = [:]

        var hasAuthor = 0
        var hasGenre = 0
        var hasSeries = 0
        var hasPublisher = 0
        var hasYear = 0
        var hasLanguage = 0
        var hasISBN = 0
        var hasCover = 0
        var finished = 0
        var inProgress = 0
        var progressSum = 0.0
        var progressCount = 0
        var lag: [JournalLagPoint] = []
        let calendar = Calendar(identifier: .gregorian)

        for book in books {
            formats[book.mediaType, default: 0] += 1
            if book.mediaType == .audiobook { audiobookCount += 1 }

            if let duration = book.duration, duration > 0 {
                if book.mediaType == .audiobook { totalAudioSeconds += duration }
                durations.append(JournalDurationBook(id: book.id, title: book.title, seconds: duration))
            }

            if let author = book.author?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
                authors[author, default: 0] += 1
                hasAuthor += 1
            }
            if let narrator = book.narrator?.trimmingCharacters(in: .whitespacesAndNewlines), !narrator.isEmpty {
                narrators[narrator, default: 0] += 1
            }
            if let name = book.series?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                series[name, default: 0] += 1
                if book.isFinished { seriesFinished[name, default: 0] += 1 }
                hasSeries += 1
            }
            if let publisher = book.publisher?.trimmingCharacters(in: .whitespacesAndNewlines), !publisher.isEmpty {
                publishers.insert(publisher)
                hasPublisher += 1
            }
            if let bookGenres = book.genres, !bookGenres.isEmpty {
                var counted = false
                for genre in bookGenres {
                    let key = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { continue }
                    genres[key, default: 0] += 1
                    counted = true
                }
                if counted { hasGenre += 1 }
            }
            if let language = book.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
                languages[language.uppercased(), default: 0] += 1
                hasLanguage += 1
            }
            if let isbn = book.isbn, !isbn.isEmpty { hasISBN += 1 }
            if let thumb = book.thumb, !thumb.isEmpty { hasCover += 1 }

            if let year = book.publishedYear, year > 0 {
                years[year, default: 0] += 1
                hasYear += 1
                if let added = book.addedAt, lag.count < 500 {
                    let addedYear = calendar.component(.year, from: added)
                    lag.append(JournalLagPoint(index: lag.count, publishedYear: year, addedYear: addedYear))
                }
            }
            if let added = book.addedAt {
                let comps = calendar.dateComponents([.year, .month], from: added)
                if let monthStart = calendar.date(from: comps) {
                    months[monthStart, default: 0] += 1
                }
            }

            if book.isFinished {
                finished += 1
                progressSum += 1
                progressCount += 1
            } else {
                let frac = book.progress
                if frac > 0 {
                    inProgress += 1
                    progressSum += frac
                    progressCount += 1
                }
            }
        }

        snap.totalBooks = books.count
        snap.totalAuthors = authors.count
        snap.totalSeries = series.count
        snap.totalPublishers = publishers.count
        snap.totalGenres = genres.count
        snap.totalLanguages = languages.count
        snap.finishedCount = finished
        snap.inProgressCount = inProgress
        snap.avgProgress = progressCount > 0 ? progressSum / Double(progressCount) : 0

        snap.formatBreakdown =
            formats
            .map { JournalNamedCount(label: journalFormatLabel($0.key), count: $0.value) }
            .sorted { $0.count > $1.count }
        snap.topGenres = journalTopN(genres, 15)
        snap.languageBreakdown = journalTopN(languages, 10)
        snap.topAuthors = journalTopN(authors, 20)
        snap.topSeries = journalTopN(series, 20)
        snap.topNarrators = journalTopN(narrators, 15)

        snap.totalAudioSeconds = totalAudioSeconds
        snap.audiobookCount = audiobookCount
        snap.longestBooks = durations.sorted { $0.seconds > $1.seconds }.prefix(10).map { $0 }
        snap.seriesCompletion =
            series
            .compactMap { name, total -> JournalSeriesProgress? in
                guard total >= 2 else { return nil }
                return JournalSeriesProgress(name: name, finished: seriesFinished[name] ?? 0, total: total)
            }
            .sorted { ($0.fraction, $0.total) > ($1.fraction, $1.total) }
            .prefix(20)
            .map { $0 }

        let yearKeys = years.keys
        snap.earliestYear = yearKeys.min()
        snap.latestYear = yearKeys.max()
        if let lo = snap.earliestYear, let hi = snap.latestYear {
            snap.pubYearTimeline = (lo...hi).map { JournalYearCount(year: $0, count: years[$0] ?? 0) }
            snap.uniqueYears = years.count
            snap.yearSpan = hi - lo + 1
            let totalWithYear = years.values.reduce(0, +)
            snap.avgPerYear = snap.uniqueYears > 0 ? totalWithYear / snap.uniqueYears : 0
            if let peak = years.max(by: { $0.value < $1.value }) {
                snap.peakYear = peak.key
                snap.peakYearCount = peak.value
            }
            snap.decadeHistogram = journalDecadeBins(years, low: lo, high: hi)
        }

        snap.addedOverTime =
            months
            .map { JournalMonthCount(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }

        let n = Double(books.count)
        snap.completeness = [
            JournalCompletenessStat(field: "Cover", fraction: Double(hasCover) / n),
            JournalCompletenessStat(field: "Author", fraction: Double(hasAuthor) / n),
            JournalCompletenessStat(field: "Genre", fraction: Double(hasGenre) / n),
            JournalCompletenessStat(field: "Year", fraction: Double(hasYear) / n),
            JournalCompletenessStat(field: "Language", fraction: Double(hasLanguage) / n),
            JournalCompletenessStat(field: "Publisher", fraction: Double(hasPublisher) / n),
            JournalCompletenessStat(field: "Series", fraction: Double(hasSeries) / n),
            JournalCompletenessStat(field: "ISBN", fraction: Double(hasISBN) / n),
        ]
        snap.acquisitionLag = lag

        return snap
    }

    private nonisolated static func journalFormatLabel(_ type: AppMediaType) -> String {
        switch type {
        case .audiobook: "Audiobooks"
        case .ebook: "Books"
        case .podcast: "Podcasts"
        }
    }

    private nonisolated static func journalTopN(_ dict: [String: Int], _ n: Int) -> [JournalNamedCount] {
        dict.map { JournalNamedCount(label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(n)
            .map { $0 }
    }

    private nonisolated static func journalDecadeBins(_ years: [Int: Int], low: Int, high: Int) -> [JournalNamedCount] {
        let firstDecade = (low / 10) * 10
        let lastDecade = (high / 10) * 10
        var bins: [JournalNamedCount] = []
        var decade = firstDecade
        while decade <= lastDecade {
            let count = (decade..<(decade + 10)).reduce(0) { $0 + (years[$1] ?? 0) }
            bins.append(JournalNamedCount(label: "\(decade)s", count: count))
            decade += 10
        }
        return bins
    }
}
