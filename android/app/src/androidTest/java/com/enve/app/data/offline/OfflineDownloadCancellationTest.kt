package com.enve.app.data.offline

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
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
class OfflineDownloadCancellationTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val parentScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private lateinit var root: File
    private lateinit var database: ReaderDatabase
    private lateinit var locations: ProfileStorageLocations
    private lateinit var storage: OfflineAudioStorage
    private val coverRequested = CountDownLatch(1)
    private val releaseCover = CountDownLatch(1)
    private val book = Book(
        id = "race-book",
        title = "Race",
        source = BookSource.AUDIOBOOKSHELF,
        coverUrl = "http://offline.test/cover.jpg",
    )

    @Before
    fun setUp() {
        root = File(context.cacheDir, "offline-download-cancel-${UUID.randomUUID()}")
        check(root.mkdirs())
        database = Room.inMemoryDatabaseBuilder(context, ReaderDatabase::class.java).build()
        locations = ProfileStorageLocations.forProfile(
            profileId = "download-race",
            filesDirectory = File(root, "files"),
            cacheDirectory = File(root, "cache"),
            databaseDirectory = File(root, "databases"),
        )
        storage = OfflineAudioStorage(locations)
    }

    @After
    fun tearDown() {
        releaseCover.countDown()
        runBlocking { parentScope.coroutineContext[Job]!!.cancelAndJoin() }
        database.close()
        root.deleteRecursively()
    }

    @Test
    fun cancelDuringCoverDownloadDoesNotPublishManifest() =
        assertInterruptedDuringCover { it.cancelDownload(book.offlineDownloadKey) }

    @Test
    fun removeDuringCoverDownloadDoesNotPublishManifest() =
        assertInterruptedDuringCover { it.removeDownload(book.offlineDownloadKey) }

    @Test
    fun cancelledWorkerPreservesReplacementRequest() = runBlocking {
        val key = book.offlineDownloadKey
        val manager = manager()
        storage.savePendingRequest(book)
        val old = async(Dispatchers.IO) { runCatching { manager.runDownload(book) } }

        assertTrue(coverRequested.await(10, TimeUnit.SECONDS))
        manager.cancelDownload(key)
        val replacement = book.copy(title = "Replacement", coverUrl = null)
        storage.savePendingRequest(replacement)
        releaseCover.countDown()

        assertTrue(old.await().exceptionOrNull() is CancellationException)
        assertEquals(replacement, storage.getPendingRequest(key))
        assertEquals(DownloadRunOutcome.COMPLETED, manager.runDownload(replacement))
        assertEquals("Replacement", storage.getManifest(key)?.title)
    }

    @Test
    fun incompleteManifestsAreNotReportedAndValidDownloadsSurviveCancel() = runBlocking {
        val valid = book.copy(id = "valid").offlineDownloadKey
        val truncated = book.copy(id = "truncated").offlineDownloadKey
        val orphan = book.copy(id = "orphan").offlineDownloadKey
        val validTrack = storage.createTrackFinalFile(valid, 0, "mp3").apply { writeText("audio") }
        val truncatedTrack = storage.createTrackFinalFile(truncated, 0, "mp3").apply { writeText("bad") }
        storage.saveManifest(manifest("valid", valid, storage.relativePath(validTrack)))
        storage.saveManifest(manifest("truncated", truncated, storage.relativePath(truncatedTrack)))
        storage.saveManifest(manifest("orphan", orphan, "$orphan/track_0.mp3"))

        val manager = manager()

        assertEquals(setOf(valid), manager.downloadedKeys.value)
        assertEquals(listOf("valid"), manager.listDownloadedManifests().map { it.bookId })
        manager.cancelDownload(valid)
        assertEquals(DownloadRunOutcome.COMPLETED, manager.runDownload(book.copy(id = "valid")))
        assertTrue(storage.isDownloaded(valid))
    }

    @Test
    fun sameBookIdOnTwoConnectionsDownloadsPlaysAndDeletesIndependently() = runBlocking {
        val first = book.copy(id = "42", connectionId = "abs-a", coverUrl = null)
        val second = book.copy(id = "42", connectionId = "abs-b", coverUrl = null)
        val manager = manager()

        assertEquals(DownloadRunOutcome.COMPLETED, manager.runDownload(first))
        assertEquals(DownloadRunOutcome.COMPLETED, manager.runDownload(second))

        assertEquals(setOf(first.offlineDownloadKey, second.offlineDownloadKey), manager.downloadedKeys.value)
        assertEquals("abs-a", manager.getManifest(first.offlineDownloadKey)?.connectionId)
        assertEquals("abs-b", manager.getManifest(second.offlineDownloadKey)?.connectionId)
        assertNull(manager.localTracks(book.copy(id = "42", connectionId = "abs-c").offlineDownloadKey))

        manager.removeDownload(first.offlineDownloadKey)

        assertFalse(storage.isDownloaded(first.offlineDownloadKey))
        assertTrue(storage.isDownloaded(second.offlineDownloadKey))
        assertEquals(1, manager.localTracks(second.offlineDownloadKey)?.size)
    }

    @Test
    fun pendingRequestsForTwoConnectionsDoNotReplaceEachOther() {
        val first = book.copy(id = "42", connectionId = "abs-a", title = "First")
        val second = book.copy(id = "42", connectionId = "abs-b", title = "Second")

        storage.savePendingRequest(first)
        storage.savePendingRequest(second)

        assertEquals("First", storage.getPendingRequest(first.offlineDownloadKey)?.title)
        assertEquals("Second", storage.getPendingRequest(second.offlineDownloadKey)?.title)
        storage.clearPendingRequest(first.offlineDownloadKey)
        assertEquals(listOf("Second"), storage.listPendingRequests().map { it.title })
    }

    @Test
    fun legacyDownloadsBecomeLocalRecoveredCopiesWithoutGuessingAnOwner() = runBlocking {
        val single = writeLegacyDownload("42")
        writeLegacyDownload("77")
        storage = OfflineAudioStorage(locations)
        val singleManifest = File(single, "manifest.json").readText()
        val recovered = storage.listManifests().associateBy { it.title }
        val singleCopy = Book(id = recovered.getValue("42").bookId, title = "42", source = BookSource.LOCAL)
        val ambiguousCopy = Book(id = recovered.getValue("77").bookId, title = "77", source = BookSource.LOCAL)
        val dao = database.bookCacheDao()
        dao.upsert(listOf(
            book.copy(id = "42", connectionId = "abs-a").toCachedBook(1L),
            book.copy(id = "77", connectionId = "abs-a").toCachedBook(1L),
            book.copy(id = "77", connectionId = "abs-b").toCachedBook(1L),
            singleCopy.copy(readProgress = 0.4f, currentTime = 120L).toCachedBook(1L),
        ))

        val manager = manager()
        val deadline = System.currentTimeMillis() + 10_000L
        while (dao.getByCacheKey(ambiguousCopy.uniqueKey) == null && System.currentTimeMillis() < deadline) Thread.sleep(50)

        assertTrue(singleCopy.id.startsWith("local-recovered-") && ambiguousCopy.id.startsWith("local-recovered-"))
        assertTrue(singleCopy.id != ambiguousCopy.id)
        for (connection in listOf("abs-a", "abs-b")) {
            assertNull(manager.localTracks(book.copy(id = "42", connectionId = connection).offlineDownloadKey))
            assertNull(manager.localTracks(book.copy(id = "77", connectionId = connection).offlineDownloadKey))
        }
        assertNull(manager.localTracks(book.copy(id = "42").offlineDownloadKey))
        assertEquals(1, manager.localTracks(singleCopy.offlineDownloadKey)?.size)
        assertEquals(1, manager.localTracks(ambiguousCopy.offlineDownloadKey)?.size)
        assertEquals(singleManifest, File(single, "manifest.json").readText())
        assertNull(manager.getManifest(singleCopy.offlineDownloadKey)?.connectionId)
        assertEquals(BookSource.LOCAL.name, manager.getManifest(singleCopy.offlineDownloadKey)?.source)
        assertEquals(0.4f, dao.getByCacheKey(singleCopy.uniqueKey)?.toBook()?.readProgress)
        assertEquals(BookSource.LOCAL, dao.getByCacheKey(ambiguousCopy.uniqueKey)?.toBook()?.source)

        val scoped = book.copy(id = "42", connectionId = "abs-a", coverUrl = null)
        assertEquals(DownloadRunOutcome.COMPLETED, manager.runDownload(scoped))
        manager.removeDownload(singleCopy.offlineDownloadKey)

        assertFalse(single.exists())
        assertNull(manager.localTracks(singleCopy.offlineDownloadKey))
        assertTrue(storage.isDownloaded(scoped.offlineDownloadKey))
        assertEquals(1, manager.localTracks(scoped.offlineDownloadKey)?.size)
        assertEquals(1, manager.localTracks(ambiguousCopy.offlineDownloadKey)?.size)
    }

    private fun writeLegacyDownload(bookId: String): File {
        val directory = File(locations.filesDirectory, "offline-audio/$bookId").apply { check(mkdirs()) }
        File(directory, "track_0.mp3").writeText("audio")
        File(directory, "manifest.json").writeText(
            """{"bookId":"$bookId","title":"$bookId","coverUrl":"http://offline.test/cover.jpg","source":"AUDIOBOOKSHELF",""" +
                """"downloadedAtEpochMs":1,"tracks":[{"index":0,"title":"Track","durationMs":1000,"relativePath":"$bookId/track_0.mp3","bytes":5}]}""",
        )
        return directory
    }

    private fun assertInterruptedDuringCover(interrupt: (OfflineDownloadManager) -> Unit) = runBlocking {
        val key = book.offlineDownloadKey
        val manager = manager()
        val download = async(Dispatchers.IO) { runCatching { manager.runDownload(book) } }

        assertTrue(coverRequested.await(10, TimeUnit.SECONDS))
        interrupt(manager)
        releaseCover.countDown()

        assertTrue(download.await().exceptionOrNull() is CancellationException)
        assertNull(storage.getManifest(key))
        assertFalse(storage.isDownloaded(key))
        assertFalse(key in manager.downloadedKeys.value)
        assertFalse(book.id in manager.listDownloadedManifests().map { it.bookId })
        assertNull(manager.progressByDownloadKey.value[key])
        assertFalse(storage.bookDirectory(key).exists())
    }

    private fun manager() = OfflineDownloadManager(
        context = context,
        resolvers = mapOf(
            BookSource.AUDIOBOOKSHELF to object : AudiobookTrackResolver {
                override suspend fun resolveTracks(book: Book) =
                    Result.success(listOf(ResolvedTrack(0, "Track", 1_000L, "http://offline.test/track.mp3")))
            },
        ),
        storage = storage,
        okHttpClient = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            if (request.url.encodedPath == "/cover.jpg") {
                coverRequested.countDown()
                check(releaseCover.await(10, TimeUnit.SECONDS))
            }
            Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body("bytes".toResponseBody("audio/mpeg".toMediaType()))
                .build()
        }.build(),
        bookCacheDao = database.bookCacheDao(),
        parentScope = parentScope,
        locations = locations,
    )

    private fun manifest(bookId: String, key: String, relativePath: String) = OfflineAudioManifest(
        bookId = bookId,
        title = bookId,
        author = null,
        coverUrl = null,
        source = BookSource.AUDIOBOOKSHELF.name,
        downloadedAtEpochMs = 1L,
        tracks = listOf(OfflineAudioTrackManifest(0, "Track", 1_000L, relativePath, 5L)),
        downloadKey = key,
    )
}
