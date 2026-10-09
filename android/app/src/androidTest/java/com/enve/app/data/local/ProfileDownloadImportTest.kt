package com.enve.app.data.local

import android.content.Context
import android.system.Os
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
import com.enve.core.data.model.BookSource
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.UUID
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileDownloadImportTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var root: File

    @Before
    fun setUp() {
        root = File(context.cacheDir, "profile-download-import-${UUID.randomUUID()}")
        check(root.mkdirs())
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    @Test
    fun audioImportReusesBytesWithPrivateMetadataAndSurvivesSourceRemoval() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val sourceFile = completedAudio(owner)
        owner.savePendingRequest(Book(id = "42", title = "Owner", connectionId = "owner-account", currentTime = 90))
        owner.coverFile("42").writeText("private artwork")
        owner.createTrackTempFile("42", 99).writeText("unfinished")
        val childLocations = locations("child-one")
        val child = OfflineAudioStorage(childLocations)

        val imported = child.importCompletedDownload(owner, "42")
        val childFile = child.absolutePath(imported.tracks.single().relativePath)
        val privateDirectory = child.bookDirectory(imported.bookId)
        assertTrue(Files.isSymbolicLink(sourceFile.toPath()))
        assertTrue(Files.isSymbolicLink(File(privateDirectory, "track_0.mp3").toPath()))
        assertEquals(sourceFile.canonicalFile, childFile.canonicalFile)
        assertEquals(locations(DEFAULT_ADULT_PROFILE_ID).sharedDownloadsDirectory, childLocations.sharedDownloadsDirectory)
        assertNotEquals("42", imported.bookId)
        assertEquals(BookSource.LOCAL.name, imported.source)
        assertEquals(android.net.Uri.fromFile(child.coverFile(imported.bookId)).toString(), imported.coverUrl)
        assertEquals(owner.coverFile("42").canonicalFile, child.coverFile(imported.bookId).canonicalFile)
        assertEquals(sourceFile.length(), imported.tracks.single().bytes)
        assertEquals(Os.stat(sourceFile.path).st_ino, Os.stat(childFile.path).st_ino)
        assertEquals(Os.stat(sourceFile.path).st_dev, Os.stat(childFile.path).st_dev)
        assertEquals("audio bytes", childFile.readText())
        assertTrue(child.listPendingRequests().isEmpty())
        assertEquals("private artwork", child.coverFile(imported.bookId).readText())
        assertNull(child.existingTrackFinalFile(imported.bookId, 99))
        val metadata = File(privateDirectory, "manifest.json").readText()
        assertFalse(metadata.contains("owner-account") || metadata.contains("test-secret") || metadata.contains("https://"))
        val receipt = File(privateDirectory, ".import-receipt.json").readText()
        assertFalse(receipt.contains(DEFAULT_ADULT_PROFILE_ID) || receipt.contains("test-secret"))

        val reopened = OfflineAudioStorage(childLocations)
        assertEquals(imported, reopened.importCompletedDownload(owner, "42"))
        assertEquals(2, File(childLocations.sharedDownloadsDirectory, "assets").listFiles().orEmpty().size)
        assertEquals(1, reopened.listManifests().size)
        owner.removeDownload("42")
        assertTrue(reopened.isDownloaded(imported.bookId))
        assertEquals("audio bytes", childFile.readText())
    }

    @Test
    fun twoDestinationsHaveUniqueLocalIdsAndDeletingOnePreservesOtherLinks() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val sourceFile = completedAudio(owner)
        val first = OfflineAudioStorage(locations("child-one"))
        val second = OfflineAudioStorage(locations("child-two"))
        val firstImport = first.importCompletedDownload(owner, "42")
        val secondImport = second.importCompletedDownload(owner, "42")
        assertNotEquals(firstImport.bookId, secondImport.bookId)

        first.removeDownload(firstImport.bookId)
        assertTrue(owner.isDownloaded("42"))
        assertTrue(second.isDownloaded(secondImport.bookId))
        assertEquals("audio bytes", sourceFile.readText())
        assertEquals("audio bytes", second.absolutePath(secondImport.tracks.single().relativePath).readText())
        val removedPrivateFile = File(first.bookDirectory(firstImport.bookId).also { it.mkdirs() }, "track_0.mp3")
        Files.createSymbolicLink(removedPrivateFile.toPath(), sourceFile.canonicalFile.toPath())
        expectFailure { first.absolutePath(firstImport.tracks.single().relativePath) }
    }

    @Test
    fun ebookImportResetsStateAndReplacementLeavesImportedInodeUntouched() {
        val owner = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val sourceBook = Book(
            id = "42",
            title = "Book title",
            author = "Author",
            source = BookSource.GRIMMORY,
            mediaType = AppMediaType.EBOOK,
            connectionId = "owner-account",
            coverUrl = "https://example.invalid/cover?token=test-secret",
            currentTime = 80,
            readProgress = 0.8f,
            epubProgress = 0.8f,
            epubLocator = "private locator",
            isFinished = true,
            readAlongAvailable = true,
            hasAudio = true,
            audioTracks = emptyList(),
            opdsAcquisitionUrl = "https://example.invalid/file?token=test-secret",
            podcastEnclosureUrl = "https://example.invalid/audio?token=test-secret",
        )
        val temp = owner.createTempFile("42", "epub")
        temp.writeText("ebook bytes")
        val sourceFile = owner.commit(temp)
        owner.saveManifest(sourceBook)
        val childLocations = locations("child-one")
        val child = ComicOfflineStorage(childLocations)

        val imported = child.importCompletedDownload(owner, "42")
        val childFile = child.getDownloadedFile(imported.id)!!
        assertNotEquals(sourceBook.id, imported.id)
        assertEquals(BookSource.LOCAL, imported.source)
        assertNull(imported.connectionId)
        assertNull(imported.coverUrl)
        assertNull(imported.epubLocator)
        assertNull(imported.epubProgress)
        assertNull(imported.opdsAcquisitionUrl)
        assertNull(imported.podcastEnclosureUrl)
        assertEquals(0L, imported.currentTime)
        assertEquals(0f, imported.readProgress)
        assertFalse(imported.isFinished)
        assertFalse(imported.readAlongAvailable)
        assertFalse(imported.hasAudio)
        assertTrue(imported.audioTracks.isEmpty())
        assertEquals(Os.stat(sourceFile.path).st_ino, Os.stat(childFile.path).st_ino)
        assertTrue(Files.isSymbolicLink(sourceFile.toPath()))
        assertTrue(Files.isSymbolicLink(childFile.toPath()))
        assertEquals(sourceFile.canonicalFile, childFile.canonicalFile)
        assertEquals("ebook bytes", childFile.readText())
        assertEquals(imported, ComicOfflineStorage(childLocations).importCompletedDownload(owner, "42"))
        val receipt = File(childFile.parentFile, ".import-receipt.json").readText()
        val metadata = File(childFile.parentFile, "book.json").readText()
        assertFalse(receipt.contains("test-secret") || receipt.contains("owner-account") || receipt.contains("private locator"))
        assertFalse(metadata.contains("test-secret") || metadata.contains("owner-account") || metadata.contains("private locator"))

        val replacement = owner.createTempFile("42", "epub")
        replacement.writeText("replacement ebook")
        owner.commit(replacement)
        assertEquals("replacement ebook", owner.getDownloadedFile("42")!!.readText())
        assertEquals("ebook bytes", childFile.readText())
        child.removeDownload(imported.id)
        assertTrue(owner.isDownloaded("42"))
        assertEquals("replacement ebook", sourceFile.readText())
    }

    @Test
    fun failedAudioImportRemovesStagedLinksAndKeepsSourceUsable() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val sourceFile = completedAudio(owner)
        val sourceLinks = Os.stat(sourceFile.path).st_nlink
        val manifest = owner.getManifest("42")!!
        owner.saveManifest(manifest.copy(tracks = manifest.tracks + manifest.tracks.single().copy(
            index = 1,
            relativePath = "42/missing.mp3",
        )))
        val childLocations = locations("child-one")
        val child = OfflineAudioStorage(childLocations)

        expectFailure { child.importCompletedDownload(owner, "42") }
        assertTrue(child.listManifests().isEmpty())
        assertFalse(File(childLocations.filesDirectory, "offline-audio").listFiles().orEmpty().any { it.name.startsWith(".import-") })
        assertEquals(sourceLinks, Os.stat(sourceFile.path).st_nlink)
        assertEquals("audio bytes", sourceFile.readText())
    }

    @Test
    fun audioImportRejectsEmptyMismatchedPartialSymlinkAndEscapingPayloads() {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val owner = OfflineAudioStorage(ownerLocations)
        val sourceFile = completedAudio(owner)
        val manifest = owner.getManifest("42")!!
        val track = manifest.tracks.single()
        val child = OfflineAudioStorage(locations("child-one"))
        val empty = owner.createTrackFinalFile("42", 1, "mp3").also { it.writeBytes(byteArrayOf()) }
        val partial = owner.createTrackTempFile("42", 2).also { it.writeText("unfinished") }
        val outside = File(root, "outside.mp3").also { it.writeText("outside") }
        val symlink = File(sourceFile.parentFile, "linked.mp3")
        Files.createSymbolicLink(symlink.toPath(), sourceFile.toPath())
        val invalidTracks = listOf(
            track.copy(relativePath = owner.relativePath(empty), bytes = 0),
            track.copy(bytes = sourceFile.length() + 1),
            track.copy(relativePath = owner.relativePath(partial), bytes = 0),
            track.copy(relativePath = owner.relativePath(symlink), bytes = 0),
            track.copy(relativePath = outside.relativeTo(File(ownerLocations.filesDirectory, "offline-audio")).path, bytes = 0),
            track.copy(relativePath = outside.absolutePath, bytes = 0),
        )
        for (invalid in invalidTracks) {
            owner.saveManifest(manifest.copy(tracks = listOf(invalid)))
            expectFailure { child.importCompletedDownload(owner, "42") }
            assertTrue(child.listManifests().isEmpty())
        }
        assertEquals("audio bytes", sourceFile.readText())
        assertEquals("outside", outside.readText())
    }

    @Test
    fun comicImportRejectsPartsAndSymlinksWithoutDestinationManifest() {
        val owner = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val child = ComicOfflineStorage(locations("child-one"))
        owner.saveManifest(Book(id = "42", title = "Owner ebook", mediaType = AppMediaType.EBOOK))
        val temp = owner.createTempFile("42", "epub").also { it.writeText("unfinished") }
        expectFailure { child.importCompletedDownload(owner, "42") }
        assertTrue(child.listManifests().isEmpty())
        val outside = File(root, "outside.epub").also { it.writeText("outside bytes") }
        Files.createSymbolicLink(File(temp.parentFile, "book.epub").toPath(), outside.toPath())
        expectFailure { child.importCompletedDownload(owner, "42") }
        assertTrue(child.listManifests().isEmpty())
        assertEquals("outside bytes", outside.readText())
    }

    @Test
    fun failedFinalUnlinkCannotOverwriteExistingComicPayload() {
        val storage = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val temp = storage.createTempFile("42", "epub").also { it.writeText("replacement") }
        val blockedFinal = File(temp.parentFile, "book.epub")
        check(blockedFinal.mkdir())
        File(blockedFinal, "preserved").writeText("existing data")

        expectFailure { storage.commit(temp) }
        assertEquals("existing data", File(blockedFinal, "preserved").readText())
        assertEquals("replacement", temp.readText())
    }

    @Test
    fun recoveryRestoresSourceLinkAfterJournaledMove() {
        recoverAdoption(moveBeforeRecovery = true)
    }

    @Test
    fun recoveryCompletesJournalPersistedBeforeMove() {
        recoverAdoption(moveBeforeRecovery = false)
    }

    @Test
    fun ungrantedSymlinkToSharedBlobCannotExposeAnotherProfilesMedia() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val source = completedAudio(owner)
        val first = OfflineAudioStorage(locations("child-one"))
        first.importCompletedDownload(owner, "42")
        val second = OfflineAudioStorage(locations("child-two"))
        val malicious = second.createTrackFinalFile("42", 0, "mp3")
        Files.createSymbolicLink(malicious.toPath(), source.canonicalFile.toPath())
        expectFailure { second.absolutePath(second.relativePath(malicious)) }
        assertNull(second.existingTrackFinalFile("42", 0))
        assertEquals("audio bytes", source.readText())
    }

    @Test
    fun importedProfileCanGrantSameBlobAfterOriginalDownloadRemoval() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        completedAudio(owner)
        val first = OfflineAudioStorage(locations("child-one"))
        val originalImport = first.importCompletedDownload(owner, "42")
        owner.removeDownload("42")
        val second = OfflineAudioStorage(locations("child-two"))
        val nextImport = second.importCompletedDownload(first, originalImport.bookId)
        assertEquals(
            first.absolutePath(originalImport.tracks.single().relativePath).canonicalFile,
            second.absolutePath(nextImport.tracks.single().relativePath).canonicalFile,
        )
        first.removeDownload(originalImport.bookId)
        assertTrue(second.isDownloaded(nextImport.bookId))
        assertEquals("audio bytes", second.absolutePath(nextImport.tracks.single().relativePath).readText())
        assertEquals(1, File(locations(DEFAULT_ADULT_PROFILE_ID).sharedDownloadsDirectory, "assets").listFiles().orEmpty().size)
    }

    private fun recoverAdoption(moveBeforeRecovery: Boolean) {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val owner = OfflineAudioStorage(ownerLocations)
        val source = completedAudio(owner)
        val pinned = Os.stat(source.path)
        val assetId = UUID.randomUUID().toString()
        val blob = File(ownerLocations.sharedDownloadsDirectory, "assets/$assetId.bin")
        val grant = buildJsonObject {
            put("profileId", DEFAULT_ADULT_PROFILE_ID)
            put("bookDigest", MessageDigest.getInstance("SHA-256").digest("42".toByteArray()).joinToString("") { "%02x".format(it) })
            put("format", "audio")
            put("relativePath", owner.relativePath(source))
        }
        val journal = File(ownerLocations.sharedDownloadsDirectory, "records/$assetId.json")
        journal.writeText(buildJsonObject {
            put("assetId", assetId)
            put("bytes", pinned.st_size)
            put("device", pinned.st_dev)
            put("inode", pinned.st_ino)
            put("original", grant)
            put("adoptionPending", true)
            put("grants", JsonArray(listOf(grant)))
        }.toString())
        if (moveBeforeRecovery) {
            Files.move(source.toPath(), blob.toPath(), StandardCopyOption.ATOMIC_MOVE)
            assertFalse(source.exists())
        }

        val reopened = OfflineAudioStorage(ownerLocations)
        assertTrue(Files.isSymbolicLink(source.toPath()))
        assertEquals(blob.canonicalFile, source.canonicalFile)
        assertEquals("audio bytes", source.readText())
        assertTrue(reopened.isDownloaded("42"))
        assertTrue(journal.readText().contains("\"adoptionPending\":false"))
        assertEquals(1, File(ownerLocations.sharedDownloadsDirectory, "assets").listFiles().orEmpty().size)
    }

    @Test
    fun sharedBytesAreCountedOnceAndCollectedAfterLastReference() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val source = completedAudio(owner)
        val bytes = source.length()
        val child = OfflineAudioStorage(locations("child-one"))
        val imported = child.importCompletedDownload(owner, "42")
        assertEquals(bytes, child.sharedStorageBytes())
        owner.removeDownload("42")
        assertEquals(bytes, child.sharedStorageBytes())
        assertEquals("audio bytes", child.absolutePath(imported.tracks.single().relativePath).readText())
        child.removeDownload(imported.bookId)
        assertEquals(0L, child.sharedStorageBytes())
    }

    @Test
    fun publicationRejectionKeepsSourceAndPublishesNoDestination() {
        val owner = OfflineAudioStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val source = completedAudio(owner)
        val child = OfflineAudioStorage(locations("child-one"))
        expectFailure { child.importCompletedDownload(owner, "42") { error("Parent authorization expired") } }
        assertTrue(child.listManifests().isEmpty())
        assertNull(child.importedBookId(DEFAULT_ADULT_PROFILE_ID, "42"))
        assertTrue(owner.isDownloaded("42"))
        assertEquals("audio bytes", source.readText())
    }

    @Test
    fun embeddedReadAloudRequiresInternalCommittedAudio() {
        val owner = ComicOfflineStorage(locations(DEFAULT_ADULT_PROFILE_ID))
        val child = ComicOfflineStorage(locations("child-one"))
        for ((id, audioReference) in listOf("internal" to "audio.mp3", "external" to "https://example.invalid/audio.mp3")) {
            val temp = owner.createTempFile(id, "epub")
            java.util.zip.ZipOutputStream(temp.outputStream()).use { zip ->
                val entries = mapOf(
                    "META-INF/container.xml" to "<container><rootfiles><rootfile full-path=\"content.opf\"/></rootfiles></container>",
                    "content.opf" to "<package><manifest><item id=\"text\" href=\"text.xhtml\" media-type=\"application/xhtml+xml\" media-overlay=\"overlay\"/><item id=\"overlay\" href=\"overlay.smil\" media-type=\"application/smil+xml\"/></manifest><spine><itemref idref=\"text\"/></spine></package>",
                    "overlay.smil" to "<smil><body><seq><par><audio src=\"$audioReference\"/></par></seq></body></smil>",
                    "text.xhtml" to "<html><body>Text</body></html>",
                    "audio.mp3" to "committed audio",
                )
                entries.forEach { (name, content) ->
                    zip.putNextEntry(java.util.zip.ZipEntry(name))
                    zip.write(content.toByteArray())
                    zip.closeEntry()
                }
            }
            owner.commit(temp)
            owner.saveManifest(Book(id = id, title = id, source = BookSource.GRIMMORY, mediaType = AppMediaType.EBOOK))
            val imported = child.importCompletedDownload(owner, id)
            assertEquals(id == "internal", imported.readAlongAvailable)
            assertFalse(imported.hasAudio)
        }
    }

    private fun completedAudio(storage: OfflineAudioStorage): File {
        val track = storage.createTrackFinalFile("42", 0, "mp3").also { it.writeText("audio bytes") }
        storage.saveManifest(OfflineAudioManifest(
            bookId = "42",
            title = "Book title",
            author = "Author",
            coverUrl = "https://example.invalid/cover?token=test-secret",
            source = BookSource.GRIMMORY.name,
            downloadedAtEpochMs = 1L,
            tracks = listOf(OfflineAudioTrackManifest(index = 0, relativePath = storage.relativePath(track), bytes = track.length())),
        ))
        return track
    }

    private fun expectFailure(block: () -> Unit) {
        try {
            block()
            fail("Import or publication must fail")
        } catch (_: Exception) {
        }
    }

    private fun locations(profileId: String) = ProfileStorageLocations.forProfile(
        profileId = profileId,
        filesDirectory = File(root, "files"),
        cacheDirectory = File(root, "cache"),
        databaseDirectory = File(root, "databases"),
    )
}
