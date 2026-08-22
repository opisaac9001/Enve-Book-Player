import Foundation
import SwiftData

@Model
final class VocabEntryRecord {
    var id: String = ""
    var bookStableId: String = ""
    var word: String = ""
    var sentence: String = ""
    var sentenceBefore: String = ""
    var sentenceAfter: String = ""
    var locator: String?
    var position: Double = 0
    var chapterTitle: String?
    var definitionSnapshot: String?
    var userNote: String?
    var lookedUpAt: Date = Date()
    var tags: String = ""
    var sourceLanguage: String?

    var studyBox: Int = 0
    var nextReviewAt: Date?
    var lastReviewedAt: Date?
    var reviewStreak: Int = 0

    init() {}

    init(
        id: String,
        bookStableId: String,
        word: String,
        sentence: String,
        sentenceBefore: String,
        sentenceAfter: String,
        locator: String?,
        position: Double,
        chapterTitle: String?,
        definitionSnapshot: String?,
        userNote: String?,
        lookedUpAt: Date,
        tags: String,
        sourceLanguage: String?,
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
}

struct VocabEntrySnapshot: Sendable {
    let id: String
    let bookStableId: String
    let word: String
    let sentence: String
    let sentenceBefore: String
    let sentenceAfter: String
    let locator: String?
    let position: Double
    let chapterTitle: String?
    let definitionSnapshot: String?
    let userNote: String?
    let lookedUpAt: Date
    let tags: String
    let sourceLanguage: String?
    let studyBox: Int
    let nextReviewAt: Date?
    let lastReviewedAt: Date?
    let reviewStreak: Int
}
