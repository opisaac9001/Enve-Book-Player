import Foundation

public struct VocabEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let bookStableId: String
    public var word: String
    public var sentence: String
    public var sentenceBefore: String
    public var sentenceAfter: String
    public var locator: String?
    public var position: Double
    public var chapterTitle: String?
    public var definitionSnapshot: String?
    public var userNote: String?
    public var lookedUpAt: Date
    public var tags: String
    public var sourceLanguage: String?

    public var studyBox: Int
    public var nextReviewAt: Date?
    public var lastReviewedAt: Date?
    public var reviewStreak: Int

    public init(
        id: String = UUID().uuidString,
        bookStableId: String,
        word: String,
        sentence: String,
        sentenceBefore: String = "",
        sentenceAfter: String = "",
        locator: String? = nil,
        position: Double = 0,
        chapterTitle: String? = nil,
        definitionSnapshot: String? = nil,
        userNote: String? = nil,
        lookedUpAt: Date = Date(),
        tags: String = "",
        sourceLanguage: String? = nil,
        studyBox: Int = 0,
        nextReviewAt: Date? = nil,
        lastReviewedAt: Date? = nil,
        reviewStreak: Int = 0
    ) {
        self.id = id
        self.bookStableId = bookStableId
        self.word = word
        self.sentence = sentence
        self.sentenceBefore = sentenceBefore
        self.sentenceAfter = sentenceAfter
        self.locator = locator
        self.position = position
        self.chapterTitle = chapterTitle
        self.definitionSnapshot = definitionSnapshot
        self.userNote = userNote
        self.lookedUpAt = lookedUpAt
        self.tags = tags
        self.sourceLanguage = sourceLanguage
        self.studyBox = studyBox
        self.nextReviewAt = nextReviewAt
        self.lastReviewedAt = lastReviewedAt
        self.reviewStreak = reviewStreak
    }

    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: lookedUpAt)
    }

    public var isDue: Bool {
        if studyBox >= 5 { return false }
        guard let next = nextReviewAt else { return true }
        return next <= Date()
    }

    public var isNew: Bool { studyBox == 0 && nextReviewAt == nil }
    public var isMastered: Bool { studyBox >= 5 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        bookStableId = try c.decode(String.self, forKey: .bookStableId)
        word = try c.decode(String.self, forKey: .word)
        sentence = try c.decode(String.self, forKey: .sentence)
        sentenceBefore = try c.decodeIfPresent(String.self, forKey: .sentenceBefore) ?? ""
        sentenceAfter = try c.decodeIfPresent(String.self, forKey: .sentenceAfter) ?? ""
        locator = try c.decodeIfPresent(String.self, forKey: .locator)
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        chapterTitle = try c.decodeIfPresent(String.self, forKey: .chapterTitle)
        definitionSnapshot = try c.decodeIfPresent(String.self, forKey: .definitionSnapshot)
        userNote = try c.decodeIfPresent(String.self, forKey: .userNote)
        lookedUpAt = try c.decodeIfPresent(Date.self, forKey: .lookedUpAt) ?? Date()
        tags = try c.decodeIfPresent(String.self, forKey: .tags) ?? ""
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        studyBox = try c.decodeIfPresent(Int.self, forKey: .studyBox) ?? 0
        nextReviewAt = try c.decodeIfPresent(Date.self, forKey: .nextReviewAt)
        lastReviewedAt = try c.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
        reviewStreak = try c.decodeIfPresent(Int.self, forKey: .reviewStreak) ?? 0
    }
}
