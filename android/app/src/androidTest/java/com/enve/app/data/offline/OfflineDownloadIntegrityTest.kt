package com.enve.app.data.offline

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OfflineDownloadIntegrityTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val parentScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var root: File
    private lateinit var database: ReaderDatabase
    private lateinit var storage: OfflineAudioStorage
    private lateinit var locations: ProfileStorageLocations
    private val requests = mutableListOf<Request>()
    private var respond: (Request) -> Response = { ok(it, "abcdef") }
    private val book = Book(id = "integrity-book", title = "Integrity", source = BookSource.AUDIOBOOKSHELF)
    private val key = book.offlineDownloadKey

    @Before
    fun setUp() {
        root = File(context.cacheDir, "offline-download-integrity-${UUID.randomUUID()}")
        check(root.mkdirs())
        database = Room.inMemoryDatabaseBuilder(context, ReaderDatabase::class.java).build()
        locations = ProfileStorageLocations.forProfile(
            profileId = "download-integrity",
            filesDirectory = File(root, "files"),
            cacheDirectory = File(root, "cache"),
            databaseDirectory = File(root, "databases"),
        )
        storage = OfflineAudioStorage(locations)
    }

    @After
    fun tearDown() {
        runBlocking { parentScope.coroutineContext[Job]!!.cancelAndJoin() }
        database.close()
        root.deleteRecursively()
    }

    @Test
    fun resumeSendsIfRangeWithTheStoredValidator() = runBlocking {
        storage.createTrackTempFile(key, 0).writeText("abc")
        storage.trackResumeValidatorFile(key, 0).writeText("\"v1\"")
        respond = { request ->
            if (request.header("Range") == "bytes=3-" && request.header("If-Range") == "\"v1\"") {
                partial(request, "def", "bytes 3-5/6")
            } else {
                ok(request, "abcdef")
            }
        }

        assertEquals(DownloadRunOutcome.COMPLETED, manager().runDownload(book))

        assertEquals("\"v1\"", requests.single().header("If-Range"))
        assertEquals("abcdef", trackFile().readText())
        assertFalse(storage.trackResumeValidatorFile(key, 0).exists())
        assertEquals(6L, storage.getManifest(key)!!.tracks.single().bytes)
    }

    @Test
    fun changedValidatorOnPartialResponseRequiresFullRetry() = runBlocking {
        storage.createTrackTempFile(key, 0).writeText("abc")
        storage.trackResumeValidatorFile(key, 0).writeText("\"v1\"")
        respond = { request ->
            partial(request, "xyz", "bytes 3-5/6").newBuilder().header("ETag", "\"v2\"").build()
        }

        assertEquals(DownloadRunOutcome.RETRY, manager().runDownload(book, finalAttempt = false))
        assertNull(storage.getManifest(key))
        assertFalse(storage.trackResumeValidatorFile(key, 0).exists())

        respond = { ok(it, "uvwxyz") }
        assertEquals(DownloadRunOutcome.COMPLETED, manager().runDownload(book))
        assertNull(requests.last().header("Range"))
        assertEquals("uvwxyz", trackFile().readText())
    }

    @Test
    fun partialWithoutValidatorRestartsFromZero() = runBlocking {
        storage.createTrackTempFile(key, 0).writeText("stale")

        assertEquals(DownloadRunOutcome.COMPLETED, manager().runDownload(book))

        assertNull(requests.single().header("Range"))
        assertEquals("abcdef", trackFile().readText())
    }

    @Test
    fun changedRepresentationReplacesThePartialFile() = runBlocking {
        storage.createTrackTempFile(key, 0).writeText("abc")
        storage.trackResumeValidatorFile(key, 0).writeText("\"v1\"")
        respond = { ok(it, "uvwxyz") }

        assertEquals(DownloadRunOutcome.COMPLETED, manager().runDownload(book))

        assertEquals("uvwxyz", trackFile().readText())
    }

    @Test
    fun serverSizeThatDisagreesWithTheManifestIsRejected() = runBlocking {
        val tracks = listOf(ResolvedTrack(0, "Track", 1_000L, "http://offline.test/track.mp3", sizeBytes = 10L))

        val retrying = manager(tracks)
        assertEquals(DownloadRunOutcome.RETRY, retrying.runDownload(book, finalAttempt = false))
        assertFalse(storage.isDownloaded(key))
        assertEquals(OfflineDownloadStatus.QUEUED, retrying.progressByDownloadKey.value[key]?.status)

        val final = manager(tracks)
        assertEquals(DownloadRunOutcome.FAILED, final.runDownload(book, finalAttempt = true))
        assertEquals(OfflineDownloadStatus.FAILED, final.progressByDownloadKey.value[key]?.status)
        assertNull(storage.existingTrackFinalFile(key, 0))
    }

    @Test
    fun replacedTrackWithTheSameSizeIsDownloadedAgain() = runBlocking {
        respond = { request -> if (request.url.encodedPath == "/one.mp3") ok(request, "abcdef") else status(request, 404) }
        assertEquals(DownloadRunOutcome.FAILED, manager(twoTracks(firstAssetId = "ino-1")).runDownload(book))

        respond = { request -> ok(request, if (request.url.encodedPath == "/one.mp3") "uvwxyz" else "ghijkl") }
        assertEquals(DownloadRunOutcome.COMPLETED, manager(twoTracks(firstAssetId = "ino-2")).runDownload(book))

        assertEquals("uvwxyz", trackFile().readText())
    }

    @Test
    fun unchangedTrackIsReusedOnResume() = runBlocking {
        respond = { request -> if (request.url.encodedPath == "/one.mp3") ok(request, "abcdef") else status(request, 404) }
        assertEquals(DownloadRunOutcome.FAILED, manager(twoTracks(firstAssetId = "ino-1")).runDownload(book))

        requests.clear()
        respond = { request -> ok(request, if (request.url.encodedPath == "/one.mp3") "uvwxyz" else "ghijkl") }
        assertEquals(DownloadRunOutcome.COMPLETED, manager(twoTracks(firstAssetId = "ino-1")).runDownload(book))

        assertEquals("abcdef", trackFile().readText())
        assertEquals(listOf("/two.mp3"), requests.map { it.url.encodedPath })
    }

    @Test
    fun trackDownloadedWithoutAStoredAssetIdIsReused() = runBlocking {
        storage.createTrackFinalFile(key, 0, "mp3").writeText("abcdef")
        respond = { request -> ok(request, if (request.url.encodedPath == "/one.mp3") "uvwxyz" else "ghijkl") }

        assertEquals(DownloadRunOutcome.COMPLETED, manager(twoTracks(firstAssetId = "ino-2")).runDownload(book))

        assertEquals("abcdef", trackFile().readText())
        assertEquals(listOf("/two.mp3"), requests.map { it.url.encodedPath })
    }

    @Test
    fun clientErrorsFailWithoutRetrying() = runBlocking {
        respond = { status(it, 404) }
        val manager = manager()

        assertEquals(DownloadRunOutcome.FAILED, manager.runDownload(book, finalAttempt = false))
        assertEquals(OfflineDownloadStatus.FAILED, manager.progressByDownloadKey.value[key]?.status)
    }

    @Test
    fun serverErrorsRetryUntilTheFinalAttempt() = runBlocking {
        respond = { status(it, 503) }

        assertEquals(DownloadRunOutcome.RETRY, manager().runDownload(book, finalAttempt = false))
        assertEquals(DownloadRunOutcome.FAILED, manager().runDownload(book, finalAttempt = true))
    }

    @Test
    fun incompleteManifestIsNotPlayedOffline() = runBlocking {
        val present = storage.createTrackFinalFile(key, 0, "mp3").apply { writeText("audio") }
        val manifest = OfflineAudioManifest(
            bookId = book.id,
            title = book.title,
            source = BookSource.AUDIOBOOKSHELF.name,
            downloadedAtEpochMs = 1L,
            tracks = listOf(
                OfflineAudioTrackManifest(0, "One", 1_000L, storage.relativePath(present), 5L),
                OfflineAudioTrackManifest(1, "Two", 1_000L, "$key/track_1.mp3", 5L),
            ),
            downloadKey = key,
        )
        storage.saveManifest(manifest)

        assertNull(manager().localTracks(key))

        storage.createTrackFinalFile(key, 1, "mp3").writeText("audio")
        assertEquals(2, manager().localTracks(key)?.size)
        assertFalse(File(storage.bookDirectory(key), "manifest.json.tmp").exists())
    }

    @Test
    fun cancelDiscardsOnlyThatBooksPartialFiles() = runBlocking {
        storage.createTrackTempFile(key, 0).writeText("abc")
        storage.createTrackFinalFile(key, 1, "mp3").writeText("audio")
        val other = storage.createTrackTempFile("other-book", 0).apply { writeText("keep") }
        val manager = manager()

        manager.cancelDownload(key)

        assertFalse(storage.bookDirectory(key).exists())
        assertTrue(other.exists())
        assertNull(manager.progressByDownloadKey.value[key])
    }

    private fun twoTracks(firstAssetId: String) = listOf(
        ResolvedTrack(0, "One", 1_000L, "http://offline.test/one.mp3", sizeBytes = 6L, assetId = firstAssetId),
        ResolvedTrack(1, "Two", 1_000L, "http://offline.test/two.mp3", sizeBytes = 6L, assetId = "ino-two"),
    )

    private fun trackFile(): File = checkNotNull(storage.existingTrackFinalFile(key, 0))

    private fun manager(
        tracks: List<ResolvedTrack> = listOf(ResolvedTrack(0, "Track", 1_000L, "http://offline.test/track.mp3")),
    ) = OfflineDownloadManager(
        context = context,
        resolvers = mapOf(
            BookSource.AUDIOBOOKSHELF to object : AudiobookTrackResolver {
                override suspend fun resolveTracks(book: Book) = Result.success(tracks)
            },
        ),
        storage = storage,
        okHttpClient = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            synchronized(requests) { requests += request }
            respond(request)
        }.build(),
        bookCacheDao = database.bookCacheDao(),
        parentScope = parentScope,
        locations = locations,
    )

    private fun ok(request: Request, body: String) = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("OK")
        .header("ETag", "\"fresh\"")
        .body(body.toResponseBody("audio/mpeg".toMediaType()))
        .build()

    private fun partial(request: Request, body: String, contentRange: String) = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(206)
        .message("Partial Content")
        .header("Content-Range", contentRange)
        .body(body.toResponseBody("audio/mpeg".toMediaType()))
        .build()

    private fun status(request: Request, code: Int) = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(code)
        .message("Error")
        .body("".toResponseBody("text/plain".toMediaType()))
        .build()
}
