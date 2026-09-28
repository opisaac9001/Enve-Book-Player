package com.enve.app.data.opds

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsProgressionStateStoreTest {

    private val dao = FakeOpdsProgressionStateDao()
    private val store = OpdsProgressionStateStore(dao)

    private val ebookId = "https://opds.example.com/moby.epub"
    private val audiobookId = "urn:uuid:019c0049-6e8c-745c-adb1-5b03f8ad50c4"
    private val noMembers = JsonObject(emptyMap())

    @Test
    fun keeps_the_unhandled_references_of_each_book_and_connection_apart() = runBlocking {
        store.save("conn-1", ebookId, listOf("#xywh=160,120,320,240"), noMembers)
        store.save("conn-1", audiobookId, listOf("vendor:state=later"), noMembers)
        store.save("conn-2", ebookId, listOf("#custom=2"), noMembers)

        assertEquals(listOf("#xywh=160,120,320,240"), store.carryover("conn-1", ebookId).references)
        assertEquals(listOf("vendor:state=later"), store.carryover("conn-1", audiobookId).references)
        assertEquals(listOf("#custom=2"), store.carryover("conn-2", ebookId).references)
        assertTrue(store.carryover("conn-1", "urn:uuid:unknown").references.isEmpty())
    }

    @Test
    fun an_authoritative_document_without_unknown_references_clears_the_row() = runBlocking {
        store.save("conn-1", ebookId, listOf("#xywh=160,120,320,240"), noMembers)
        store.save("conn-1", ebookId, emptyList(), noMembers)

        assertTrue(store.carryover("conn-1", ebookId).references.isEmpty())
        assertNull(dao.get("conn-1:$ebookId"))
    }

    @Test
    fun unknown_top_level_members_are_carried_until_the_server_drops_them() = runBlocking {
        val members = Json.parseToJsonElement("""{"x-shelf":{"seat":2}}""") as JsonObject

        store.save("conn-1", ebookId, emptyList(), members)
        assertEquals(members, store.carryover("conn-1", ebookId).additionalMembers)

        store.save("conn-1", ebookId, emptyList(), noMembers)
        assertEquals(noMembers, store.carryover("conn-1", ebookId).additionalMembers)
        assertNull(dao.get("conn-1:$ebookId"))
    }

    @Test
    fun the_authenticate_hint_outlives_a_document_that_clears_its_references() = runBlocking {
        store.saveAuthenticateUrls("conn-1", mapOf(ebookId to "https://opds.example.com/auth"))
        store.save("conn-1", ebookId, listOf("#xywh=160,120,320,240"), noMembers)
        store.save("conn-1", ebookId, emptyList(), noMembers)

        assertTrue(store.carryover("conn-1", ebookId).references.isEmpty())
        assertEquals("https://opds.example.com/auth", store.authenticateUrl("conn-1", ebookId))
    }

    @Test
    fun a_book_with_no_hint_and_no_references_keeps_no_row() = runBlocking {
        store.saveAuthenticateUrls("conn-1", emptyMap())
        store.save("conn-1", audiobookId, emptyList(), noMembers)

        assertNull(dao.get("conn-1:$audiobookId"))
        assertNull(store.authenticateUrl("conn-1", audiobookId))
    }

    @Test
    fun a_feed_that_stops_carrying_a_hint_never_erases_the_stored_one() = runBlocking {
        store.saveAuthenticateUrls("conn-1", mapOf(ebookId to "https://opds.example.com/auth"))
        store.saveAuthenticateUrls("conn-1", emptyMap())

        assertEquals("https://opds.example.com/auth", store.authenticateUrl("conn-1", ebookId))
        assertEquals(1, dao.transactions)
    }

    @Test
    fun a_page_of_hints_costs_one_transaction() = runBlocking {
        store.saveAuthenticateUrls(
            "conn-1",
            mapOf(
                ebookId to "https://opds.example.com/auth",
                audiobookId to "https://opds.example.com/auth",
            ),
        )

        assertEquals(1, dao.transactions)
        assertEquals("https://opds.example.com/auth", store.authenticateUrl("conn-1", ebookId))
        assertEquals("https://opds.example.com/auth", store.authenticateUrl("conn-1", audiobookId))
    }

    @Test
    fun references_survive_the_json_round_trip_in_order() = runBlocking {
        val references = listOf("#xywh=160,120,320,240", "page78.jxl?variant=hi", "vendor:state=later")

        store.save("conn-1", audiobookId, references, noMembers)

        assertEquals(references, store.carryover("conn-1", audiobookId).references)
        assertEquals(references, decodeReferences(encodeReferences(references)))
    }
}

private class FakeOpdsProgressionStateDao : OpdsProgressionStateDao {
    private val rows = mutableMapOf<String, OpdsProgressionStateEntity>()

    var transactions: Int = 0
        private set

    override suspend fun get(bookKey: String): OpdsProgressionStateEntity? = rows[bookKey]

    override suspend fun upsert(entity: OpdsProgressionStateEntity) {
        rows[entity.bookKey] = entity
    }

    override suspend fun delete(bookKey: String) {
        rows.remove(bookKey)
    }

    override suspend fun setAuthenticateUrl(bookKey: String, url: String?): Int {
        val existing = rows[bookKey] ?: return 0
        rows[bookKey] = existing.copy(authenticateUrl = url)
        return 1
    }

    override suspend fun insertIfAbsent(entity: OpdsProgressionStateEntity): Long {
        if (rows.containsKey(entity.bookKey)) return -1L
        rows[entity.bookKey] = entity
        return 1L
    }

    override suspend fun saveAuthenticateHints(hints: List<OpdsProgressionAuthenticateHint>, nowMs: Long) {
        transactions += 1
        super<OpdsProgressionStateDao>.saveAuthenticateHints(hints, nowMs)
    }
}
