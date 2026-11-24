import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func vocabEntries(forBookStableId sid: String) async -> [VocabEntry] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchVocabEntries(forBookStableId: sid)
            return snapshots.map { entryFromSnapshot($0) }
        } catch {
            AppLogger.general.error("BookStore.vocabEntries failed: \(error)")
            return []
        }
    }

    func allVocabEntries() async -> [VocabEntry] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchAllVocabEntries()
            return snapshots.map { entryFromSnapshot($0) }
        } catch {
            AppLogger.general.error("BookStore.allVocabEntries failed: \(error)")
            return []
        }
    }

    func upsertVocabEntry(_ entry: VocabEntry) async {
        guard !entry.id.isEmpty, !entry.bookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertVocabEntry: rejecting empty entry id or bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertVocabEntryRecord(
                id: entry.id,
                bookStableId: entry.bookStableId,
                word: entry.word,
                sentence: entry.sentence,
                sentenceBefore: entry.sentenceBefore,
                sentenceAfter: entry.sentenceAfter,
                locator: entry.locator,
                position: entry.position,
                chapterTitle: entry.chapterTitle,
                definitionSnapshot: entry.definitionSnapshot,
                userNote: entry.userNote,
                lookedUpAt: entry.lookedUpAt,
                tags: entry.tags,
                sourceLanguage: entry.sourceLanguage,
                studyBox: entry.studyBox,
                nextReviewAt: entry.nextReviewAt,
                lastReviewedAt: entry.lastReviewedAt,
                reviewStreak: entry.reviewStreak
            )
        } catch {
            AppLogger.general.error("BookStore.upsertVocabEntry failed: \(error)")
        }
    }

    func deleteVocabEntry(id: String) async {
        guard !id.isEmpty else {
            AppLogger.general.error("BookStore.deleteVocabEntry: rejecting empty id")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.deleteVocabEntryRecord(id: id)
        } catch {
            AppLogger.general.error("BookStore.deleteVocabEntry failed: \(error)")
        }
    }

    private func entryFromSnapshot(_ s: VocabEntrySnapshot) -> VocabEntry {
        VocabEntry(
            id: s.id,
            bookStableId: s.bookStableId,
            word: s.word,
            sentence: s.sentence,
            sentenceBefore: s.sentenceBefore,
            sentenceAfter: s.sentenceAfter,
            locator: s.locator,
            position: s.position,
            chapterTitle: s.chapterTitle,
            definitionSnapshot: s.definitionSnapshot,
            userNote: s.userNote,
            lookedUpAt: s.lookedUpAt,
            tags: s.tags,
            sourceLanguage: s.sourceLanguage,
            studyBox: s.studyBox,
            nextReviewAt: s.nextReviewAt,
            lastReviewedAt: s.lastReviewedAt,
            reviewStreak: s.reviewStreak
        )
    }
}

extension SwiftDataBookStore.Worker {
    func fetchVocabEntries(forBookStableId sid: String) throws -> [VocabEntrySnapshot] {
        let descriptor = FetchDescriptor<VocabEntryRecord>(
            predicate: #Predicate { $0.bookStableId == sid },
            sortBy: [SortDescriptor(\.lookedUpAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { snap($0) }
    }

    func fetchAllVocabEntries() throws -> [VocabEntrySnapshot] {
        let descriptor = FetchDescriptor<VocabEntryRecord>(
            sortBy: [SortDescriptor(\.lookedUpAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map { snap($0) }
    }

    private func snap(_ r: VocabEntryRecord) -> VocabEntrySnapshot {
        VocabEntrySnapshot(
            id: r.id,
            bookStableId: r.bookStableId,
            word: r.word,
            sentence: r.sentence,
            sentenceBefore: r.sentenceBefore,
            sentenceAfter: r.sentenceAfter,
            locator: r.locator,
            position: r.position,
            chapterTitle: r.chapterTitle,
            definitionSnapshot: r.definitionSnapshot,
            userNote: r.userNote,
            lookedUpAt: r.lookedUpAt,
            tags: r.tags,
            sourceLanguage: r.sourceLanguage,
            studyBox: r.studyBox,
            nextReviewAt: r.nextReviewAt,
            lastReviewedAt: r.lastReviewedAt,
            reviewStreak: r.reviewStreak
        )
    }

    func upsertVocabEntryRecord(
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
        studyBox: Int,
        nextReviewAt: Date?,
        lastReviewedAt: Date?,
        reviewStreak: Int
    ) throws {
        let vid = id
        var descriptor = FetchDescriptor<VocabEntryRecord>(
            predicate: #Predicate { $0.id == vid }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.word = word
            existing.sentence = sentence
            existing.sentenceBefore = sentenceBefore
            existing.sentenceAfter = sentenceAfter
            existing.locator = locator
            existing.position = position
            existing.chapterTitle = chapterTitle
            existing.definitionSnapshot = definitionSnapshot
            existing.userNote = userNote
            existing.tags = tags
            existing.sourceLanguage = sourceLanguage
            existing.studyBox = studyBox
            existing.nextReviewAt = nextReviewAt
            existing.lastReviewedAt = lastReviewedAt
            existing.reviewStreak = reviewStreak
        } else {
            modelContext.insert(
                VocabEntryRecord(
                    id: id,
                    bookStableId: bookStableId,
                    word: word,
                    sentence: sentence,
                    sentenceBefore: sentenceBefore,
                    sentenceAfter: sentenceAfter,
                    locator: locator,
                    position: position,
                    chapterTitle: chapterTitle,
                    definitionSnapshot: definitionSnapshot,
                    userNote: userNote,
                    lookedUpAt: lookedUpAt,
                    tags: tags,
                    sourceLanguage: sourceLanguage,
                    studyBox: studyBox,
                    nextReviewAt: nextReviewAt,
                    lastReviewedAt: lastReviewedAt,
                    reviewStreak: reviewStreak
                )
            )
        }
        try modelContext.save()
    }

    func deleteVocabEntryRecord(id vid: String) throws {
        var descriptor = FetchDescriptor<VocabEntryRecord>(
            predicate: #Predicate { $0.id == vid }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
        }
        try modelContext.save()
    }
}
