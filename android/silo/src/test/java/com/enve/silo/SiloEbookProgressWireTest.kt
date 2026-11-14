package com.enve.silo

import com.enve.silo.dto.SiloEbookProgressRequest
import com.enve.silo.dto.SiloProgressSyncItem
import com.enve.silo.dto.SiloProgressSyncRequest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class SiloEbookProgressWireTest {
    private val observedAt = 1_767_323_045_123L
    private val request = SiloEbookProgressRequest("12", "epubcfi(/6/2)", 0.25, siloInstant(observedAt))

    @Test
    fun savePutsTheObservedEventTimeAndAcceptsTheEcho() = runBlocking {
        val transport = SiloFakeTransport {
            SiloReply(200, """{"progress":{"content_id":"book-one","file_id":"12","location":"epubcfi(/6/2)","progress":0.25,"updated_at":"2026-01-02T03:04:05.123Z"}}""")
        }
        transport.api.saveSiloEbookProgress("profile-1", "book-one", request)
        val call = transport.calls.single()
        assertEquals("PUT", call.method)
        assertEquals("/api/v2/ebooks/book-one/progress", call.path)
        assertEquals("profile-1", call.headers["X-Profile-Id"])
        assertEquals("2026-01-02T03:04:05.123Z", call.json()["updated_at"]!!.jsonPrimitive.content)
        assertEquals("12", call.json()["file_id"]!!.jsonPrimitive.content)
    }

    @Test
    fun aNewerStoredPositionAcknowledgesTheSupersededOfflineWrite() = runBlocking {
        val transport = SiloFakeTransport {
            SiloReply(200, """{"progress":{"content_id":"book-one","file_id":"12","location":"epubcfi(/6/9)","progress":0.5,"updated_at":"2026-01-03T00:00:00.000Z"}}""")
        }
        transport.api.saveSiloEbookProgress("profile-1", "book-one", request)
        assertEquals(1, transport.calls.size)
        assertEquals("2026-01-02T03:04:05.123Z", transport.calls.single().json()["updated_at"]!!.jsonPrimitive.content)
    }

    @Test
    fun anEqualTimeWithADifferentPositionIsNotReportedAsSaved() {
        val transport = SiloFakeTransport {
            SiloReply(200, """{"progress":{"content_id":"book-one","file_id":"12","location":"epubcfi(/6/9)","progress":0.5,"updated_at":"2026-01-02T03:04:05.123Z"}}""")
        }
        assertThrows(IllegalStateException::class.java) {
            runBlocking { transport.api.saveSiloEbookProgress("profile-1", "book-one", request) }
        }
    }

    @Test
    fun futureEventRejectionAndMissingBodyFail() {
        val rejected = SiloFakeTransport { problem("validation_failed", 422) }
        assertThrows(IllegalStateException::class.java) {
            runBlocking { rejected.api.saveSiloEbookProgress("profile-1", "book-one", request) }
        }
        val empty = SiloFakeTransport { SiloReply(200, "{}") }
        assertThrows(IllegalStateException::class.java) {
            runBlocking { empty.api.saveSiloEbookProgress("profile-1", "book-one", request) }
        }
    }

    @Test
    fun readDecodesTheEnvelopeAndAbsentProgress() = runBlocking {
        val saved = SiloFakeTransport {
            SiloReply(200, """{"progress":{"content_id":"book-one","file_id":"12","location":"epubcfi(/6/2)","progress":0.25,"updated_at":"2026-01-02T03:04:05.000Z"}}""")
        }
        val progress = siloEbookProgress(saved.api.ebookProgress("profile-1", "book-one"))
        assertEquals("12", progress?.fileId)
        assertEquals(1_767_323_045_000L, siloInstantMillis(progress?.updatedAt))

        val absent = SiloFakeTransport { SiloReply(200, "{}") }
        assertNull(siloEbookProgress(absent.api.ebookProgress("profile-1", "book-one")))
    }

    @Test
    fun audioBatchSyncSendsMillisecondsAndOmitsUnknownEventTime() = runBlocking {
        val transport = SiloFakeTransport {
            SiloReply(200, """{"items":[{"index":0,"media_item_id":"a","status":"success"},{"index":1,"media_item_id":"b","status":"failure","failure":{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"Catalog item not found."}}],"summary":{"total":2,"succeeded":1,"failed":1}}""")
        }
        val response = transport.api.syncProgress(
            "profile-1",
            SiloProgressSyncRequest(
                listOf(
                    SiloProgressSyncItem("a", positionMs = 61_000L, durationMs = 3_600_000L, updatedAt = siloInstant(observedAt)),
                    SiloProgressSyncItem("b", positionMs = 0L, durationMs = 0L),
                ),
            ),
        ).siloBody("sync")
        val items = transport.calls.single().json()["items"]!!.jsonArray
        assertEquals("/api/v2/sync/progress", transport.calls.single().path)
        assertEquals("61000", items[0].jsonObject["position_ms"].toString())
        assertEquals("2026-01-02T03:04:05.123Z", items[0].jsonObject["updated_at"]!!.jsonPrimitive.content)
        assertFalse("updated_at" in items[1].jsonObject)
        assertEquals("success", response.items[0].status)
        assertEquals("not_found", response.items[1].failure?.id)
    }
}
