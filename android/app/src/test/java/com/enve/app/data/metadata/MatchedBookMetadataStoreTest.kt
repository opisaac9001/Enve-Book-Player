package com.enve.app.data.metadata

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class MatchedBookMetadataStoreTest {
    @Test
    fun saveMatch_appliesCandidateFieldsAndPreservesProgress() = runBlocking {
        val dao = FakeMatchedBookMetadataDao()
        val store = MatchedBookMetadataStore(dao)
        val book = Book(
            id = "42",
            title = "Old Title",
            author = "Old Author",
            duration = 1234,
            currentTime = 300,
            readProgress = 0.25f,
            source = BookSource.GRIMMORY,
            mediaType = AppMediaType.AUDIOBOOK,
        )
        val candidate = MetadataMatchCandidate(
            id = "audio:B000TEST00",
            externalId = "B000TEST00",
            source = MetadataCandidateSource.AUDIOBOOK_CATALOG,
            mediaType = AppMediaType.AUDIOBOOK,
            title = "New Title",
            author = "New Author",
            narrator = "Narrator",
            publisher = "Publisher",
            coverUrl = "https://example.com/cover.jpg",
            seriesName = "Series",
            seriesPosition = "2",
            description = "Description",
            categories = listOf("Fantasy", "Adventure"),
            durationSec = null,
            confidence = 0.9,
            matchReason = "90%",
        )

        val updated = store.saveMatch(book, candidate)

        assertEquals("New Title", updated.title)
        assertEquals("New Author", updated.author)
        assertEquals("Narrator", updated.narrator)
        assertEquals("Publisher", updated.publisher)
        assertEquals("Series", updated.seriesName)
        assertEquals("2", updated.seriesNumber)
        assertEquals("https://example.com/cover.jpg", updated.coverUrl)
        assertEquals(listOf("Fantasy", "Adventure"), updated.categories)
        assertEquals(1234, updated.duration)
        assertEquals(300, updated.currentTime)
        assertEquals(0.25f, updated.readProgress)
    }

    private class FakeMatchedBookMetadataDao : MatchedBookMetadataDao {
        private val rows = mutableMapOf<String, MatchedBookMetadata>()

        override suspend fun upsert(metadata: MatchedBookMetadata) {
            rows[metadata.metadataKey] = metadata
        }

        override suspend fun get(metadataKey: String): MatchedBookMetadata? = rows[metadataKey]

        override suspend fun getForKeys(metadataKeys: List<String>): List<MatchedBookMetadata> =
            metadataKeys.mapNotNull(rows::get)

        override suspend fun delete(metadataKey: String) {
            rows.remove(metadataKey)
        }
    }
}
