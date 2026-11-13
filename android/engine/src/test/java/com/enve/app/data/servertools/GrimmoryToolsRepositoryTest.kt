package com.enve.app.data.servertools

import com.enve.app.data.remote.GrimmoryApi
import com.enve.engine.servertools.ServerFeatureUnsupportedException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import retrofit2.HttpException
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class GrimmoryToolsRepositoryTest {
    private val json = Json { ignoreUnknownKeys = true }

    private val server = MockWebServer()
    private lateinit var repository: GrimmoryToolsRepository
    private var status = 404
    private var validEmpty = false
    private var recommendations: String? = null

    @Before
    fun setUp() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                recommendations?.let { body ->
                    if (request.path?.contains("/recommendations") == true) {
                        return MockResponse().setHeader("Content-Type", "application/json").setBody(body)
                    }
                }
                if (validEmpty && request.path?.startsWith("/api/v1/user-stats/reading/genres") == true) {
                    return MockResponse().setHeader("Content-Type", "application/json").setBody("[]")
                }
                if (validEmpty && request.path?.startsWith("/api/v1/app/notebook/books") == true) {
                    return MockResponse().setHeader("Content-Type", "application/json").setBody("{\"content\":[]}")
                }
                return MockResponse().setResponseCode(status)
            }
        }
        server.start()
        repository = GrimmoryToolsRepository(
            Retrofit.Builder().baseUrl(server.url("/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build().create(GrimmoryApi::class.java),
        )
    }

    @After
    fun tearDown() { server.shutdown() }

    @Test
    fun `service and permission failures remain errors`() = runBlocking {
        for (code in listOf(401, 403, 503)) {
            status = code
            assertEquals(code, (repository.stats().exceptionOrNull() as HttpException).code())
            assertEquals(code, (repository.notes(12).exceptionOrNull() as HttpException).code())
        }
    }

    @Test
    fun `unsupported endpoints are distinct from valid empty activity`() = runBlocking {
        for (code in listOf(404, 405)) {
            status = code
            assertTrue(repository.stats().exceptionOrNull() is ServerFeatureUnsupportedException)
            assertTrue(repository.notes(12).exceptionOrNull() is ServerFeatureUnsupportedException)
        }
        validEmpty = true
        assertNull(repository.stats().getOrThrow())
        assertEquals(emptyList<GrimmoryNote>(), repository.notes(12).getOrThrow())
    }

    @Test
    fun `a later successful request recovers from optional feature failure`() = runBlocking {
        status = 503
        assertTrue(repository.stats().isFailure)
        assertTrue(repository.notes(12).isFailure)
        status = 404
        validEmpty = true
        assertTrue(repository.stats().isSuccess)
        assertTrue(repository.notes(12).isSuccess)
    }

    @Test
    fun `legacy recommendations retain score ordering`() = runBlocking {
        recommendations = """[{"book":{"id":43},"similarityScore":0.2},{"book":{"id":"42"},"similarityScore":0.9}]"""
        assertEquals(listOf("42", "43"), repository.recommendedBookIds("1", 12).getOrThrow())
        recommendations = """[{"book":{"id":44},"similarityScore":0.5},{"book":{"id":1},"similarityScore":0.9},{"book":{"id":45},"similarityScore":0.5},{"book":{"id":44},"similarityScore":0.1}]"""
        assertEquals(listOf("44", "45"), repository.recommendedBookIds("1", 12).getOrThrow())
    }

    @Test
    fun `plain book recommendations preserve server order without duplicates or the current book`() = runBlocking {
        recommendations = """[{"id":43,"metadata":{"title":"First"}},{"id":"42"},{"id":43},{"id":1}]"""
        assertEquals(listOf("43", "42"), repository.recommendedBookIds("1", 12).getOrThrow())
    }

    @Test
    fun `malformed recommendation bodies fail instead of guessing`() = runBlocking {
        for (body in listOf("""{"id":42}""", """[42]""", "not json")) {
            recommendations = body
            assertTrue(repository.recommendedBookIds("1", 12).isFailure)
        }
    }

    @Test
    fun `empty and missing recommendation IDs do not produce phantom books`() = runBlocking {
        for (body in listOf("[]", """[{"id":""},{"book":null},{}]""")) {
            recommendations = body
            assertEquals(emptyList<String>(), repository.recommendedBookIds("1", 12).getOrThrow())
        }
    }

    @Test
    fun `recommendation errors remain failures and unsupported is null`() = runBlocking {
        for (code in listOf(401, 403, 503)) {
            status = code
            assertTrue(repository.recommendedBookIds("1", 12).isFailure)
        }
        status = 404
        assertNull(repository.recommendedBookIds("1", 12).getOrThrow())
    }

}
