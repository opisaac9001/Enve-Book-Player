package com.enve.silo

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.provider.RemoteCatalogSort
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class SiloRemoteCatalogTest {
    private val cards = """{"items":[{"content_id":"one","type":"ebook","title":"Alice","original_language":"en","genres":["Fiction"]}],"page":{"has_more":true,"next_cursor":"page-two"}}"""

    @Test fun plainSearchUsesOneCatalogRequestWithNoDetailCalls() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, cards) }
        val result = transport.api.remoteCatalogPage("profile", "library", RemoteCatalogRequest(search = " Alice ", mediaType = AppMediaType.EBOOK), null, 50)
        assertEquals("en", result.items.single().originalLanguage)
        assertEquals("page-two", result.page?.nextCursor)
        val call = transport.calls.single()
        assertEquals("GET", call.method)
        assertEquals("/api/v2/catalog", call.path)
        assertEquals("Alice", call.query("q"))
        assertEquals("ebook", call.query("type"))
        assertEquals("50", call.query("limit"))
        assertEquals("true", call.query("skip_total"))
        assertEquals("profile", call.headers["X-Profile-Id"])
    }

    @Test fun filtersAreOrWithinCategoriesAndAcrossCategoriesBeforePaging() = runBlocking {
        val transport = SiloFakeTransport { SiloReply(200, cards) }
        transport.api.remoteCatalogPage("profile", "library", RemoteCatalogRequest(
            search = "Alice", mediaType = AppMediaType.EBOOK, sort = RemoteCatalogSort.RECENTLY_ADDED,
            genres = setOf("History", "Fiction"), languages = setOf("en", "de"),
        ), "page-one", 200)
        val call = transport.calls.single()
        assertEquals("POST", call.method)
        assertEquals("/api/v2/catalog/query", call.path)
        val body = call.json()
        assertEquals("all", body["match"]?.jsonPrimitive?.content)
        assertEquals("100", body["limit"]?.jsonPrimitive?.content)
        assertEquals("page-one", body["cursor"]?.jsonPrimitive?.content)
        assertEquals("library", body["library_id"]?.jsonPrimitive?.content)
        assertEquals("Alice", body["q"]?.jsonPrimitive?.content)
        assertEquals("added_at", body["sort"]?.jsonPrimitive?.content)
        assertEquals("desc", body["order"]?.jsonPrimitive?.content)
        val groups = body.getValue("groups").jsonArray
        assertEquals(2, groups.size)
        groups.forEach { assertEquals("any", it.jsonObject["match"]?.jsonPrimitive?.content) }
        val rules = groups[0].jsonObject.getValue("rules").jsonArray
        assertEquals(listOf("Fiction", "History"), rules.map { it.jsonObject.getValue("value").jsonPrimitive.content })
        assertTrue(rules.all { it.jsonObject["op"]?.jsonPrimitive?.content == "is" })
        assertEquals("original_language", groups[1].jsonObject.getValue("rules").jsonArray[0].jsonObject["field"]?.jsonPrimitive?.content)
    }

    @Test fun facetSearchUsesCapabilitiesAndRankedValues() = runBlocking {
        val transport = SiloFakeTransport { call ->
            if (call.path.endsWith("capabilities")) SiloReply(200, """{"facet_value_search":true}""")
            else SiloReply(200, """{"values":[{"value":"${if (call.query("facet") == "genre") "Fiction" else "en"}","count":10}],"values_has_more":true}""")
        }
        val result = transport.api.remoteCatalogFilterOptions("profile", "library", AppMediaType.EBOOK, "fi")
        assertEquals(listOf("Fiction"), result.genres)
        assertEquals(listOf("en"), result.languages)
        assertTrue(result.hasMore)
        assertEquals(3, transport.calls.size)
        transport.calls.filter { it.path.endsWith("search") }.forEach {
            assertEquals("24", it.query("limit"))
            assertEquals("fi", it.query("q"))
            assertEquals("ebook", it.query("type"))
            assertEquals("library", it.query("library_id"))
        }
    }

    @Test fun oldServerAndFailedQueriesAreNotEmptySuccess() {
        for (code in listOf(401, 500, 400)) {
            val transport = SiloFakeTransport { SiloReply(code, "{}") }
            assertThrows(IllegalStateException::class.java) {
                runBlocking { transport.api.remoteCatalogPage("p", "l", RemoteCatalogRequest(), null, 50) }
            }
        }
        val old = SiloFakeTransport { SiloReply(404, "{}") }
        val failure = assertThrows(UnsupportedOperationException::class.java) {
            runBlocking { old.api.remoteCatalogFilterOptions("p", "l", null, "") }
        }
        assertTrue(failure.message.orEmpty().startsWith("Update this Silo server"))
    }

    @Test fun missingTitlesOrBrokenContinuationFailInsteadOfHidingResults() {
        for (body in listOf(
            """{"items":[{"content_id":"x","type":"ebook"}]}""",
            """{"items":[],"page":{"has_more":true}}""",
            """{"items":[],"page":{"has_more":true,"next_cursor":"same"}}""",
        )) {
            val transport = SiloFakeTransport { SiloReply(200, body) }
            assertThrows(IllegalArgumentException::class.java) {
                runBlocking { transport.api.remoteCatalogPage("p", "l", RemoteCatalogRequest(), "same", 50) }
            }
        }
    }
}
