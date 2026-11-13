package com.enve.app.data.local

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.offline.resolvers.SiloTrackResolver
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.*
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.silo.*
import com.enve.silo.api.SiloApi
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

@RunWith(AndroidJUnit4::class)
class SiloLiveRepositoryTest {
    @Test fun liveDownloadsPlaybackOfflineReplayAndAnnotations() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "silo-live-test.json")
        assumeTrue("Requires isolated Silo lab fixtures", fixture.isFile)
        val config = JSONObject(fixture.readText())
        val base = config.getString("base_url")
        val identity = "silo-live-${UUID.randomUUID()}"
        val root = File(context.cacheDir, identity).also { it.mkdirs() }
        val job = SupervisorJob()
        val vault = CredentialVault.forProfile(context, identity)
        val registry = ConnectionRegistry(PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
            File(root, "connections.preferences_pb")
        })
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
        val transport = OkHttpClient()
        val login = JSONObject().put("username", config.getString("username")).put("password", config.getString("password"))
        val token = transport.newCall(Request.Builder().url("$base/api/v2/auth/login")
            .post(login.toString().toRequestBody("application/json".toMediaType())).build()).execute().use {
            assertEquals("Lab login", 200, it.code)
            JSONObject(checkNotNull(it.body).string()).getString("access_token")
        }
        val client = transport.newBuilder().addInterceptor { chain ->
            chain.proceed(chain.request().newBuilder().header("Authorization", "Bearer $token").build())
        }.build()
        val api = Retrofit.Builder().baseUrl("$base/").client(client)
            .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(SiloApi::class.java)
        val repository = SiloRepository(api, vault, registry, SiloPlaybackInstallations(api), SiloCatalogCursors())
        var stage = "catalog"
        try {
            registry.upsert(ProviderConnection(identity, BookSource.SILO, "Silo live verification", base, config.getString("username")))
            vault.put(CredentialVault.accessTokenKey(identity), token)
            withContext(ConnectionScope.asContextElement(identity) + Dispatchers.IO) {
                val libraries = repository.getLibraries().getOrThrow()
                assertEquals(2, libraries.size)
                val books = libraries.flatMap { repository.getBooks(it.id, 0, 20, "title", "asc").getOrThrow() }
                    .map { it.copy(connectionId = identity) }
                assertTrue(books.size >= 4)
                val ebook = books.first { it.title == "Birch Verification" }
                val audio = books.first { it.title == "Delta Verification Audio" }
                stage = "ebook download and progress"
                val resource = checkNotNull(repository.getEbookResource(ebook.id))
                client.newCall(Request.Builder().url(resource.url).header("X-Profile-Id", checkNotNull(vault.get("silo_profile_id_$identity")))
                    .header("Range", "bytes=0-1023").build()).execute().use {
                    assertEquals(206, it.code)
                    assertEquals(1024, checkNotNull(it.body).bytes().size)
                }
                val event = System.currentTimeMillis() - 2_000
                val locator = EpubBridgeCheckpointCodec.encode(EpubBridgeCheckpoint(
                    publicationSha256 = "fixture", providerFileId = resource.providerFileId,
                    observedAt = event, sourceEngine = ReaderEngineKind.FOLIATE,
                    epubCfi = "epubcfi(/6/2!/4/2:1)", totalProgression = 0.3,
                ))
                repository.syncEbookProgress(ebook.id, 0.3f, locator, event).getOrThrow()
                repository.syncEbookProgress(ebook.id, 0.1f, locator, event - 60_000).getOrThrow()
                assertEquals(0.3f, checkNotNull(repository.fetchEbookProgress(ebook).getOrThrow()).percentage, 0.001f)
                stage = "audiobook direct download"
                val stale = audio.copy(audioTracks = listOf(AudioTrack(index = 0, fileName = "old", durationMs = 90_000,
                    contentUrl = "$base/api/v1/stream/expired")))
                val download = SiloTrackResolver(repository).resolveTracks(stale).getOrThrow().single()
                val request = Request.Builder().url(download.url).header("Range", "bytes=65536-66559")
                download.httpHeaders.forEach { (key, value) -> request.header(key, value) }
                client.newCall(request.build()).execute().use { assertEquals(206, it.code); assertEquals(1024, checkNotNull(it.body).bytes().size) }
                stage = "playback negotiation and seek"
                val playback = repository.startPlaybackSession(stale).getOrThrow()
                try {
                    val url = checkNotNull(playback.audioTracks.single().contentUrl)
                    client.newCall(Request.Builder().url(url).header("Range", "bytes=65536-66559").build()).execute().use {
                        assertEquals(206, it.code); assertEquals(1024, checkNotNull(it.body).bytes().size)
                    }
                    repository.setPlaybackPaused(audio, 12, true).getOrThrow()
                    repository.setPlaybackPaused(audio, 13, false).getOrThrow()
                    repository.syncAudiobookProgress(audio, 20, 0.2f).getOrThrow()
                } finally { repository.stopPlaybackSession(audio).getOrThrow() }
                stage = "offline progress replay"
                repository.invalidateCaches()
                val queued = audio.copy(lastReadTime = System.currentTimeMillis())
                repository.syncAudiobookProgress(queued, 27, 0.3f).getOrThrow()
                repeat(2) { repository.syncAudiobookProgress(queued.copy(lastReadTime = queued.lastReadTime - 60_000), 4, 0.04f).getOrThrow() }
                assertEquals(27_000L, checkNotNull(repository.fetchAudiobookProgress(audio).getOrThrow()).positionMs)
                stage = "annotation conflict"
                val annotation = ReaderAnnotation(id = UUID.randomUUID().toString(), bookId = ebook.id,
                    cfi = "epubcfi(/6/2!/4/2:1)", selectedText = "Original Enve test", note = "first")
                val created = repository.pushAnnotations(ebook, listOf(annotation)).getOrThrow()
                assertEquals(1, created.accepted.size)
                val remote = repository.fetchAnnotations(ebook).getOrThrow().single { it.serverId == annotation.id }
                val updated = repository.pushAnnotations(ebook, listOf(remote.copy(note = "newer"))).getOrThrow()
                assertEquals(1, updated.accepted.size)
                val conflict = repository.pushAnnotations(ebook, listOf(remote.copy(note = "stale"))).getOrThrow()
                assertEquals(1, conflict.conflicts.size)
                assertTrue(conflict.accepted.isEmpty())
                repository.deleteRemoteAnnotation(ebook, annotation.id).getOrThrow()
            }
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            throw AssertionError("Silo live verification failed at $stage: ${failure.javaClass.simpleName}")
        } finally {
            job.cancelAndJoin()
            vault.clearAll()
            root.deleteRecursively()
        }
    }
}
