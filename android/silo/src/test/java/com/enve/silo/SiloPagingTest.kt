package com.enve.silo

import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloPageInfo
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class SiloPagingTest {
    private fun pages(vararg pages: Pair<List<Int>, String?>): Map<String?, SiloCollection<Int>> {
        val result = mutableMapOf<String?, SiloCollection<Int>>()
        var cursor: String? = null
        pages.forEach { (items, next) ->
            result[cursor] = SiloCollection(items, next?.let { SiloPageInfo(it, true) } ?: SiloPageInfo(null, false))
            cursor = next
        }
        return result
    }

    @Test
    fun collectAllFollowsCursorsThroughShortAndEmptyPages() = runBlocking {
        val server = pages(listOf(1, 2) to "a", emptyList<Int>() to "b", listOf(3) to "c", emptyList<Int>() to null)
        val requested = mutableListOf<String?>()
        val items = siloCollectAll { cursor -> requested += cursor; server.getValue(cursor) }
        assertEquals(listOf(1, 2, 3), items)
        assertEquals(listOf(null, "a", "b", "c"), requested)
    }

    @Test
    fun hasMoreWithoutCursorEndsAndBlankCursorEnds() = runBlocking {
        val items = siloCollectAll { SiloCollection(listOf(1), SiloPageInfo(nextCursor = "", hasMore = true)) }
        assertEquals(listOf(1), items)
    }

    @Test
    fun repeatedCursorIsRefused() {
        assertThrows(IllegalStateException::class.java) {
            runBlocking { siloCollectAll { SiloCollection(listOf(1), SiloPageInfo("same", true)) } }
        }
        assertThrows(IllegalStateException::class.java) {
            runBlocking { siloFillPage(SiloPageStart("same"), 5) { SiloCollection(emptyList<Int>(), SiloPageInfo("same", true)) } }
        }
    }

    @Test
    fun fillPageKeepsReadingPastShortPagesAndResumesInsideASplitPage() = runBlocking {
        val server = pages(listOf(1) to "a", emptyList<Int>() to "b", listOf(2, 3, 4) to "c", listOf(5) to null)
        val first = siloFillPage(SiloPageStart(null), 3) { server.getValue(it) }
        assertEquals(listOf(1, 2, 3), first.items)
        assertEquals(SiloPageStart("b", 2), first.next)

        val second = siloFillPage(first.next!!, 3) { server.getValue(it) }
        assertEquals(listOf(4, 5), second.items)
        assertNull(second.next)
    }

    @Test
    fun exactlyFullPageAdvancesToTheNextCursor() = runBlocking {
        val server = pages(listOf(1, 2) to "a", listOf(3) to null)
        val first = siloFillPage(SiloPageStart(null), 2) { server.getValue(it) }
        assertEquals(SiloPageStart("a"), first.next)
    }

    @Test
    fun catalogCursorsWalkSkippedPagesAndStopAtTheEnd() = runBlocking {
        val server = pages(listOf(1, 2) to "a", listOf(3) to "b", emptyList<Int>() to "c", listOf(4, 5, 6) to null)
        val requested = mutableListOf<String?>()
        val cursors = SiloCatalogCursors()
        val fetch: suspend (String?) -> SiloCollection<Int> = { requested += it; server.getValue(it) }

        assertEquals(listOf(5, 6), cursors.page("k", 2, 2, fetch))
        assertEquals(listOf(null, "a", "b", "c", "c"), requested)

        requested.clear()
        assertEquals(listOf(3, 4), cursors.page("k", 1, 2, fetch))
        assertEquals(listOf("a", "b", "c"), requested)

        requested.clear()
        assertEquals(emptyList<Int>(), cursors.page("k", 3, 2, fetch))
        assertEquals(emptyList<String?>(), requested)
    }

    @Test
    fun firstPageResetsLaterCursors() = runBlocking {
        val server = pages(listOf(1, 2) to "a", listOf(3, 4) to null)
        val requested = mutableListOf<String?>()
        val cursors = SiloCatalogCursors()
        val fetch: suspend (String?) -> SiloCollection<Int> = { requested += it; server.getValue(it) }
        cursors.page("k", 1, 2, fetch)
        requested.clear()
        cursors.page("k", 0, 2, fetch)
        cursors.page("k", 1, 2, fetch)
        assertEquals(listOf(null, "a"), requested)
    }

    @Test
    fun catalogWireRequestCarriesCursorSortAndProfile() = runBlocking {
        val transport = SiloFakeTransport { call ->
            when (call.query("cursor")) {
                null -> SiloReply(200, """{"items":[{"content_id":"a","type":"ebook"}],"page":{"next_cursor":"n1","has_more":true}}""")
                else -> SiloReply(200, """{"items":[{"content_id":"b","type":"ebook"}],"page":{"has_more":false}}""")
            }
        }
        val items = siloCollectAll { cursor ->
            transport.api.catalog("profile-1", "12", "-added_at", cursor, 50).siloBody("catalog")
        }
        assertEquals(listOf("a", "b"), items.map { it.contentId })
        val second = transport.calls[1]
        assertEquals("/api/v2/catalog", second.path)
        assertEquals("n1", second.query("cursor"))
        assertEquals("-added_at", second.query("sort"))
        assertEquals("12", second.query("library_id"))
        assertEquals("true", second.query("skip_total"))
        assertNull(transport.calls[0].query("cursor"))
        assertNull(transport.calls[0].query("offset"))
        assertEquals("profile-1", second.headers["X-Profile-Id"])
    }

    @Test
    fun invalidCursorProblemSurfacesAsFailure() {
        val transport = SiloFakeTransport { problem("invalid_cursor", 400) }
        assertThrows(IllegalStateException::class.java) {
            runBlocking { transport.api.progressList("profile-1", "12", "stale").siloBody("progress") }
        }
    }
}
