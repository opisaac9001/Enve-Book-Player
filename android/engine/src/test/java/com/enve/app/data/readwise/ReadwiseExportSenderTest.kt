package com.enve.app.data.readwise

import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.readwise.ReadwiseExportProgress
import com.enve.engine.readwise.ReadwiseFailure
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.concurrent.TimeUnit

class ReadwiseExportSenderTest {
    @get:Rule val folder = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var store: ReadwiseReceiptStore
    private val pauses = mutableListOf<Long>()
    private var now = 0L

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
        store = ReadwiseReceiptStore(locations(folder.newFolder("profile")))
    }

    @After fun tearDown() {
        server.shutdown()
    }

    private fun sender() = ReadwiseExportSender(
        ReadwiseClient(readwiseHttpClient(), server.url("/").newBuilder().host("127.0.0.1").build()),
        store,
        pause = { pauses += it; now += it },
        clock = { now },
    )

    @Test fun createsOneHighlightPerRequestAndRecordsConfirmedIds() = runBlocking {
        repeat(3) { server.enqueue(created(book = 5, highlight = 100L + it)) }
        val progress = mutableListOf<ReadwiseExportProgress>()
        val items = pending(3)

        val result = sender().send("t", "account-a", items) { progress += it }

        assertEquals(3, result.sentCount)
        assertEquals(0, result.unsentCount)
        assertNull(result.failure)
        repeat(3) {
            val request = server.takeRequest()
            assertEquals("POST", request.method)
            assertEquals(1, highlightsIn(request))
        }
        assertEquals(items.mapIndexed { i, item -> item.annotationId to ReadwiseReceipt(100L + i, item.fingerprint) }.toMap(), store.receipts("account-a"))
        assertTrue(store.receipts("account-b").isEmpty())
        assertEquals(listOf(260L, 260L), pauses)
        assertEquals(ReadwiseExportProgress(3, 3), progress.last())
    }

    @Test fun editedNoteIsPatchedOntoTheConfirmedHighlight() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":42,"text":"Highlight 0","note":"Edited"}"""))
        val edited = pending(1, remoteId = 42, note = "Edited").single()

        val result = sender().send("t", "account", listOf(edited), {})

        assertEquals(1, result.sentCount)
        val request = server.takeRequest()
        assertEquals("PATCH", request.method)
        assertEquals("/api/v2/highlights/42/", request.path)
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals("Edited", body.getValue("note").jsonPrimitive.content)
        assertEquals("Highlight 0", body.getValue("text").jsonPrimitive.content)
        assertEquals(1, server.requestCount)
        assertEquals(mapOf(edited.annotationId to ReadwiseReceipt(42, edited.fingerprint)), store.receipts("account"))
    }

    @Test fun patchOfADeletedRemoteHighlightRecreatesIt() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(created(book = 5, highlight = 77))
        val edited = pending(1, remoteId = 42).single()

        val result = sender().send("t", "account", listOf(edited), {})

        assertEquals(1, result.sentCount)
        assertEquals("PATCH", server.takeRequest().method)
        assertEquals("POST", server.takeRequest().method)
        assertEquals(ReadwiseReceipt(77, edited.fingerprint), store.receipts("account").getValue(edited.annotationId))
    }

    @Test fun unchangedCreateRecoversTheIdFromFixedOriginPages() = runBlocking {
        val elsewhere = MockWebServer().apply { start() }
        try {
            server.enqueue(created(book = 5, highlight = null))
            server.enqueue(page(next = elsewhere.url("/api/v2/highlights/?page=2").toString(), 11L to "Unrelated"))
            server.enqueue(page(next = null, 88L to " Highlight 0 "))
            server.enqueue(MockResponse().setBody("""{"id":88,"text":"Highlight 0"}"""))
            val item = pending(1).single()

            val result = sender().send("t", "account", listOf(item), {})

            assertEquals(1, result.sentCount)
            assertEquals("POST", server.takeRequest().method)
            assertEquals("/api/v2/highlights/?book_id=5&page_size=1000&page=1", server.takeRequest().path)
            assertEquals("/api/v2/highlights/?book_id=5&page_size=1000&page=2", server.takeRequest().path)
            assertEquals(0, elsewhere.requestCount)
            assertEquals(ReadwiseReceipt(88, item.fingerprint), store.receipts("account").getValue(item.annotationId))
            assertEquals(listOf(260L, 3_100L, 260L), pauses)
            assertEquals("PATCH", server.takeRequest().method)
        } finally {
            elsewhere.shutdown()
        }
    }

    @Test fun lostCreateResponseIsRecoveredWithoutADuplicate() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))
        server.enqueue(created(book = 5, highlight = null))
        server.enqueue(page(next = null, 61L to "Highlight 0"))
        server.enqueue(MockResponse().setBody("""{"id":61,"text":"Highlight 0"}"""))
        val item = pending(1).single()

        val result = sender().send("t", "account", listOf(item), {})

        assertEquals("result=$result requests=${server.requestCount}", 1, result.sentCount)
        assertNull(result.failure)
        assertEquals(4, server.requestCount)
        assertEquals(ReadwiseReceipt(61, item.fingerprint), store.receipts("account").getValue(item.annotationId))
    }

    @Test fun unconfirmedCreateFailsWithoutRetryOrReceipt() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200))

        val result = sender().send("t", "account", pending(2), {})

        assertEquals(0, result.sentCount)
        assertEquals(2, result.unsentCount)
        assertEquals(ReadwiseFailure.SERVER, result.failure)
        assertEquals(1, server.requestCount)
        assertTrue(store.receipts("account").isEmpty())
    }

    @Test fun createWithoutAnyReturnedBookIsUnconfirmed() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("[]"))

        val result = sender().send("t", "account", pending(1), {})

        assertEquals(ReadwiseFailure.SERVER, result.failure)
        assertTrue(store.receipts("account").isEmpty())
    }

    @Test fun lookupWithoutAMatchIsUnconfirmed() = runBlocking {
        server.enqueue(created(book = 5, highlight = null))
        server.enqueue(page(next = null, 1L to "Different"))

        val result = sender().send("t", "account", pending(1), {})

        assertEquals(ReadwiseFailure.SERVER, result.failure)
        assertEquals(1, result.unsentCount)
        assertTrue(store.receipts("account").isEmpty())
    }

    @Test fun ambiguousLookupIsUnconfirmed() = runBlocking {
        server.enqueue(created(book = 5, highlight = null))
        server.enqueue(page(next = null, 1L to "Highlight 0", 2L to "Highlight 0"))

        val result = sender().send("t", "account", pending(1), {})

        assertEquals(ReadwiseFailure.SERVER, result.failure)
        assertTrue(store.receipts("account").isEmpty())
    }

    @Test fun malformedOrRedirectedPagesStopWithoutReceipts() = runBlocking {
        val elsewhere = MockWebServer().apply { start() }
        try {
            server.enqueue(created(book = 5, highlight = null))
            server.enqueue(MockResponse().setResponseCode(200).setBody("""{"next":3,"results":[]}"""))
            server.enqueue(created(book = 5, highlight = null))
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", elsewhere.url("/steal").toString()))

            val malformed = sender().send("t", "account", pending(1), {})
            val redirected = sender().send("t", "account", pending(1), {})

            assertEquals(ReadwiseFailure.SERVER, malformed.failure)
            assertEquals(ReadwiseFailure.SERVER, redirected.failure)
            assertEquals(4, server.requestCount)
            assertEquals(0, elsewhere.requestCount)
            assertTrue(store.receipts("account").isEmpty())
        } finally {
            elsewhere.shutdown()
        }
    }

    @Test fun lookupStopsAtThePageBound() = runBlocking {
        server.enqueue(created(book = 5, highlight = null))
        repeat(ReadwiseExportSender.MAX_LOOKUP_PAGES) { server.enqueue(page(next = "more", 1L to "Other")) }

        val result = sender().send("t", "account", pending(1), {})

        assertEquals(ReadwiseFailure.SERVER, result.failure)
        assertEquals(1 + ReadwiseExportSender.MAX_LOOKUP_PAGES, server.requestCount)
    }

    @Test fun partialFailureKeepsConfirmedReceiptsOnly() = runBlocking {
        server.enqueue(created(book = 5, highlight = 1))
        server.enqueue(MockResponse().setResponseCode(400))
        val items = pending(3)

        val result = sender().send("t", "account", items, {})

        assertEquals(1, result.sentCount)
        assertEquals(2, result.unsentCount)
        assertEquals(ReadwiseFailure.REJECTED, result.failure)
        assertEquals(mapOf(items[0].annotationId to ReadwiseReceipt(1, items[0].fingerprint)), store.receipts("account"))
        assertEquals(2, server.requestCount)
    }

    @Test fun rateLimitWaitsForRetryAfterThenSucceeds() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "3"))
        server.enqueue(created(book = 5, highlight = 9))

        val result = sender().send("t", "account", pending(1), {})

        assertEquals(1, result.sentCount)
        assertEquals(listOf(3_000L), pauses)
        assertEquals(2, server.requestCount)
    }

    @Test fun serverErrorsStopAfterBoundedAttempts() = runBlocking {
        repeat(ReadwiseExportSender.MAX_ATTEMPTS) { server.enqueue(MockResponse().setResponseCode(503)) }

        val result = sender().send("t", "account", pending(5), {})

        assertEquals(0, result.sentCount)
        assertEquals(5, result.unsentCount)
        assertEquals(ReadwiseFailure.SERVER, result.failure)
        assertEquals(listOf(2_000L, 4_000L), pauses)
        assertEquals(ReadwiseExportSender.MAX_ATTEMPTS, server.requestCount)
        assertTrue(store.receipts("account").isEmpty())
    }

    @Test fun overlongRetryAfterIsReportedInsteadOfWaiting() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "3600"))

        val result = sender().send("t", "account", pending(5), {})

        assertEquals(ReadwiseFailure.RATE_LIMITED, result.failure)
        assertEquals(3600L, result.retryAfterSeconds)
        assertTrue(pauses.isEmpty())
    }

    @Test fun invalidTokenIsNotRetried() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))

        val result = sender().send("t", "account", pending(5), {})

        assertEquals(ReadwiseFailure.INVALID_TOKEN, result.failure)
        assertEquals(1, server.requestCount)
    }

    @Test fun cancellationPropagatesAndKeepsConfirmedHighlights() = runBlocking {
        server.enqueue(created(book = 5, highlight = 1))
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
        val items = pending(2)

        val job = launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) {
            ReadwiseExportSender(ReadwiseClient(readwiseHttpClient(), server.url("/")), store).send("t", "account", items, {})
        }
        server.takeRequest(5, TimeUnit.SECONDS)
        server.takeRequest(5, TimeUnit.SECONDS)
        job.cancelAndJoin()

        assertTrue(job.isCancelled)
        assertEquals(setOf(items[0].annotationId), store.receipts("account").keys)
    }

    private fun created(book: Long, highlight: Long?): MockResponse =
        MockResponse().setResponseCode(200).setBody("""[{"id":$book,"title":"Book","modified_highlights":[${highlight ?: ""}]}]""")

    private fun page(next: String?, vararg highlights: Pair<Long, String>): MockResponse {
        val results = highlights.joinToString(",") { (id, text) -> """{"id":$id,"text":"$text","note":""}""" }
        val nextJson = next?.let { "\"$it\"" } ?: "null"
        return MockResponse().setResponseCode(200).setBody("""{"count":${highlights.size},"next":$nextJson,"previous":null,"results":[$results]}""")
    }

    private fun highlightsIn(request: RecordedRequest): Int =
        Json.parseToJsonElement(request.body.readUtf8()).jsonObject.getValue("highlights").jsonArray.size
}

internal fun pending(count: Int, remoteId: Long? = null, note: String? = null): List<ReadwisePendingHighlight> = List(count) { index ->
    val payload = payload("Highlight $index", note = note)
    ReadwisePendingHighlight(
        annotationId = "a$index",
        bookId = "book",
        fingerprint = ReadwiseHighlightMapper.fingerprint(payload),
        payload = payload,
        remoteId = remoteId,
    )
}

internal fun locations(root: java.io.File, profileId: String = "adult-default"): ProfileStorageLocations = ProfileStorageLocations.forProfile(
    profileId = profileId,
    filesDirectory = java.io.File(root, "files"),
    cacheDirectory = java.io.File(root, "cache"),
    databaseDirectory = java.io.File(root, "db"),
)
