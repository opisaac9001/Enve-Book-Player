package com.enve.app.data.repository

import com.enve.core.data.model.VocabEntry
import com.enve.core.data.model.VocabEntryDao
import com.enve.core.data.vocab.LeitnerScheduler
import kotlinx.coroutines.flow.Flow
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class VocabRepository @Inject constructor(
    private val dao: VocabEntryDao,
) {
    val all: Flow<List<VocabEntry>> = dao.observeAll()
    val count: Flow<Int> = dao.observeCount()

    suspend fun getAll(): List<VocabEntry> = dao.getAll()

    suspend fun save(entry: VocabEntry) = dao.upsert(entry)

    suspend fun create(
        bookStableId: String,
        word: String,
        sentence: String,
        sentenceBefore: String,
        sentenceAfter: String,
        locator: String?,
        position: Double,
        chapterTitle: String?,
        sourceLanguage: String?,
        definitionSnapshot: String?,
    ): VocabEntry {
        val entry = VocabEntry(
            id = UUID.randomUUID().toString(),
            bookStableId = bookStableId,
            word = word.trim(),
            sentence = sentence,
            sentenceBefore = sentenceBefore,
            sentenceAfter = sentenceAfter,
            locator = locator,
            position = position,
            chapterTitle = chapterTitle,
            sourceLanguage = sourceLanguage,
            definitionSnapshot = definitionSnapshot,
        )
        dao.upsert(entry)
        return entry
    }

    suspend fun delete(id: String) = dao.delete(id)

    suspend fun updateNoteAndDefinition(id: String, note: String?, definition: String?) =
        dao.updateNoteAndDefinition(id, note, definition)

    suspend fun updateDefinition(id: String, definition: String?) =
        dao.updateDefinition(id, definition)

    suspend fun review(entry: VocabEntry, action: LeitnerScheduler.Action) {
        val now = System.currentTimeMillis()
        val r = LeitnerScheduler.apply(action, entry.studyBox, entry.reviewStreak, now)
        dao.applyReview(entry.id, r.newBox, r.nextReviewAt, now, r.reviewStreak)
    }
}
