package com.enve.app.data.librarian

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.local.ProfileStorageLocations
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BookContextBoundaryTest {
    private val book = LibrarianBookRef("boundary", "LOCAL", null, "Boundary fixture", null, "EPUB", 0.0)

    @Test fun recentPagesSlicesBothBoundsAgainstTheOriginalChunk() = withContextStore { store, retriever ->
        store.save(book.stableId, listOf(chunk(text = words(1..100))))
        val result = retriever.contextFor(book, BookIntelligenceScope.RECENT_PAGES, 0.3)
        assertEquals(words(26..30), result.text)
        assertEquals(1, result.chunkCount)
    }

    @Test fun zeroProgressContainsNoTextOrChapterTitle() = withContextStore { store, retriever ->
        store.save(book.stableId, listOf(chunk(title = "Unread title", text = words(1..100))))
        for (scope in BookIntelligenceScope.entries) {
            val result = retriever.contextFor(book, scope, 0.0)
            assertTrue(result.isEmpty)
            assertEquals(0, result.chunkCount)
        }
    }

    @Test fun chapterBoundaryExcludesTheNextChapterTitleAndWords() = withContextStore { store, retriever ->
        store.save(book.stableId, listOf(
            chunk(title = "Read chapter", end = 0.5, text = "Already read."),
            chunk(index = 1, title = "Future revelation", start = 0.5, text = "Not read yet."),
        ))
        val result = retriever.contextFor(book, BookIntelligenceScope.BOOK_SO_FAR, 0.5)
        assertEquals("[Read chapter] Already read.", result.text)
        assertEquals(1, result.chunkCount)
    }

    @Test fun readingBeforeTheFirstIndexedChapterHasNoContext() = withContextStore { store, retriever ->
        store.save(book.stableId, listOf(chunk(start = 0.2, text = "Future content")))
        val result = retriever.contextFor(book, BookIntelligenceScope.CURRENT_CHAPTER_SO_FAR, 0.1)
        assertTrue(result.isEmpty)
        assertEquals(0.1, result.rangeStart, 0.0)
        assertEquals(0.1, result.rangeEnd, 0.0)
    }

    @Test fun partialWordsAndWhitespaceCannotExtendTheUpperBoundary() = withContextStore { store, retriever ->
        store.save(book.stableId, listOf(chunk(text = "one\ntwo\tthree four")))
        assertEquals("one", retriever.contextFor(book, BookIntelligenceScope.BOOK_SO_FAR, 0.49).text)
    }

    @Test fun retrievalNeighborsAndScopeFallbackStayBeforeTheBoundary() = withContextStore { store, retriever ->
        store.save(book.stableId, listOf(
            chunk(end = 0.5, text = "The traveler arrived."),
            chunk(index = 1, title = "Future revelation", start = 0.5, text = "The traveler is the king."),
        ))
        val result = retriever.contextForWithFallback(book, BookIntelligenceScope.RECENT_PAGES, 0.5, "Who is the traveler?")
        assertTrue(result.text.contains("traveler"))
        assertTrue(!result.text.contains("king"))
        assertTrue(!result.text.contains("Future revelation"))
    }

    private fun withContextStore(test: suspend (EbookContextStore, BookContextRetriever) -> Unit) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = File(context.cacheDir, "context-boundary-${UUID.randomUUID()}")
        val locations = ProfileStorageLocations.forProfile(UUID.randomUUID().toString(), root, root, root)
        try {
            val store = EbookContextStore(context, locations)
            test(store, BookContextRetriever(store))
        } finally {
            root.deleteRecursively()
        }
    }

    private fun chunk(index: Int = 0, title: String? = null, start: Double = 0.0, end: Double = 1.0, text: String) =
        EbookContextChunk("c$index", book.stableId, title, "chapter$index.xhtml", index, start, end, text)

    private fun words(range: IntRange) = range.joinToString(" ") { "word$it" }
}
