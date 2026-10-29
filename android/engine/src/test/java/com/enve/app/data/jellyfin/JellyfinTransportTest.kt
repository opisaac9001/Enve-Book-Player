package com.enve.app.data.jellyfin

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.JellyfinAuthRequest
import com.enve.app.data.remote.dto.MediaBrowserItemsDto
import com.enve.core.data.remote.AuthHeaderContext
import com.enve.core.data.remote.XEmbyTokenAuthHeaderStrategy
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class JellyfinTransportTest {
    private val server = MockWebServer()
    private val token = "fixture-token"
    private val strategy = JellyfinAuthHeaderStrategy()
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun start() = server.start()

    @After
    fun stop() = server.shutdown()

    private fun api(authenticated: Boolean = false): GrimmoryApi {
        val client = OkHttpClient.Builder()
        if (authenticated) {
            client.addInterceptor { chain ->
                val original = chain.request()
                chain.proceed(strategy.apply(AuthHeaderContext(original, original.newBuilder(), token, "fixture-user")))
            }
        }
        return Retrofit.Builder()
            .baseUrl(server.url("/jellyfin/"))
            .client(client.build())
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
            .build()
            .create(GrimmoryApi::class.java)
    }

    @Test
    fun passwordLoginSendsModernClientMetadataAndExpectedPayload() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"AccessToken":"fixture-token"}"""))
        val response = api().jellyfinLogin(
            server.url("/jellyfin/Users/AuthenticateByName").toString(),
            "MediaBrowser Client=\"Enve\", Device=\"Android\", DeviceId=\"fixture-device\", Version=\"1.0\"",
            JellyfinAuthRequest("fixture-user", "fixture-password"),
        )
        assertEquals(token, response.body()?.accessToken)
        val request = server.takeRequest()
        assertEquals("/jellyfin/Users/AuthenticateByName", request.path)
        assertTrue(request.getHeader("Authorization")!!.startsWith("MediaBrowser Client="))
        assertNull(request.getHeader("X-Emby-Authorization"))
        assertEquals(
            Json.parseToJsonElement("""{"Username":"fixture-user","Pw":"fixture-password"}"""),
            Json.parseToJsonElement(request.body.readUtf8()),
        )
    }

    @Test
    fun loginKeepsItsDestinationWhenAnotherProviderIsConfigured() = runBlocking {
        val other = MockWebServer()
        other.start()
        try {
            server.enqueue(MockResponse().setBody("""{"AccessToken":"fixture-token"}"""))
            val client = Retrofit.Builder()
                .baseUrl(other.url("/kavita/"))
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType()))
                .build().create(GrimmoryApi::class.java)
            val response = client.jellyfinLogin(
                server.url("/jellyfin/Users/AuthenticateByName").toString(),
                "MediaBrowser Client=\"Enve\"",
                JellyfinAuthRequest("fixture-user", "fixture-password"),
            )
            assertEquals(200, response.code())
            assertEquals("/jellyfin/Users/AuthenticateByName", server.takeRequest().path)
            assertEquals(0, other.requestCount)
        } finally {
            other.shutdown()
        }
    }

    @Test
    fun modernServerAcceptsUserLibrariesItemsCoverAndMediaWithBasePath() = runBlocking {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.getHeader("Authorization") != "MediaBrowser Token=\"$token\"") {
                    return MockResponse().setResponseCode(401)
                }
                return when {
                    request.path == "/jellyfin/Users/Me" -> MockResponse().setBody("""{"Id":"user","Name":"fixture"}""")
                    request.path?.endsWith("/Views") == true || request.path?.contains("/Items?") == true ->
                        MockResponse().setBody("""{"Items":[],"TotalRecordCount":0}""")
                    request.path == "/jellyfin/Items/book/Images/Primary" -> MockResponse().setBody("fixture-cover")
                    request.path == "/jellyfin/Audio/book/stream?static=true" -> MockResponse().setBody("fixture-media")
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        val api = api(authenticated = true)
        assertEquals("user", api.jellyfinMe().jellyfinBody("user lookup").Id)
        assertTrue(api.jellyfinViews("user").jellyfinBody("library discovery").items.isEmpty())
        assertTrue(api.jellyfinItems("user", "library").jellyfinBody("item loading").items.isEmpty())
        assertEquals("fixture-cover", api.fetchRawUrl(server.url("/jellyfin/Items/book/Images/Primary").toString()).body()!!.string())
        assertEquals("fixture-media", api.fetchRawUrl(server.url("/jellyfin/Audio/book/stream?static=true").toString()).body()!!.string())
        repeat(5) {
            val request = server.takeRequest()
            assertTrue(request.path!!.startsWith("/jellyfin/"))
            assertNull(request.getHeader("X-Emby-Token"))
            assertFalse(request.path!!.contains(token))
        }
    }

    @Test
    fun previousServerContractAcceptsModernAndLegacyClients() {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                if (request.getHeader("Authorization") == "MediaBrowser Token=\"$token\"" ||
                    request.getHeader("X-Emby-Token") == token
                ) MockResponse().setBody("ok") else MockResponse().setResponseCode(401)
        }
        val original = Request.Builder().url(server.url("/Users/Me")).build()
        val client = OkHttpClient()
        for (auth in listOf(strategy, XEmbyTokenAuthHeaderStrategy())) {
            val request = auth.apply(AuthHeaderContext(original, original.newBuilder(), token, "fixture-user"))
            client.newCall(request).execute().use { assertEquals(200, it.code) }
        }
    }

    @Test
    fun modernStrategyReplacesStaleAuthorizationWithoutChangingOtherHeaders() {
        val original = Request.Builder().url(server.url("/cover?ApiKey=stale-fixture-token&size=200"))
            .header("Authorization", "Bearer stale-fixture-token")
            .header("X-Emby-Token", "stale-fixture-token")
            .header("X-Emby-Authorization", "MediaBrowser Token=\"stale-fixture-token\"")
            .header("Range", "bytes=0-99")
            .build()
        val request = strategy.apply(AuthHeaderContext(original, original.newBuilder(), token, "fixture-user"))
        assertEquals("MediaBrowser Token=\"$token\"", request.header("Authorization"))
        assertNull(request.header("X-Emby-Token"))
        assertNull(request.header("X-Emby-Authorization"))
        assertEquals("bytes=0-99", request.header("Range"))
        assertEquals("size=200", request.url.encodedQuery)
    }

    @Test
    fun failedCatalogRequestsAreErrorsRatherThanEmptyListsAndDoNotExposeBodies() {
        for (status in listOf(400, 401, 403, 500)) {
            val response = Response.error<MediaBrowserItemsDto>(status, "private-fixture-response".toResponseBody())
            val failure = assertThrows(IOException::class.java) { response.jellyfinBody("item loading") }
            assertTrue(failure.message!!.contains("HTTP $status"))
            assertFalse(failure.message!!.contains("private-fixture-response"))
        }
    }

    @Test
    fun validEmptyCatalogIsDistinctFromMissingSuccessfulResponseBody() {
        val empty = MediaBrowserItemsDto(emptyList(), 0)
        assertEquals(empty, Response.success(empty).jellyfinBody("item loading"))
        assertThrows(IOException::class.java) {
            Response.success<MediaBrowserItemsDto>(null).jellyfinBody("item loading")
        }
    }
}
