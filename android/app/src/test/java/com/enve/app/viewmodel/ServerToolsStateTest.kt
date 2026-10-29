package com.enve.app.viewmodel

import com.enve.core.data.model.Book
import com.enve.engine.servertools.*
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ServerToolsStateTest {
    private val features = setOf(ServerFeature.STATS, ServerFeature.HIGHLIGHTS, ServerFeature.RECOMMENDATIONS)

    @Test
    fun `failed stats retain successful notes and show a retryable failure`() = runBlocking {
        val facade = FixtureFacade(statsError = IOException("HTTP 503"), notes = listOf(note))
        val state = loadServerToolsState(facade, "fixture", features)
        assertEquals(setOf(ServerFeature.STATS), state.failedFeatures)
        assertEquals(listOf(note), state.highlights)
        assertTrue(state.hasAnyContent)
        assertFalse(state.unsupported)
    }

    @Test
    fun `valid empty and unsupported results are distinct`() = runBlocking {
        val empty = loadServerToolsState(FixtureFacade(), "fixture", features)
        assertFalse(empty.hasAnyContent)
        assertFalse(empty.unsupported)
        assertTrue(empty.failedFeatures.isEmpty())
        val unsupported = loadServerToolsState(
            FixtureFacade(ServerFeatureUnsupportedException(), ServerFeatureUnsupportedException()), "fixture", features,
        )
        assertTrue(unsupported.unsupported)
        assertTrue(unsupported.failedFeatures.isEmpty())
    }

    @Test
    fun `supported empty notes prevent a partially unsupported source being labeled unsupported`() = runBlocking {
        val state = loadServerToolsState(FixtureFacade(statsError = ServerFeatureUnsupportedException()), "fixture", features)
        assertFalse(state.unsupported)
        assertTrue(state.failedFeatures.isEmpty())
    }

    @Test
    fun `retry recovers after both feature requests fail`() = runBlocking {
        val facade = FixtureFacade(IOException(), IOException())
        assertEquals(setOf(ServerFeature.STATS, ServerFeature.HIGHLIGHTS), loadServerToolsState(facade, "fixture", features).failedFeatures)
        facade.statsError = null
        facade.notesError = null
        val recovered = loadServerToolsState(facade, "fixture", features)
        assertTrue(recovered.failedFeatures.isEmpty())
        assertFalse(recovered.unsupported)
    }

    @Test
    fun `cancellation propagates`() {
        assertThrows(CancellationException::class.java) {
            runBlocking { loadServerToolsState(FixtureFacade(statsError = CancellationException()), "fixture", features) }
        }
    }

    private class FixtureFacade(
        var statsError: Exception? = null,
        var notesError: Exception? = null,
        val notes: List<ServerHighlight> = emptyList(),
    ) : ServerToolsFacade {
        override val targets = flowOf(emptyList<ServerToolsTarget>())
        override suspend fun stats(connectionId: String): List<ServerStatGroup> {
            statsError?.let { throw it }
            return emptyList()
        }
        override suspend fun highlights(connectionId: String, limit: Int): List<ServerHighlight> {
            notesError?.let { throw it }
            return notes
        }
        override suspend fun achievements(connectionId: String): ServerAchievementSummary? = null
        override suspend fun bookmarks(connectionId: String, limit: Int): List<ServerBookmark> = emptyList()
        override suspend fun history(connectionId: String, limit: Int): List<ServerHistoryEntry> = emptyList()
        override suspend fun relatedBooks(book: Book, limit: Int): List<Book> = emptyList()
    }

    private val note = ServerHighlight("note", "Fixture", null, null, "Text", null, null)
}
