package com.enve.app.data.readwise

import com.enve.engine.readwise.ReadwiseFailure
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

class ReadwiseClientTest {
    private lateinit var server: MockWebServer
    private lateinit var client: ReadwiseClient

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
        client = ReadwiseClient(readwiseHttpClient(), server.url("/"))
    }

    @After fun tearDown() {
        server.shutdown()
    }

    @Test fun authCheckSendsTokenHeaderToAuthEndpoint() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(204))

        client.checkToken("abc123")

        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/api/v2/auth/", request.path)
        assertEquals("Token abc123", request.getHeader("Authorization"))
    }

    @Test fun authCheckRequiresNoContentStatus() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("<html>portal</html>"))

        val error = failureOf { client.checkToken("abc123") }

        assertEquals(ReadwiseFailure.SERVER, error.failure)
        assertFalse(error.retryable)
    }

    @Test fun unauthorizedMapsToInvalidToken() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(401))

        assertEquals(ReadwiseFailure.INVALID_TOKEN, failureOf { client.checkToken("bad") }.failure)
    }

    @Test fun rateLimitCarriesRetryAfterSeconds() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "7"))

        val error = failureOf { client.createHighlight("t", payload("a")) }

        assertEquals(ReadwiseFailure.RATE_LIMITED, error.failure)
        assertEquals(7L, error.retryAfterSeconds)
        assertTrue(error.retryable)
    }

    @Test fun redirectsAreNotFollowedSoTheTokenStaysOnTheOrigin() = runBlocking {
        val elsewhere = MockWebServer().apply { start() }
        try {
            server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", elsewhere.url("/steal").toString()))
            server.enqueue(MockResponse().setResponseCode(307).setHeader("Location", elsewhere.url("/steal").toString()))

            val auth = failureOf { client.checkToken("secret") }
            val page = failureOf { client.highlightsPage("secret", 7, 1) }

            assertEquals(ReadwiseFailure.SERVER, auth.failure)
            assertFalse(auth.retryable)
            assertEquals(ReadwiseFailure.SERVER, page.failure)
            assertFalse(page.retryable)
            assertEquals(0, elsewhere.requestCount)
        } finally {
            elsewhere.shutdown()
        }
    }

    @Test fun createHighlightPostsOneReadwisePayloadWithoutNullsAndParsesBooks() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""[{"id":5,"title":"Book","modified_highlights":[901]}]"""))

        val books = client.createHighlight("t", payload("Quoted text", note = "My note", location = 12, locationType = "page"))

        assertEquals(listOf(ReadwiseCreatedBook(5, listOf(901))), books)
        val request = server.takeRequest()
        assertEquals("POST", request.method)
        assertEquals("/api/v2/highlights/", request.path)
        assertEquals("Token t", request.getHeader("Authorization"))
        assertTrue(request.getHeader("Content-Type")!!.startsWith("application/json"))
        val highlights = Json.parseToJsonElement(request.body.readUtf8()).jsonObject["highlights"]!!.jsonArray
        assertEquals(1, highlights.size)
        val first = highlights[0].jsonObject
        assertEquals("Quoted text", first.string("text"))
        assertEquals("Book", first.string("title"))
        assertEquals("Author", first.string("author"))
        assertEquals("My note", first.string("note"))
        assertEquals("enve_book_player", first.string("source_type"))
        assertEquals("books", first.string("category"))
        assertEquals("12", first.string("location"))
        assertEquals("page", first.string("location_type"))
        assertEquals("2026-01-02T03:04:05Z", first.string("highlighted_at"))
        listOf("source_url", "highlight_url", "image_url").forEach { assertFalse(it in first) }
    }

    @Test fun createHighlightOmitsAbsentOptionalFields() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""[{"id":5,"modified_highlights":[]}]"""))

        assertEquals(listOf(ReadwiseCreatedBook(5, emptyList())), client.createHighlight("t", payload("Second")))

        val sent = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject["highlights"]!!.jsonArray[0].jsonObject
        assertFalse("note" in sent)
        assertFalse("location" in sent)
        assertFalse("location_type" in sent)
    }

    @Test fun createHighlightRejectsUnconfirmedSuccessBodies() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"detail":"ok"}"""))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""[{"modified_highlights":[1]}]"""))
        server.enqueue(MockResponse().setResponseCode(201).setBody("""[{"id":5,"modified_highlights":[1]}]"""))

        repeat(4) {
            val error = failureOf { client.createHighlight("t", payload("a")) }
            assertEquals(ReadwiseFailure.SERVER, error.failure)
            assertFalse(error.retryable)
        }
    }

    @Test fun updateHighlightPatchesTheConfirmedHighlight() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":42,"text":"Quoted text","note":"Edited"}"""))

        assertTrue(client.updateHighlight("t", 42, payload("Quoted text", note = "Edited", location = 3, locationType = "page").update()))

        val request = server.takeRequest()
        assertEquals("PATCH", request.method)
        assertEquals("/api/v2/highlights/42/", request.path)
        assertEquals("Token t", request.getHeader("Authorization"))
        val body = Json.parseToJsonElement(request.body.readUtf8()).jsonObject
        assertEquals(setOf("text", "note", "location", "location_type"), body.keys)
        assertEquals("Edited", body.string("note"))
    }

    @Test fun updateHighlightClearsRemovedNotes() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":42,"text":"Quoted text"}"""))

        client.updateHighlight("t", 42, payload("Quoted text").update())

        val body = Json.parseToJsonElement(server.takeRequest().body.readUtf8()).jsonObject
        assertEquals("", body.string("note"))
        assertFalse("location" in body)
    }

    @Test fun updateHighlightReportsMissingHighlightAndRejectsMismatchedConfirmation() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"id":43,"text":"x"}"""))

        assertFalse(client.updateHighlight("t", 42, payload("x").update()))
        assertEquals(ReadwiseFailure.SERVER, failureOf { client.updateHighlight("t", 42, payload("x").update()) }.failure)
    }

    @Test fun highlightsPageQueriesTheOriginWithFixedParameters() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"count":1,"next":"https://evil.example/page","results":[{"id":9,"text":"t","note":""}]}"""))

        val page = client.highlightsPage("t", 77, 3)

        assertEquals(listOf(ReadwiseRemoteHighlight(9, "t")), page.results)
        assertEquals("https://evil.example/page", page.next)
        val request = server.takeRequest()
        assertEquals("GET", request.method)
        assertEquals("/api/v2/highlights/?book_id=77&page_size=1000&page=3", request.path)
    }

    @Test fun highlightsPageRejectsMalformedPayloads() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"next":null}"""))
        server.enqueue(MockResponse().setResponseCode(200).setBody("""{"results":[{"id":"x","text":"t"}]}"""))

        repeat(2) { assertEquals(ReadwiseFailure.SERVER, failureOf { client.highlightsPage("t", 1, 1) }.failure) }
    }

    @Test fun cancellationCancelsTheInFlightCall() = runBlocking {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))

        val job = launch(Dispatchers.IO, start = CoroutineStart.UNDISPATCHED) { client.checkToken("t") }
        assertTrue(server.takeRequest(5, TimeUnit.SECONDS) != null)
        val started = System.nanoTime()
        job.cancelAndJoin()

        assertTrue(job.isCancelled)
        assertTrue(TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started) < 5)
    }

    @Test fun failureMappingCoversStatusFamilies() {
        assertNull(readwiseFailureFor(200, null))
        assertNull(readwiseFailureFor(204, null))
        assertEquals(ReadwiseFailure.INVALID_TOKEN, readwiseFailureFor(403, null)?.failure)
        assertEquals(ReadwiseFailure.REJECTED, readwiseFailureFor(400, null)?.failure)
        assertFalse(readwiseFailureFor(400, null)!!.retryable)
        assertEquals(ReadwiseFailure.SERVER, readwiseFailureFor(301, null)?.failure)
        assertFalse(readwiseFailureFor(301, null)!!.retryable)
        assertEquals(ReadwiseFailure.SERVER, readwiseFailureFor(503, null)?.failure)
        assertTrue(readwiseFailureFor(503, null)!!.retryable)
        assertNull(readwiseFailureFor(429, "soon")?.retryAfterSeconds)
        assertEquals(0L, readwiseFailureFor(429, "-3")?.retryAfterSeconds)
    }

    private suspend fun failureOf(block: suspend () -> Unit): ReadwiseRequestException {
        try {
            block()
        } catch (e: ReadwiseRequestException) {
            return e
        }
        throw AssertionError("Expected a Readwise failure")
    }

    private fun JsonObject.string(key: String): String = getValue(key).jsonPrimitive.content
}

internal fun payload(
    text: String,
    note: String? = null,
    location: Long? = null,
    locationType: String? = null,
) = ReadwiseHighlightPayload(
    text = text,
    title = "Book",
    author = "Author",
    sourceType = ReadwiseHighlightPayload.SOURCE_TYPE,
    category = ReadwiseHighlightPayload.CATEGORY,
    note = note,
    location = location,
    locationType = locationType,
    highlightedAt = "2026-01-02T03:04:05Z",
)
