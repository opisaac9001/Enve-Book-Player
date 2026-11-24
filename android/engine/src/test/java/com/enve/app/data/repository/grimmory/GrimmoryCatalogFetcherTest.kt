package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.provider.CatalogFailureKind
import com.enve.core.data.provider.CatalogRejectionReason
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
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
import kotlinx.serialization.json.jsonObject
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
        val inventoryActive = AtomicInteger()
        val inventoryPeak = AtomicInteger()
        init {
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    requests += request
                    val url = requireNotNull(request.requestUrl)
                    val path = url.encodedPath
                    val page = url.queryParameter("page")?.toInt() ?: 0
                    val requestedSize = url.queryParameter("size")?.toInt() ?: 100
                    val size = if (mode == "capped") requestedSize.coerceAtMost(50) else requestedSize
                    val last = (total - 1).coerceAtLeast(0) / size
                    if (path == "/api/v1/books/ids") {
                        if (mode == "ids-denied") return reply("{}", 403)
                        if (!mode.startsWith("ids")) return reply("{}", 404)
                        val ids = (1..total).map { id -> when {
                            mode == "ids-invalid" && id == 1 -> JsonNull
                            mode == "ids-duplicate" && id == total -> JsonPrimitive(1)
                            else -> JsonPrimitive(id)
                        } }
                        return reply(JsonArray(ids).toString())
                    }
                    if (path == "/api/v1/books/page") {
                        if (mode == "denied") return reply("{}", 403)
                        if (mode == "legacy") return reply("{}", 404)
                        if (requestedSize > 100) return reply("{}", 400)
                        if (page == last && mode == "http") return reply("{}", 503)
                        if (page == last && mode == "parse") return reply("{broken")
                        val actualPage = if (page == last && mode == "duplicate") 0 else page
                        val items = (actualPage * size until minOf((actualPage + 1) * size, total)).map { index ->
                            val valid = book(index + 1)
                            when {
                                mode == "missing-first" && index == 0 -> JsonObject(valid - "id")
                                mode == "missing-last" && index == total - 1 -> JsonObject(valid - "id")
                                mode == "title" && index == 0 -> JsonObject(valid + ("metadata" to JsonObject(valid.getValue("metadata").jsonObject - "title")))
                                mode == "metadata" && index == 0 -> JsonObject(valid + ("metadata" to JsonObject(mapOf("authors" to JsonObject(mapOf("secret" to JsonPrimitive("private.invalid/account")))))))
                                mode == "wrong-library" && index == 0 -> JsonObject(valid + ("libraryId" to JsonPrimitive(2)))
                                else -> valid
                            }
                        }
                        val pageInfo = JsonObject(mapOf("number" to JsonPrimitive(if (mode == "wrong-page" && page == last) 0 else page), "size" to JsonPrimitive(size),
                            "totalElements" to JsonPrimitive(if (mode == "changed-count" && page == last) total - 1 else total), "totalPages" to JsonPrimitive((total + size - 1) / size)))
                        val body = JsonObject(mapOf("content" to JsonArray(items), "page" to pageInfo))
                        val response = reply(body.toString())
                        return if (page == last && mode == "timeout") response.setBodyDelay(500, TimeUnit.MILLISECONDS) else response
                    }
                    if (path == "/api/v1/books/batch") {
                        if (mode == "ids-conflict") return reply("{}", 404)
                        val ids = url.queryParameter("ids").orEmpty().split(',').filter { it.isNotBlank() }.map(String::toInt)
                        if (mode == "ids-inventory-http" && ids.first() == 2501) return reply("{}", 503)
                        if (mode == "ids-parallel-inventory") {
                            val active = inventoryActive.incrementAndGet()
                            inventoryPeak.updateAndGet { maxOf(it, active) }
                            try { Thread.sleep(30) } finally { inventoryActive.decrementAndGet() }
                        }
                        return reply(JsonArray(ids.filterNot { mode == "ids-missing" && it == 2601 }.map(::book)).toString())
                    }
                    if (path == "/api/v1/libraries/1/book") {
                        return reply(JsonArray(if (mode == "ids-conflict") emptyList() else (1..total).map(::book)).toString())
                    }
                    return reply("{}", 404)
                }
            }
            server.start()
        }

        private fun reply(body: String, status: Int = 200): MockResponse = MockResponse().setResponseCode(status)
            .setHeader("Content-Type", "application/json").setBody(body)

        private fun book(id: Int): JsonObject = JsonObject(mapOf(
            "id" to JsonPrimitive(id), "libraryId" to JsonPrimitive(1),
            "metadata" to JsonObject(mapOf("title" to JsonPrimitive("Synthetic $id"),
                "authors" to JsonArray(listOf(JsonPrimitive("Fixture Author"))),
                "publisher" to JsonPrimitive("Fixture Publisher"), "language" to JsonPrimitive("en"))),
            "primaryFile" to JsonObject(mapOf("id" to JsonPrimitive(id), "bookType" to JsonPrimitive("EPUB"),
                "fileName" to JsonPrimitive("fixture.epub"), "fileSizeKb" to JsonPrimitive(1234))),
            "alternativeFormats" to JsonArray(listOf(JsonObject(mapOf("id" to JsonPrimitive(id + 100_000),
                "bookType" to JsonPrimitive("AUDIOBOOK"), "fileName" to JsonPrimitive("fixture.m4b"))))),
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

    @Test fun bulkIdsAvoidPagedCatalogAndPreserveMetadata() = fetch("ids") { batch, fixture ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.isComplete)
        assertEquals("Synthetic 1", batch.books.first().title)
        assertEquals(listOf("Fixture Author"), batch.books.first().authors)
        assertEquals("Fixture Publisher", batch.books.first().publisher)
        assertEquals("en", batch.books.first().language)
        assertEquals("EPUB", batch.books.first().primaryFileType)
        assertEquals("fixture.epub", batch.books.first().primaryFileName)
        assertEquals(1234L, batch.books.first().fileSizeKb)
        assertTrue(batch.books.first().hasAudioFormat())
        assertTrue(fixture.requests.none { it.requestUrl?.encodedPath == "/api/v1/books/page" })
        assertEquals(50, fixture.requests.count { it.requestUrl?.encodedPath == "/api/v1/books/batch" })
        val ids = fixture.requests.single { it.requestUrl?.encodedPath == "/api/v1/books/ids" }.requestUrl!!
        assertEquals(listOf("library:1"), ids.queryParameterValues("facet"))
        assertEquals("-addedOn", ids.queryParameter("sort"))
        assertTrue(fixture.requests.none { it.requestUrl?.encodedPath.orEmpty().startsWith("/api/v1/app/") })
    }

    @Test fun deniedBulkIdsCannotFallBackToAnotherCatalog() = fetch("ids-denied") { batch, fixture ->
        assertEquals(CatalogFailureKind.ACCESS_DENIED, batch.report.failures.single().kind)
        assertEquals(1, fixture.requests.size)
    }

    @Test fun malformedAndDuplicateBulkIdsRemainIncomplete() {
        for (mode in listOf("ids-invalid", "ids-duplicate")) fetch(mode) { batch, _ ->
            assertEquals(4999, batch.books.size)
            assertFalse(batch.report.isComplete)
        }
    }

    @Test fun missingBulkInventoryPreservesOtherBooksWithoutClaimingComplete() = fetch("ids-missing") { batch, _ ->
        assertEquals(4999, batch.books.size)
        assertEquals(1, batch.report.rejections[CatalogRejectionReason.MISSING_INVENTORY])
        assertFalse(batch.report.isComplete)
    }

    @Test fun fiveThousandValidBooksCompleteAcrossFiftyBrowsePages() = fetch("valid") { batch, fixture ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.isComplete)
        val pages = fixture.requests.filter { it.requestUrl?.encodedPath == "/api/v1/books/page" }.map { it.requestUrl!! }
        assertEquals(50, pages.size)
        assertTrue(pages.all { it.queryParameterValues("facet") == listOf("library:1") })
        assertTrue(pages.all { it.queryParameter("sort") == "-addedOn" && it.queryParameter("size") == "100" })
        assertTrue(pages.none { it.queryParameter("libraryId") != null || it.queryParameter("dir") != null })
        assertEquals(0, fixture.requests.count { it.requestUrl?.encodedPath == "/api/v1/books/batch" })
        val first = batch.books.first()
        assertEquals("Synthetic 1", first.title)
        assertEquals("EPUB", first.primaryFileType)
        assertTrue(first.hasAudioFormat())
    }

    @Test fun formatInventoryUsesBoundedParallelRequests() = fetch("ids-parallel-inventory") { batch, fixture ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.isComplete)
        assertTrue(fixture.inventoryPeak.get() in 2..4)
    }

    @Test fun failedInventoryBatchKeepsOtherValidatedBooksAndReportsIncomplete() = fetch("ids-inventory-http") { batch, _ ->
        assertEquals(4900, batch.books.size)
        assertFalse(batch.report.isComplete)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.HTTP && it.httpStatus == 503 })
        assertTrue(batch.books.any { it.id == "5000" })
    }

    @Test fun serverPageSizeCapStillLoadsEveryBook() = fetch("capped") { batch, fixture ->
        assertEquals(5000, batch.books.size)
        assertTrue(batch.report.isComplete)
        val pages = fixture.requests.filter { it.requestUrl?.encodedPath == "/api/v1/books/page" }
        assertEquals(100, pages.size)
        assertEquals((0 until 100).toSet(), pages.map { it.requestUrl?.queryParameter("page")?.toInt() }.toSet())
        assertEquals("100", pages.first().requestUrl?.queryParameter("size"))
        assertTrue(pages.drop(1).all { it.requestUrl?.queryParameter("size") == "50" })
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
        assertEquals(4900, batch.books.size)
        assertFalse(batch.report.isComplete)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.HTTP && it.page == 49 && it.httpStatus == 503 })
    }

    @Test fun malformedWholePageIsNotARecordRejection() = fetch("parse") { batch, _ ->
        assertEquals(4900, batch.books.size)
        assertEquals(0, batch.report.rejectedCount)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.INVALID_PAGE && it.page == 49 })
    }

    @Test fun changedPageIdentityOrCountsCannotCompleteACatalog() {
        for (mode in listOf("wrong-page", "changed-count")) fetch(mode, total = 201) { batch, _ ->
            assertEquals(200, batch.books.size)
            assertFalse(batch.report.isComplete)
            assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.INVALID_PAGINATION })
        }
    }

    @Test fun laterTimeoutKeepsSafelyFetchedBooksAndRemainsIncomplete() = fetch("timeout") { batch, _ ->
        assertEquals(4900, batch.books.size)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.NETWORK && it.page == 49 })
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

    @Test fun contradictoryFallbackCannotBecomeAuthoritativeEmpty() = fetch("ids-conflict") { batch, _ ->
        assertFalse(batch.report.isComplete)
        assertTrue(batch.report.failures.any { it.kind == CatalogFailureKind.CONFLICTING_CATALOG })
    }

    @Test fun successfulEmptyCatalogRemainsAuthoritative() = fetch("valid", 0) { batch, _ ->
        assertTrue(batch.books.isEmpty())
        assertTrue(batch.report.isComplete)
    }

    @Test fun accessDeniedDoesNotBroadenToLegacyEndpoints() = fetch("denied") { batch, fixture ->
        assertTrue(batch.books.isEmpty())
        assertEquals(CatalogFailureKind.ACCESS_DENIED, batch.report.failures.single().kind)
        assertEquals(2, fixture.requests.size)
    }

    @Test fun unexpectedLibraryAndBadMetadataRejectIndividualRecords() {
        for (mode in listOf("wrong-library", "metadata")) fetch(mode) { batch, _ ->
            assertEquals(4999, batch.books.size)
            assertEquals(1, batch.report.rejectedCount)
            assertFalse(batch.report.toString().contains("private.invalid"))
        }
    }

    @Test fun repeatedPageCannotBeReportedComplete() = fetch("duplicate") { batch, _ ->
        assertEquals(4900, batch.books.size)
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
                    assertTrue(api.getCatalogBooks(listOf("library:scope-$index"), "-addedOn", 0, 100).catalogResponse().isSuccessful)
                }
            } }.awaitAll()
            assertEquals(20, fixture.requests.size)
            assertTrue(fixture.requests.all { "library:${it.getHeader("X-Fixture-Scope")}" == it.requestUrl?.queryParameter("facet") })
        }
    }

    @Test fun cancellationStopsTheScopedCatalogCall() = runBlocking {
        Fixture("timeout").use { fixture ->
            val api = Retrofit.Builder().baseUrl(fixture.server.url("/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(GrimmoryApi::class.java)
            val call = api.getCatalogBooks(listOf("library:1"), "-addedOn", 49, 100)
            try {
                withTimeout(50) { call.catalogResponse() }
                fail("Cancellation must propagate")
            } catch (_: TimeoutCancellationException) {
                assertTrue(call.isCanceled)
            }
        }
    }
}
