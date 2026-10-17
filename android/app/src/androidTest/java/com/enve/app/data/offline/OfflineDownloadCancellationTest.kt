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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
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
        parentScope.cancel()
        database.close()
        root.deleteRecursively()
    }

    @Test
    fun cancelDuringCoverDownloadDoesNotPublishManifest() =
        assertInterruptedDuringCover { it.cancelDownload(book.id) }

    @Test
    fun removeDuringCoverDownloadDoesNotPublishManifest() =
        assertInterruptedDuringCover { it.removeDownload(book.id) }

    @Test
    fun incompleteManifestsAreNotReportedAndValidDownloadsSurviveCancel() = runBlocking {
        val validTrack = storage.createTrackFinalFile("valid", 0, "mp3").apply { writeText("audio") }
        val truncatedTrack = storage.createTrackFinalFile("truncated", 0, "mp3").apply { writeText("bad") }
        storage.saveManifest(manifest("valid", storage.relativePath(validTrack)))
        storage.saveManifest(manifest("truncated", storage.relativePath(truncatedTrack)))
        storage.saveManifest(manifest("orphan", "orphan/track_0.mp3"))

        val manager = manager()

        assertEquals(setOf("valid"), manager.downloadedBookIds.value)
        assertEquals(listOf("valid"), manager.listDownloadedManifests().map { it.bookId })
        manager.cancelDownload("valid")
        assertEquals(DownloadRunOutcome.COMPLETED, manager.runDownload(book.copy(id = "valid")))
        assertTrue(storage.isDownloaded("valid"))
    }

    private fun assertInterruptedDuringCover(interrupt: (OfflineDownloadManager) -> Unit) = runBlocking {
        val manager = manager()
        val download = async(Dispatchers.IO) { runCatching { manager.runDownload(book) } }

        assertTrue(coverRequested.await(10, TimeUnit.SECONDS))
        interrupt(manager)
        releaseCover.countDown()

        assertTrue(download.await().exceptionOrNull() is CancellationException)
        assertNull(storage.getManifest(book.id))
        assertFalse(storage.isDownloaded(book.id))
        assertFalse(book.id in manager.downloadedBookIds.value)
        assertFalse(book.id in manager.listDownloadedManifests().map { it.bookId })
        assertNull(manager.progressByBookId.value[book.id])
        assertFalse(storage.bookDirectory(book.id).exists())
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

    private fun manifest(bookId: String, relativePath: String) = OfflineAudioManifest(
        bookId = bookId,
        title = bookId,
        author = null,
        coverUrl = null,
        source = BookSource.AUDIOBOOKSHELF.name,
        downloadedAtEpochMs = 1L,
        tracks = listOf(OfflineAudioTrackManifest(0, "Track", 1_000L, relativePath, 5L)),
    )
}
