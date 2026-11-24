package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.offline.OfflineAudioManifest
import com.enve.app.data.offline.OfflineAudioStorage
import com.enve.app.data.offline.OfflineAudioTrackManifest
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileOfflineStorageTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var root: File

    @Before
    fun setUp() {
        root = File(context.cacheDir, "profile-offline-test-${UUID.randomUUID()}")
        check(root.mkdirs())
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    @Test
    fun audioBytesManifestsPendingRequestsAndDeletionStayInCapturedProfile() {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val childLocations = locations("child-one")
        val owner = OfflineAudioStorage(ownerLocations)
        val ownerBook = book("Owner audio")
        owner.savePendingRequest(ownerBook)
        val ownerTrack = owner.createTrackFinalFile(KEY, 0, "mp3")
        assertEquals(File(root, "files/offline-audio/$KEY/track_0.mp3"), ownerTrack)
        ownerTrack.writeText("owner media")
        owner.coverFile(KEY).writeText("owner cover")
        owner.saveManifest(manifest(ownerBook, owner.relativePath(ownerTrack)))
        assertTrue(File(root, "files/offline-audio/.pending/$KEY.json").exists())
        assertTrue(File(root, "files/offline-audio/$KEY/manifest.json").exists())

        val child = OfflineAudioStorage(childLocations)
        assertFalse(child.isDownloaded(KEY))
        assertTrue(child.listManifests().isEmpty())
        assertTrue(child.listPendingRequests().isEmpty())
        val childBook = book("Child audio")
        child.savePendingRequest(childBook)
        val childTrack = child.createTrackFinalFile(KEY, 0, "mp3")
        childTrack.writeText("child media")
        child.coverFile(KEY).writeText("child cover")
        child.saveManifest(manifest(childBook, child.relativePath(childTrack)))

        ownerTrack.appendText(" late owner write")
        owner.savePendingRequest(ownerBook.copy(title = "Owner pending updated"))
        assertEquals("child media", childTrack.readText())
        assertEquals("Child audio", child.getManifest(KEY)?.title)
        assertEquals(childBook, child.getPendingRequest(KEY))
        assertEquals("child cover", child.coverFile(KEY).readText())
        val reopened = OfflineAudioStorage(childLocations)
        assertTrue(reopened.isDownloaded(KEY))
        assertEquals("child media", reopened.absolutePath(reopened.getManifest(KEY)!!.tracks.single().relativePath).readText())
        assertEquals(listOf(childBook), reopened.listPendingRequests())

        child.clearPendingRequest(KEY)
        child.removeDownload(KEY)
        assertFalse(child.isDownloaded(KEY))
        assertTrue(owner.isDownloaded(KEY))
        assertEquals("owner media late owner write", ownerTrack.readText())
        assertEquals("Owner audio", owner.getManifest(KEY)?.title)
        assertEquals("Owner pending updated", owner.getPendingRequest(KEY)?.title)
    }

    @Test
    fun comicBytesManifestsAndDeletionStayInCapturedProfile() {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val childLocations = locations("child-one")
        val owner = ComicOfflineStorage(ownerLocations)
        val ownerBook = book("Owner comic").copy(mediaType = AppMediaType.EBOOK)
        val ownerTemp = owner.createTempFile(KEY, "epub")
        assertEquals(File(root, "files/offline-comics/$KEY/book.epub.part"), ownerTemp)
        ownerTemp.writeText("owner comic bytes")
        assertFalse(owner.isDownloaded(KEY))
        val ownerFile = owner.commit(ownerTemp)
        owner.saveManifest(ownerBook)
        assertTrue(File(root, "files/offline-comics/$KEY/book.json").exists())

        val child = ComicOfflineStorage(childLocations)
        assertFalse(child.isDownloaded(KEY))
        assertTrue(child.listManifests().isEmpty())
        val childBook = book("Child comic").copy(mediaType = AppMediaType.EBOOK)
        val childTemp = child.createTempFile(KEY, "epub")
        childTemp.writeText("child comic bytes")
        assertFalse(child.isDownloaded(KEY))
        val childFile = child.commit(childTemp)
        child.saveManifest(childBook)

        ownerFile.appendText(" late owner write")
        owner.saveManifest(ownerBook.copy(title = "Owner comic updated"))
        assertEquals("child comic bytes", childFile.readText())
        assertEquals(listOf(childBook), child.listManifests())
        val reopened = ComicOfflineStorage(childLocations)
        assertEquals("child comic bytes", reopened.getDownloadedFile(KEY)?.readText())
        assertEquals(setOf(KEY), reopened.listDownloadedKeys())
        assertEquals(childBook, reopened.getManifest(KEY))

        child.removeDownload(KEY)
        assertFalse(child.isDownloaded(KEY))
        assertTrue(owner.isDownloaded(KEY))
        assertEquals("owner comic bytes late owner write", ownerFile.readText())
        assertEquals("Owner comic updated", owner.getManifest(KEY)?.title)
    }

    @Test
    fun failedComicManifestReplacementKeepsTheCompletedBook() {
        val storage = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val original = book("Saved title").copy(mediaType = AppMediaType.EBOOK)
        val key = original.offlineDownloadKey
        val finished = storage.commit(storage.createTempFile(key, "epub").apply { writeText("complete") })
        storage.saveManifest(original)
        check(File(finished.parentFile, ".book-manifest.tmp").mkdir())

        val failure = runCatching { storage.saveManifest(original.copy(title = "Other title")) }.exceptionOrNull()

        assertTrue(failure is java.io.IOException)
        assertEquals(original, storage.getManifest(key))
        assertEquals("complete", storage.getDownloadedFile(key)?.readText())
    }

    @Test
    fun comicsWithTheSameIdOnTwoConnectionsStaySeparate() {
        val storage = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val first = Book(id = "42", title = "First", source = BookSource.KOMGA, connectionId = "komga-a", mediaType = AppMediaType.EBOOK)
        val second = first.copy(title = "Second", connectionId = "komga-b")
        storage.commit(storage.createTempFile(first.offlineDownloadKey, "cbz").apply { writeText("first") })
        storage.saveManifest(first)
        storage.commit(storage.createTempFile(second.offlineDownloadKey, "cbz").apply { writeText("second") })
        storage.saveManifest(second)
        storage.savePendingRequest(first)
        storage.savePendingRequest(second)

        assertEquals("first", storage.getDownloadedFile(first.offlineDownloadKey)?.readText())
        assertEquals("second", storage.getDownloadedFile(second.offlineDownloadKey)?.readText())
        assertEquals(2, storage.listPendingRequests().size)

        storage.removeDownload(first.offlineDownloadKey)

        assertFalse(storage.isDownloaded(first.offlineDownloadKey))
        assertEquals("second", storage.getDownloadedFile(second.offlineDownloadKey)?.readText())
        assertEquals(listOf("Second"), storage.listPendingRequests().map { it.title })
    }

    @Test
    fun legacyComicDirectoryResolvesOnlyForTheConnectionInItsManifest() {
        val owned = Book(id = "a:b", title = "Legacy", source = BookSource.KOMGA, connectionId = "komga-a", mediaType = AppMediaType.EBOOK)
        val legacy = File(root, "files/offline-comics/a_b").apply { check(mkdirs()) }
        File(legacy, "book.cbz").writeText("legacy")
        File(legacy, "book.json").writeText(Json.encodeToString(owned))
        val storage = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))

        assertEquals("legacy", storage.getDownloadedFile(owned.offlineDownloadKey)?.readText())
        assertEquals(null, storage.getDownloadedFile(owned.copy(connectionId = "komga-b").offlineDownloadKey))
        assertEquals(null, storage.getDownloadedFile(owned.copy(id = "a/b").offlineDownloadKey))
        assertEquals(setOf(owned.offlineDownloadKey), storage.listDownloadedKeys())
    }

    @Test
    fun legacyComicWithoutConnectionBecomesSeparateLocalRecoveredCopy() {
        val remote = Book(id = "a:b", title = "Legacy", source = BookSource.KOMGA, mediaType = AppMediaType.EBOOK, coverUrl = "https://example.invalid/c")
        val legacy = File(root, "files/offline-comics/a_b").apply { check(mkdirs()) }
        File(legacy, "book.cbz").writeText("legacy")
        val original = Json.encodeToString(remote)
        File(legacy, "book.json").writeText(original)
        val storage = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))

        val recovered = storage.listManifests().single()
        assertTrue(recovered.id.startsWith("local-recovered-"))
        assertEquals(BookSource.LOCAL, recovered.source)
        assertEquals(null, recovered.connectionId)
        assertEquals(null, recovered.coverUrl)
        assertEquals("legacy", storage.getDownloadedFile(recovered.offlineDownloadKey)?.readText())
        assertEquals(null, storage.getDownloadedFile(remote.offlineDownloadKey))
        assertEquals(null, storage.getDownloadedFile(remote.copy(connectionId = "komga-a").offlineDownloadKey))
        assertEquals(setOf(recovered.offlineDownloadKey), storage.listDownloadedKeys())
        assertEquals(original, File(legacy, "book.json").readText())

        val scoped = remote.copy(connectionId = "komga-a")
        storage.commit(storage.createTempFile(scoped.offlineDownloadKey, "cbz").apply { writeText("scoped") })
        storage.saveManifest(scoped)
        storage.removeDownload(recovered.offlineDownloadKey)

        assertFalse(legacy.exists())
        assertEquals("scoped", storage.getDownloadedFile(scoped.offlineDownloadKey)?.readText())
    }

    @Test
    fun legacyPendingRequestsMoveToTheirFullIdentity() {
        val pending = File(root, "files/offline-comics/.pending").apply { check(mkdirs()) }
        val book = Book(id = "a:b", title = "Pending", source = BookSource.KOMGA, connectionId = "komga-a", mediaType = AppMediaType.EBOOK)
        File(pending, "a_b.json").writeText(Json.encodeToString(book))

        val storage = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))

        assertEquals(listOf(book), storage.listPendingRequests())
        assertTrue(File(pending, "${book.offlineDownloadKey}.json").exists())
        assertFalse(File(pending, "a_b.json").exists())
    }

    @Test
    fun childAudioManifestPathsCannotEscapeToOwnerMedia() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val ownerTrack = owner.createTrackFinalFile(KEY, 0, "mp3")
        ownerTrack.writeText("owner media")
        val childLocations = locations("child-one")
        val child = OfflineAudioStorage(childLocations)
        val childRoot = File(childLocations.filesDirectory, "offline-audio")
        val escapePaths = listOf(
            ownerTrack.relativeTo(childRoot).invariantSeparatorsPath,
            ownerTrack.absolutePath,
        )

        for (path in escapePaths) {
            try {
                child.absolutePath(path)
                fail("Child manifest path must not resolve owner media")
            } catch (_: IllegalArgumentException) {
            }
        }

        val childTrack = child.createTrackFinalFile(KEY, 0, "mp3")
        childTrack.writeText("child media")
        assertEquals(childTrack.canonicalFile, child.absolutePath(child.relativePath(childTrack)))
        assertEquals("child media", child.absolutePath("$KEY/track_0.mp3").readText())
        assertEquals("owner media", ownerTrack.readText())
    }

    @Test
    fun blockedChildAudioRootCannotTouchOwnerFiles() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val ownerTrack = owner.createTrackFinalFile(KEY, 0, "mp3")
        ownerTrack.writeText("owner media")
        val childLocations = locations("child-blocked")
        check(childLocations.filesDirectory.mkdirs())
        val blocked = File(childLocations.filesDirectory, "offline-audio")
        blocked.writeText("blocked root")

        try {
            OfflineAudioStorage(childLocations)
            fail("Blocked child audio root must fail setup")
        } catch (_: IllegalStateException) {
        }
        assertEquals("blocked root", blocked.readText())
        assertEquals("owner media", ownerTrack.readText())
    }

    @Test
    fun blockedChildPendingDirectoryCannotTouchOwnerRequests() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val ownerBook = book("Owner pending")
        owner.savePendingRequest(ownerBook)
        val childLocations = locations("child-blocked")
        val childAudioRoot = File(childLocations.filesDirectory, "offline-audio")
        check(childAudioRoot.mkdirs())
        val blocked = File(childAudioRoot, ".pending")
        blocked.writeText("blocked pending directory")

        try {
            OfflineAudioStorage(childLocations)
            fail("Blocked child pending directory must fail setup")
        } catch (_: IllegalStateException) {
        }
        assertEquals("blocked pending directory", blocked.readText())
        assertEquals(ownerBook, owner.getPendingRequest(KEY))
    }

    @Test
    fun blockedChildComicRootCannotTouchOwnerFiles() {
        val owner = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val temp = owner.createTempFile(KEY, "epub")
        temp.writeText("owner comic")
        val ownerFile = owner.commit(temp)
        val childLocations = locations("child-blocked")
        check(childLocations.filesDirectory.mkdirs())
        val blocked = File(childLocations.filesDirectory, "offline-comics")
        blocked.writeText("blocked root")

        try {
            ComicOfflineStorage(childLocations)
            fail("Blocked child comic root must fail setup")
        } catch (_: IllegalStateException) {
        }
        assertEquals("blocked root", blocked.readText())
        assertEquals("owner comic", ownerFile.readText())
        assertTrue(owner.isDownloaded(KEY))
    }

    private fun locations(profileId: String) = ProfileStorageLocations.forProfile(
        profileId = profileId,
        filesDirectory = File(root, "files"),
        cacheDirectory = File(root, "cache"),
        databaseDirectory = File(root, "databases"),
    )

    private fun book(title: String) = Book(id = "42", title = title, connectionId = "same-connection")

    private fun manifest(book: Book, relativePath: String) = OfflineAudioManifest(
        bookId = book.id,
        title = book.title,
        source = book.source.name,
        downloadedAtEpochMs = 1L,
        tracks = listOf(OfflineAudioTrackManifest(index = 0, relativePath = relativePath)),
        connectionId = book.connectionId,
        downloadKey = book.offlineDownloadKey,
    )

    private companion object {
        val KEY = Book(id = "42", title = "", connectionId = "same-connection").offlineDownloadKey
    }
}
