package com.enve.app.data.local

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.offline.resolvers.SiloTrackResolver
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ServerProbe
import com.enve.core.data.provider.ServerProbeOutcome
import com.enve.core.data.remote.ConnectionScope
import com.enve.silo.SiloCatalogCursors
import com.enve.silo.SiloPlaybackInstallations
import com.enve.silo.SiloRepository
import com.enve.silo.api.SiloApi
import java.io.File
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

@RunWith(AndroidJUnit4::class)
class SiloV2RepositoryTest {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Test
    fun profilePagingFreshStreamRangesAndOfflineReplayUseV2() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profile = "silo-repository-${UUID.randomUUID()}"
        val root = File(context.cacheDir, profile).also { it.mkdirs() }
        val job = SupervisorJob()
        val vault = CredentialVault.forProfile(context, profile)
        val registry = ConnectionRegistry(PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
            File(root, "connections.preferences_pb")
        })
        val server = MockWebServer()
        val requests = CopyOnWriteArrayList<RecordedRequest>()
        val installation = "11111111-1111-4111-8111-111111111111"
        val session = "22222222-2222-4222-8222-222222222222"
        fun response(body: String) = MockResponse().setHeader("Content-Type", "application/json").setBody(body)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val url = checkNotNull(request.requestUrl)
                return when (url.encodedPath) {
                    "/api/v2/system/info" -> response("""{"api_major":2,"links":{"identity":"/api/v2/system/identity"}}""")
                    "/api/v2/profiles" -> response("""{"items":[{"id":"profile-opaque","name":"Reader","is_primary":true}]}""")
                    "/api/v2/user/libraries" -> response("""{"items":[{"id":"library-opaque","name":"Audio","type":"audiobooks"}]}""")
                    "/api/v2/catalog" -> if (url.queryParameter("cursor") == null) {
                        response("""{"items":[],"page":{"next_cursor":"next","has_more":true}}""")
                    } else response("""{"items":[{"content_id":"audio:opaque","title":"Book","type":"audiobook"}],"page":{"has_more":false}}""")
                    "/api/v2/catalog/items/audio:opaque" -> response("""{"content_id":"audio:opaque","title":"Book","type":"audiobook","versions":[{"file_id":"file-opaque","file_name":"audio.m4b","container":"m4b","duration":90}]}""")
                    "/api/v2/playback/capabilities" -> response("""{"state":"available","allowed":true,"installation_id":"$installation","protocol_versions":[3],"features":["sequenced_progress_v1"]}""")
                    "/api/v2/playback/start" -> response("""{"protocol_version":3,"outcome":"playable","session_id":"$session","playback_plan":{"protocol_version":3,"plan_id":"p","delivery":"original_http","stream":{"url":"/api/v2/stream/$session","protocol":"http_progressive"},"timeline":{"source_start_seconds":0,"player_start_seconds":0,"timeline_offset_seconds":0},"source":{"media_file_id":"file-opaque","duration_seconds":90},"requested_media_file_id":"file-opaque","effective_media_file_id":"file-opaque"}}""")
                    "/api/v2/direct-download", "/api/v2/stream/$session" -> MockResponse().setResponseCode(206).setHeader("Content-Range", "bytes 2-5/8").setBody("cdef")
                    "/api/v2/playback/$session/progress" -> response("""{"outcome":"applied"}""")
                    "/api/v2/sync/progress" -> response("""{"items":[{"media_item_id":"audio:opaque","status":"success"}],"summary":{"succeeded":1,"failed":0}}""")
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        val base = server.url("/").toString().trimEnd('/')
        val client = OkHttpClient()
        val api = Retrofit.Builder().baseUrl("$base/").client(client)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(SiloApi::class.java)
        val repository = SiloRepository(api, vault, registry, SiloPlaybackInstallations(api), SiloCatalogCursors())
        try {
            registry.upsert(ProviderConnection("fixture", BookSource.SILO, "Silo", base, "reader"))
            vault.put(CredentialVault.accessTokenKey("fixture"), "fixture-token")
            val detected = ServerProbe.detect(base)
            assertTrue("$detected; requested=${requests.map { it.path }}", detected is ServerProbeOutcome.Identified)
            assertEquals(BookSource.SILO, (detected as ServerProbeOutcome.Identified).server.source)
            withContext(ConnectionScope.asContextElement("fixture") + Dispatchers.IO) {
                assertEquals("library-opaque", repository.getLibraries().getOrThrow().single().id)
                val books = repository.getBooks("library-opaque", 0, 20, "title", "asc").getOrThrow()
                val original = books.single().copy(connectionId = "fixture", lastReadTime = 1_767_323_045_000L)
                val stale = original.copy(audioTracks = listOf(AudioTrack(index = 0, fileName = "old", durationMs = 90_000, contentUrl = "$base/api/v1/stream/old")))
                assertNull(repository.getAudioTracks(stale).getOrThrow().single().contentUrl)
                val local = stale.copy(audioTracks = stale.audioTracks.map { it.copy(contentUrl = "file:///kept/audio.m4b") })
                assertEquals("file:///kept/audio.m4b", repository.getAudioTracks(local).getOrThrow().single().contentUrl)
                val download = SiloTrackResolver(repository).resolveTracks(stale).getOrThrow().single()
                assertTrue(download.url.contains("/api/v2/direct-download?file_id=file-opaque"))
                assertFalse(requests.any { it.requestUrl?.encodedPath?.contains("/playback/") == true })
                val request = Request.Builder().url(download.url).header("Range", "bytes=2-5")
                download.httpHeaders.forEach { (name, value) -> request.header(name, value) }
                client.newCall(request.build()).execute().use {
                    assertEquals(206, it.code)
                    assertEquals("cdef", it.body?.string())
                }
                val direct = requests.single { it.requestUrl?.encodedPath == "/api/v2/direct-download" }
                assertEquals("profile-opaque", direct.getHeader("X-Profile-Id"))
                assertEquals("Bearer fixture-token", direct.getHeader("Authorization"))
                val playback = repository.startPlaybackSession(stale, persistProgress = false).getOrThrow()
                val stream = checkNotNull(playback.audioTracks.single().contentUrl)
                assertTrue(stream.contains("/api/v2/stream/"))
                client.newCall(Request.Builder().url(stream).header("Range", "bytes=2-5").build()).execute().use {
                    assertEquals(206, it.code)
                    assertEquals("cdef", it.body?.string())
                }
                repository.setPlaybackPaused(original, 10, true).getOrThrow()
                repository.syncAudiobookProgress(original, 20, 0.2f).getOrThrow()
                repository.invalidateCaches()
                repeat(2) { repository.syncAudiobookProgress(original, 20, 0.2f).getOrThrow() }
            }
            val start = requests.single { it.requestUrl?.encodedPath == "/api/v2/playback/start" }
            val startBody = json.parseToJsonElement(start.body.clone().readUtf8()).jsonObject
            assertEquals("client", startBody["progress_persistence"]!!.jsonPrimitive.content)
            assertEquals(0.0, startBody["start_position"]!!.jsonPrimitive.double, 0.0)
            val catalog = requests.filter { it.requestUrl?.encodedPath == "/api/v2/catalog" }
            assertEquals(listOf(null, "next"), catalog.map { it.requestUrl?.queryParameter("cursor") })
            assertTrue(catalog.all { it.getHeader("X-Profile-Id") == "profile-opaque" && it.requestUrl?.queryParameter("sort") == "title" })
            val samples = requests.filter { it.requestUrl?.encodedPath?.endsWith("/progress") == true && it.requestUrl?.encodedPath?.contains("/playback/") == true }
            assertEquals(listOf(1, 2), samples.map { json.parseToJsonElement(it.body.clone().readUtf8()).jsonObject["sequence"]!!.jsonPrimitive.int })
            val replay = requests.filter { it.requestUrl?.encodedPath == "/api/v2/sync/progress" }
            assertEquals(2, replay.size)
            assertEquals(replay[0].body.clone().readUtf8(), replay[1].body.clone().readUtf8())
            assertTrue(replay[0].body.clone().readUtf8().contains("2026-01-02T03:04:05.000Z"))
            assertEquals("bytes=2-5", requests.single { it.requestUrl?.encodedPath == "/api/v2/stream/$session" }.getHeader("Range"))
        } finally {
            server.shutdown()
            job.cancelAndJoin()
            vault.clearAll()
            root.deleteRecursively()
        }
    }
}
