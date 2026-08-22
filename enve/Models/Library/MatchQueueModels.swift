import Foundation

enum MatchQueueStatus: String, Codable, Sendable {
    case pending
    case approved
    case rejected
}

struct AudibleMatchCandidate: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let asin: String
    let title: String
    let author: String
    let narrators: [String]
    let series: String?
    let seriesNumber: String?
    let duration: TimeInterval
    let confidence: Double
    let matchReason: String?
    let coverUrl: String?
    let matchSource: MatchSource?
    let description: String?

    let durationScore: Double?
    let titleScore: Double?
    let authorScore: Double?
}

enum MatchSource: String, Codable, Sendable {
    case enveSearch = "Enve Search"
    case audiobookshelf = "AudioBookshelf"
    case iTunes = "iTunes"
}

struct MatchQueueEntry: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let bookId: String
    let bookPath: String?
    let ratingKey: String?
    let partKey: String?
    let source: Book.BookSource?
    let backendId: String?
    let trackIndex: Int?
    let fileMetadata: FileMetadataLayer
    let matchCandidates: [AudibleMatchCandidate]
    let selectedMatch: AudibleMatchCandidate?
    let status: MatchQueueStatus
    let createdAt: String
    let reviewedAt: String?
    let bookCoverUrl: String?
}

struct MatchQueue: Codable, Equatable, Sendable {
    var entries: [MatchQueueEntry]
    var version: String
    var lastUpdated: String
}

struct BatchMatchResult: Equatable, Sendable {
    let total: Int
    let autoMatched: Int
    let pending: Int
    let skipped: Int
    let errors: Int
    let errorsList: [String]

    init(
        total: Int = 0,
        autoMatched: Int = 0,
        pending: Int = 0,
        skipped: Int = 0,
        errors: Int = 0,
        errorsList: [String] = []
    ) {
        self.total = total
        self.autoMatched = autoMatched
        self.pending = pending
        self.skipped = skipped
        self.errors = errors
        self.errorsList = errorsList
    }
}

extension AudibleMatchCandidate {
    init(
        asin: String,
        title: String,
        author: String,
        narrators: [String] = [],
        series: String? = nil,
        seriesNumber: String? = nil,
        duration: TimeInterval,
        confidence: Double,
        matchReason: String? = nil,
        coverUrl: String? = nil,
        matchSource: MatchSource? = .enveSearch,
        description: String? = nil,
        durationScore: Double? = nil,
        titleScore: Double? = nil,
        authorScore: Double? = nil
    ) {
        self.id = asin
        self.asin = asin
        self.title = title
        self.author = author
        self.narrators = narrators
        self.series = series
        self.seriesNumber = seriesNumber
        self.duration = duration
        self.confidence = confidence
        self.matchReason = matchReason
        self.coverUrl = coverUrl
        self.matchSource = matchSource
        self.description = description
        self.durationScore = durationScore
        self.titleScore = titleScore
        self.authorScore = authorScore
    }
}

extension MatchQueueEntry {
    init(
        id: String = UUID().uuidString,
        bookId: String,
        bookPath: String? = nil,
        ratingKey: String? = nil,
        partKey: String? = nil,
        source: Book.BookSource? = nil,
        backendId: String? = nil,
        trackIndex: Int? = nil,
        fileMetadata: FileMetadataLayer,
        matchCandidates: [AudibleMatchCandidate],
        selectedMatch: AudibleMatchCandidate? = nil,
        status: MatchQueueStatus = .pending,
        createdAt: String? = nil,
        reviewedAt: String? = nil,
        bookCoverUrl: String? = nil
    ) {
        self.id = id
        self.bookId = bookId
        self.bookPath = bookPath
        self.ratingKey = ratingKey
        self.partKey = partKey
        self.source = source
        self.backendId = backendId
        self.trackIndex = trackIndex
        self.fileMetadata = fileMetadata
        self.matchCandidates = matchCandidates
        self.selectedMatch = selectedMatch
        self.status = status
        self.createdAt = createdAt ?? ISO8601DateFormatter().string(from: Date())
        self.reviewedAt = reviewedAt
        self.bookCoverUrl = bookCoverUrl
    }
}

extension MatchQueue {
    init(entries: [MatchQueueEntry] = [], version: String = "1.0", lastUpdated: String? = nil) {
        self.entries = entries
        self.version = version
        self.lastUpdated = lastUpdated ?? ISO8601DateFormatter().string(from: Date())
    }
}
