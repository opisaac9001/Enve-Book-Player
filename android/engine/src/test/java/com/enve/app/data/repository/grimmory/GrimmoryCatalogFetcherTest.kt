package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.provider.CatalogFailureKind
import com.enve.core.data.provider.CatalogRejectionReason
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.TimeoutCancellationException
import com.enve.core.data.remote.ConnectionScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.*
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class GrimmoryCatalogFetcherTest {
    private val json = Json { ignoreUnknownKeys = true; coerceInputValues = true }

    private class Fixture(val mode: String, val total: Int = 5000) : AutoCloseable {
        val server = MockWebServer()
        val requests = CopyOnWriteArrayList<RecordedRequest>()
        init {
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests += request
                    val url = requireNotNull(request.requestUrl)
                    val path = url.encodedPath
                    val page = url.queryParameter("page")?.toInt() ?: 0
                    val size = url.queryParameter("size")?.toInt() ?: 500
                    val last = (total - 1).coerceAtLeast(0) / size
                    if (path == "/api/v1/app/books") {
                        if (mode == "denied") return reply("{}", 403)
                        if (mode == "legacy") return reply("{}", 404)
                        if (page == last && mode == "http") return reply("{}", 503)
                        if (page == last && mode == "parse") return reply("{broken")
                        val actualPage = if (page == last && mode == "duplicate") 0 else page
                        val items = (actualPage * size until minOf((actualPage + 1) * size, total)).map { index ->
                            val valid = book(index + 1)
                            when {
                                mode == "missing-first" && index == 0 -> JsonObject(valid - "id")
                                mode == "missing-last" && index == total - 1 -> JsonObject(valid - "id")
                                mode == "title" && index == 0 -> JsonObject(valid - "title")
                                mode == "metadata" && index == 0 -> JsonObject(valid + ("authors" to JsonObject(mapOf("secret" to JsonPrimitive("private.invalid/account")))))
                                mode == "wrong-library" && index == 0 -> JsonObject(valid + ("libraryId" to JsonPrimitive(2)))
                                else -> valid
                            }
                        }
                        val body = JsonObject(mapOf("content" to JsonArray(items), "size" to JsonPrimitive(size),
                            "totalPages" to JsonPrimitive((total + size - 1) / size), "totalElements" to JsonPrimitive(total)))
                        val response = reply(body.toString())
                        return if (page == last && mode == "timeout") response.setBodyDelay(500, TimeUnit.MILLISECONDS) else response
                    }
                    if (path == "/api/v1/books/batch") {
                        if (mode == "conflict") return reply("{}", 404)
                        val ids = url.queryParameter("ids").orEmpty().split(',').filter { it.isNotBlank() }.map(String::toInt)
                        return reply(JsonArray(ids.map(::book)).toString())
                    }
                    if (path == "/api/v1/libraries/1/book") {
                        return reply(JsonArray(if (mode == "conflict") emptyList() else (1..total).map(::book)).toString())
                    }
                    return reply("{}", 404)
                }
            }
            server.start()
        }

        private fun reply(body: String, status: Int = 200): MockResponse = MockResponse().setResponseCode(status)
            .setHeader("Content-Type", "application/json").setBody(body)

        private fun book(id: Int): JsonObject = JsonObject(mapOf(
            "id" to JsonPrimitive(id), "title" to JsonPrimitive("Synthetic $id"), "libraryId" to JsonPrimitive(1),
            "primaryFileType" to JsonPrimitive("EPUB"),
            "primaryFile" to JsonObject(mapOf("id" to JsonPrimitive(id), "bookType" to JsonPrimitive("EPUB"))),
        ))

        override fun close() = server.shutdown()
    }

    private fun fetch(mode: String, total: Int = 5000, verify: (GrimmoryCatalogBatch, Fixture) -> Unit) = runBlocking {
        Fixture(mode, total).use { fixture ->
            val api = Retrofit.Builder().baseUrl(fixture.server.url("/"))
                .client(OkHttpClient.Builder().readTimeout(if (mode == "timeout") 150 else 10000, TimeUnit.MILLISECONDS).build())
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(GrimmoryApi::class.java)
            verify(GrimmoryCatalogFetcher(api, json).fetch("1", 0, 500, "addedOn", "desc"), fixture)
        }
    }

    @Test fun fiveThousandValidBooksCompleteAcrossTenPages() = fetch("valid") { batch, fixture ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.isComplete)
        assertEquals(10, fixture.requests.count { it.requestUrl?.encodedPath == "/api/v1/app/books" })
        assertEquals(50, fixture.requests.count { it.requestUrl?.encodedPath == "/api/v1/books/batch" })
    }

    @Test fun missingIdentityEarlyAndLateRejectsOnlyOneRecord() {
        for (mode in listOf("missing-first", "missing-last")) fetch(mode) { batch, _ ->
            assertEquals(4999, batch.books.size)
            assertFalse(batch.report.isComplete)
            assertEquals(mapOf(CatalogRejectionReason.MISSING_ID to 1), batch.report.rejections)
            assertTrue(batch.report.failures.isEmpty())
            assertTrue(batch.books.all { it.id.isNotBlank() })
        }
    }

    @Test fun missingTitleStillLoadsEveryBook() = fetch("title") { batch, _ ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.isComplete)
    }

    @Test fun laterHttpFailureKeepsAllSafelyFetchedBooks() = fetch("http") { batch, _ ->
        assertEquals(4500, batch.books.size)
        assertFalse(batch.report.isComplete)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.HTTP && it.page == 9 && it.httpStatus == 503 })
    }

    @Test fun malformedWholePageIsNotARecordRejection() = fetch("parse") { batch, _ ->
        assertEquals(4500, batch.books.size)
        assertEquals(0, batch.report.rejectedCount)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.INVALID_PAGE && it.page == 9 })
    }

    @Test fun laterTimeoutKeepsSafelyFetchedBooksAndRemainsIncomplete() = fetch("timeout") { batch, _ ->
        assertEquals(4500, batch.books.size)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.NETWORK && it.page == 9 })
    }

    @Test fun legacyEndpointIsFetchedOnceWithoutPaginationParameters() {
        for (total in listOf(500, 5000)) fetch("legacy", total) { batch, fixture ->
            assertEquals(total, batch.books.size)
            assertTrue(batch.report.isComplete)
            val legacy = fixture.requests.filter { it.requestUrl?.encodedPath == "/api/v1/libraries/1/book" }
            assertEquals(1, legacy.size)
            assertNull(legacy.single().requestUrl?.query)
        }
    }

    @Test fun contradictoryFallbackCannotBecomeAuthoritativeEmpty() = fetch("conflict") { batch, _ ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.CONFLICTING_CATALOG })
    }

    @Test fun successfulEmptyCatalogRemainsAuthoritative() = fetch("valid", 0) { batch, _ ->
        assertTrue(batch.books.isEmpty())
        assertTrue(batch.report.isComplete)
    }

    @Test fun accessDeniedDoesNotBroadenToLegacyEndpoints() = fetch("denied") { batch, fixture ->
        assertTrue(batch.books.isEmpty())
        assertEquals(CatalogFailureKind.ACCESS_DENIED, batch.report.failures.single().kind)
        assertEquals(1, fixture.requests.size)
    }

    @Test fun unexpectedLibraryAndBadMetadataRejectIndividualRecords() {
        for (mode in listOf("wrong-library", "metadata")) fetch(mode) { batch, _ ->
            assertEquals(4999, batch.books.size)
            assertEquals(1, batch.report.rejectedCount)
            assertFalse(batch.report.toString().contains("private.invalid"))
        }
    }

    @Test fun repeatedPageCannotBeReportedComplete() = fetch("duplicate") { batch, _ ->
        assertEquals(4500, batch.books.size)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.INVALID_PAGINATION })
    }

    @Test fun catalogCallsKeepTheirOriginatingConnectionScope() = runBlocking {
        Fixture("valid").use { fixture ->
            val client = OkHttpClient.Builder().addInterceptor { chain ->
                chain.proceed(chain.request().newBuilder()
                    .header("X-Fixture-Scope", ConnectionScope.getConnectionId().orEmpty()).build())
            }.build()
            client.dispatcher.maxRequestsPerHost = 1
            val api = Retrofit.Builder().baseUrl(fixture.server.url("/")).client(client)
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(GrimmoryApi::class.java)
            (1..20).map { index -> async {
                withContext(ConnectionScope.asContextElement("scope-$index")) {
                    assertTrue(api.getCatalogBooks("scope-$index", 0, 500, "addedOn", "desc").catalogResponse().isSuccessful)
                }
            } }.awaitAll()
            assertEquals(20, fixture.requests.size)
            assertTrue(fixture.requests.all { it.getHeader("X-Fixture-Scope") == it.requestUrl?.queryParameter("libraryId") })
        }
    }

    @Test fun cancellationStopsTheScopedCatalogCall() = runBlocking {
        Fixture("timeout").use { fixture ->
            val api = Retrofit.Builder().baseUrl(fixture.server.url("/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(GrimmoryApi::class.java)
            val call = api.getCatalogBooks("1", 9, 500, "addedOn", "desc")
            try {
                withTimeout(50) { call.catalogResponse() }
                fail("Cancellation must propagate")
            } catch (_: TimeoutCancellationException) {
                assertTrue(call.isCanceled)
            }
        }
    }
}
