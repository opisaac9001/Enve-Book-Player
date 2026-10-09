package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.offline.OfflineAudioManifest
import com.enve.app.data.offline.OfflineAudioStorage
import com.enve.app.data.offline.OfflineAudioTrackManifest
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
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
        val ownerTrack = owner.createTrackFinalFile("42", 0, "mp3")
        assertEquals(File(root, "files/offline-audio/42/track_0.mp3"), ownerTrack)
        ownerTrack.writeText("owner media")
        owner.coverFile("42").writeText("owner cover")
        owner.saveManifest(manifest(ownerBook, owner.relativePath(ownerTrack)))
        assertTrue(File(root, "files/offline-audio/.pending/42.json").exists())
        assertTrue(File(root, "files/offline-audio/42/manifest.json").exists())

        val child = OfflineAudioStorage(childLocations)
        assertFalse(child.isDownloaded("42"))
        assertTrue(child.listManifests().isEmpty())
        assertTrue(child.listPendingRequests().isEmpty())
        val childBook = book("Child audio")
        child.savePendingRequest(childBook)
        val childTrack = child.createTrackFinalFile("42", 0, "mp3")
        childTrack.writeText("child media")
        child.coverFile("42").writeText("child cover")
        child.saveManifest(manifest(childBook, child.relativePath(childTrack)))

        ownerTrack.appendText(" late owner write")
        owner.savePendingRequest(ownerBook.copy(title = "Owner pending updated"))
        assertEquals("child media", childTrack.readText())
        assertEquals("Child audio", child.getManifest("42")?.title)
        assertEquals(childBook, child.getPendingRequest("42"))
        assertEquals("child cover", child.coverFile("42").readText())
        val reopened = OfflineAudioStorage(childLocations)
        assertTrue(reopened.isDownloaded("42"))
        assertEquals("child media", reopened.absolutePath(reopened.getManifest("42")!!.tracks.single().relativePath).readText())
        assertEquals(listOf(childBook), reopened.listPendingRequests())

        child.clearPendingRequest("42")
        child.removeDownload("42")
        assertFalse(child.isDownloaded("42"))
        assertTrue(owner.isDownloaded("42"))
        assertEquals("owner media late owner write", ownerTrack.readText())
        assertEquals("Owner audio", owner.getManifest("42")?.title)
        assertEquals("Owner pending updated", owner.getPendingRequest("42")?.title)
    }

    @Test
    fun comicBytesManifestsAndDeletionStayInCapturedProfile() {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val childLocations = locations("child-one")
        val owner = ComicOfflineStorage(ownerLocations)
        val ownerBook = book("Owner comic").copy(mediaType = AppMediaType.EBOOK)
        val ownerTemp = owner.createTempFile("42", "epub")
        assertEquals(File(root, "files/offline-comics/42/book.epub.part"), ownerTemp)
        ownerTemp.writeText("owner comic bytes")
        assertFalse(owner.isDownloaded("42"))
        val ownerFile = owner.commit(ownerTemp)
        owner.saveManifest(ownerBook)
        assertTrue(File(root, "files/offline-comics/42/book.json").exists())

        val child = ComicOfflineStorage(childLocations)
        assertFalse(child.isDownloaded("42"))
        assertTrue(child.listManifests().isEmpty())
        val childBook = book("Child comic").copy(mediaType = AppMediaType.EBOOK)
        val childTemp = child.createTempFile("42", "epub")
        childTemp.writeText("child comic bytes")
        assertFalse(child.isDownloaded("42"))
        val childFile = child.commit(childTemp)
        child.saveManifest(childBook)

        ownerFile.appendText(" late owner write")
        owner.saveManifest(ownerBook.copy(title = "Owner comic updated"))
        assertEquals("child comic bytes", childFile.readText())
        assertEquals(listOf(childBook), child.listManifests())
        val reopened = ComicOfflineStorage(childLocations)
        assertEquals("child comic bytes", reopened.getDownloadedFile("42")?.readText())
        assertEquals(setOf("42"), reopened.listDownloadedBookIds())
        assertEquals(childBook, reopened.getManifest("42"))

        child.removeDownload("42")
        assertFalse(child.isDownloaded("42"))
        assertTrue(owner.isDownloaded("42"))
        assertEquals("owner comic bytes late owner write", ownerFile.readText())
        assertEquals("Owner comic updated", owner.getManifest("42")?.title)
    }

    @Test
    fun childAudioManifestPathsCannotEscapeToOwnerMedia() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val ownerTrack = owner.createTrackFinalFile("42", 0, "mp3")
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

        val childTrack = child.createTrackFinalFile("42", 0, "mp3")
        childTrack.writeText("child media")
        assertEquals(childTrack.canonicalFile, child.absolutePath(child.relativePath(childTrack)))
        assertEquals("child media", child.absolutePath("42/track_0.mp3").readText())
        assertEquals("owner media", ownerTrack.readText())
    }

    @Test
    fun blockedChildAudioRootCannotTouchOwnerFiles() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val ownerTrack = owner.createTrackFinalFile("42", 0, "mp3")
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
        assertEquals(ownerBook, owner.getPendingRequest("42"))
    }

    @Test
    fun blockedChildComicRootCannotTouchOwnerFiles() {
        val owner = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val temp = owner.createTempFile("42", "epub")
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
        assertTrue(owner.isDownloaded("42"))
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
    )
}
