package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.fileimport.CompletedFileImporter
import com.enve.app.data.fileimport.ImportFile
import com.enve.app.data.fileimport.ImportItem
import com.enve.app.data.offline.OfflineAudioManifest
import com.enve.app.data.offline.OfflineAudioTrackManifest
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.app.profiles.DaggerProfileRuntimeComponent
import com.enve.app.profiles.ProfileResources
import com.enve.app.profiles.ProfileRuntimeComponent
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReaderAnnotation
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DownloadCacheReconciliationTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val opened = mutableListOf<ProfileResources>()
    private lateinit var component: ProfileRuntimeComponent

    @Before
    fun setUp() = runBlocking {
        component = openProfile()
    }

    @After
    fun tearDown() = runBlocking {
        opened.reversed().forEach { resources ->
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    @Test
    fun legacyMediaStaysReadableWhileRemoteFlagsAndShelvesAreRepaired() = runBlocking {
        val audio = book("legacy-audio").copy(isDownloaded = true, currentTime = 73, readProgress = 0.4f)
        val ebook = book("legacy-ebook").copy(mediaType = AppMediaType.EBOOK, isDownloaded = true)
        val audioDirectory = File(component.storageLocations().filesDirectory, "offline-audio/${audio.id}").apply { mkdirs() }
        val audioFile = File(audioDirectory, "track_0.mp3").apply { writeText("preserved legacy audio") }
        val audioManifest = File(audioDirectory, "manifest.json").apply {
            writeText(Json.encodeToString(OfflineAudioManifest(
                bookId = audio.id, title = audio.title, source = audio.source.name, downloadedAtEpochMs = 1,
                tracks = listOf(OfflineAudioTrackManifest(index = 0, relativePath = "${audio.id}/track_0.mp3", bytes = audioFile.length())),
            )))
        }
        val ebookDirectory = File(component.storageLocations().filesDirectory, "offline-comics/${ebook.id}").apply { mkdirs() }
        val ebookFile = File(ebookDirectory, "book.epub").apply { writeText("preserved legacy ebook") }
        val ebookManifest = File(ebookDirectory, "book.json").apply { writeText(Json.encodeToString(ebook)) }
        val audioOriginal = audioManifest.readText()
        val ebookOriginal = ebookManifest.readText()
        val dao = component.database().bookCacheDao()
        dao.upsert(listOf(audio.toCachedBook(17), ebook.toCachedBook(18)))

        component.libraryCache()
        val recoveredAudio = component.audioStorage().listManifests().single()
        val recoveredEbook = component.comicStorage().listManifests().single()
        awaitFlags(component, mapOf(audio.uniqueKey to false, ebook.uniqueKey to false,
            "LOCAL:${recoveredAudio.bookId}" to true, recoveredEbook.uniqueKey to true))

        assertEquals(setOf(recoveredAudio.bookId, recoveredEbook.id), dao.getDownloaded().map { it.id }.toSet())
        assertEquals(73L, dao.getByCacheKey(audio.uniqueKey)!!.currentTime)
        assertEquals(17L, dao.getByCacheKey(audio.uniqueKey)!!.cachedAt)
        assertEquals("preserved legacy audio", audioFile.readText())
        assertEquals("preserved legacy ebook", ebookFile.readText())
        assertEquals(audioOriginal, audioManifest.readText())
        assertEquals(ebookOriginal, ebookManifest.readText())
        assertTrue(component.audioStorage().isDownloaded(recoveredAudio.downloadKey))
        assertTrue(component.comicStorage().isDownloaded(recoveredEbook.offlineDownloadKey))
    }

    @Test
    fun accountAndProviderIdentityAndRemainingFormatDetermineAvailability() = runBlocking {
        for (id in listOf("first", "second")) component.connections().upsert(ProviderConnection(
            id = id, source = BookSource.GRIMMORY, name = id, serverUrl = "https://example.invalid", username = "", enabled = false,
        ))
        val first = book("same-id").copy(connectionId = "first", isDownloaded = false)
        val second = first.copy(connectionId = "second", isDownloaded = true)
        val otherProvider = first.copy(source = BookSource.KOMGA, connectionId = null, isDownloaded = true)
        val local = first.copy(id = "content://documents/book.epub", source = BookSource.LOCAL, connectionId = null, isDownloaded = true)
        val dao = component.database().bookCacheDao()
        dao.upsert(listOf(first, second, otherProvider, local).map { it.toCachedBook() })
        saveAudio(component, first)
        saveEbook(component, first)
        component.libraryCache()
        awaitFlags(component, mapOf(first.uniqueKey to true, second.uniqueKey to false, otherProvider.uniqueKey to false, local.uniqueKey to true))

        component.downloads().removeDownload(first.offlineDownloadKey)
        withTimeout(5_000) { component.downloads().downloadedKeys.first { first.offlineDownloadKey !in it } }
        awaitFlags(component, mapOf(first.uniqueKey to false))
        assertTrue(component.comicStorage().isDownloaded(first.offlineDownloadKey))
        assertEquals(listOf(local.id), dao.getDownloadedAudiobooksForCar(100).map { it.id })
        dao.upsert(listOf(first.copy(mediaType = AppMediaType.EBOOK).toCachedBook()))
        awaitFlags(component, mapOf(first.uniqueKey to true))
        component.comicDownloads().removeDownload(first.offlineDownloadKey)
        awaitFlags(component, mapOf(first.uniqueKey to false, local.uniqueKey to true))
        assertFalse(component.audioStorage().isDownloaded(first.offlineDownloadKey))
    }

    @Test
    fun lateCatalogRowsAndReplacementFlagsFollowCurrentFiles() = runBlocking {
        component.libraryCache()
        val remote = book("late").copy(isDownloaded = true)
        val dao = component.database().bookCacheDao()
        dao.upsert(listOf(remote.toCachedBook(10)))
        awaitFlags(component, mapOf(remote.uniqueKey to false))
        saveAudio(component, remote)
        component.downloads().refreshCompletedDownloads()
        awaitFlags(component, mapOf(remote.uniqueKey to true))
        dao.upsert(listOf(remote.copy(isDownloaded = false, currentTime = 90).toCachedBook(20)))
        awaitFlags(component, mapOf(remote.uniqueKey to true))
        assertEquals(90L, dao.getByCacheKey(remote.uniqueKey)!!.currentTime)
        assertEquals(20L, dao.getByCacheKey(remote.uniqueKey)!!.cachedAt)
        component.downloads().removeDownload(remote.offlineDownloadKey)
        awaitFlags(component, mapOf(remote.uniqueKey to false))
        dao.upsert(listOf(remote.toCachedBook(30)))
        awaitFlags(component, mapOf(remote.uniqueKey to false))
    }

    @Test
    fun profilesWithTheSameBookHaveIndependentDownloadFlags() = runBlocking {
        val other = openProfile()
        val remote = book("shared-id").copy(isDownloaded = true)
        for (target in listOf(component, other)) target.database().bookCacheDao().upsert(listOf(remote.toCachedBook()))
        saveAudio(component, remote)
        component.libraryCache()
        other.libraryCache()
        awaitFlags(component, mapOf(remote.uniqueKey to true))
        awaitFlags(other, mapOf(remote.uniqueKey to false))
        assertTrue(component.audioStorage().isDownloaded(remote.offlineDownloadKey))
        assertFalse(other.audioStorage().isDownloaded(remote.offlineDownloadKey))
    }

    @Test
    fun importedEbookRemovalSurvivesRestartAndReimportPreservesReadingData() = runBlocking {
        val bytes = "local ebook bytes".toByteArray()
        val item = ImportItem.Document(ImportFile("Local.epub", bytes.size.toLong(), "local-document") { bytes.inputStream() })
        component.libraryCache()
        val imported = importer(component).import(item)
        val dao = component.database().bookCacheDao()
        dao.upsert(listOf(imported.copy(epubProgress = 0.4f, readProgress = 0.4f, epubLocator = "saved locator").toCachedBook(123)))
        val annotation = ReaderAnnotation(id = "local-note", bookId = imported.id, note = "Keep this note")
        component.database().annotationDao().upsert(annotation)
        awaitFlags(component, mapOf(imported.uniqueKey to true))

        component.library().removeDownload(imported)
        awaitFlags(component, mapOf(imported.uniqueKey to false))
        assertTrue(dao.getDownloaded().isEmpty())
        assertFalse(component.comicStorage().isDownloaded(imported.offlineDownloadKey))
        val resources = opened.single()
        val profileId = resources.locations.profileId
        resources.close()
        opened.remove(resources)
        component = openProfile(profileId)
        component.libraryCache()
        awaitFlags(component, mapOf(imported.uniqueKey to false))
        val retained = component.database().bookCacheDao().getByCacheKey(imported.uniqueKey)!!
        assertEquals(0.4f, retained.epubProgress)
        assertEquals("saved locator", retained.epubLocator)
        assertEquals(123L, retained.cachedAt)
        assertEquals(annotation, component.database().annotationDao().getById(annotation.id))

        val reimported = importer(component).import(item)
        assertEquals(imported.id, reimported.id)
        assertTrue(reimported.isDownloaded)
        awaitFlags(component, mapOf(imported.uniqueKey to true))
        assertEquals("saved locator", component.database().bookCacheDao().getByCacheKey(imported.uniqueKey)!!.epubLocator)
        assertTrue(component.library().deleteFromLibrary(imported))
        assertNull(component.database().bookCacheDao().getByCacheKey(imported.uniqueKey))
        assertFalse(component.comicStorage().isDownloaded(imported.offlineDownloadKey))
        assertEquals(annotation, component.database().annotationDao().getById(annotation.id))
    }

    @Test
    fun deletingImportedEbookGrantPreservesOtherProfilesAndTheirAvailability() = runBlocking {
        val other = openProfile()
        val source = book("local-file-shared").copy(source = BookSource.LOCAL, mediaType = AppMediaType.EBOOK)
        saveEbook(component, source)
        val imported = other.comicStorage().importCompletedDownload(component.comicStorage(), source.offlineDownloadKey)
        component.database().bookCacheDao().upsert(listOf(source.toCachedBook()))
        other.database().bookCacheDao().upsert(listOf(imported.copy(epubLocator = "other profile locator").toCachedBook()))
        component.libraryCache()
        other.libraryCache()
        awaitFlags(component, mapOf(source.uniqueKey to true))
        awaitFlags(other, mapOf(imported.uniqueKey to true))
        val sharedFile = other.comicStorage().getDownloadedFile(imported.offlineDownloadKey)!!.canonicalFile

        component.library().removeDownload(source)
        awaitFlags(component, mapOf(source.uniqueKey to false))
        awaitFlags(other, mapOf(imported.uniqueKey to true))
        assertEquals("complete ebook", other.comicStorage().getDownloadedFile(imported.offlineDownloadKey)!!.readText())
        assertTrue(sharedFile.exists())
        assertEquals("other profile locator", other.database().bookCacheDao().getByCacheKey(imported.uniqueKey)!!.epubLocator)
        assertTrue(component.library().deleteFromLibrary(source))
        assertNull(component.database().bookCacheDao().getByCacheKey(source.uniqueKey))
        assertTrue(other.comicStorage().isDownloaded(imported.offlineDownloadKey))
        other.library().removeDownload(imported)
        awaitFlags(other, mapOf(imported.uniqueKey to false))
        assertFalse(sharedFile.exists())
        assertTrue(other.library().deleteFromLibrary(imported))
        assertNull(other.database().bookCacheDao().getByCacheKey(imported.uniqueKey))
    }

    @Test
    fun recoveredEbookCanBeRemovedAndExplicitlyDeletedWithoutFolderConnection() = runBlocking {
        val legacy = book("orphaned-ebook").copy(mediaType = AppMediaType.EBOOK)
        val directory = File(component.storageLocations().filesDirectory, "offline-comics/${legacy.id}").apply { mkdirs() }
        File(directory, "book.epub").writeText("recovered ebook")
        File(directory, "book.json").writeText(Json.encodeToString(legacy))
        component.libraryCache()
        val recovered = component.comicStorage().listManifests().single()
        awaitFlags(component, mapOf(recovered.uniqueKey to true))
        component.library().removeDownload(recovered)
        awaitFlags(component, mapOf(recovered.uniqueKey to false))
        assertTrue(component.library().deleteFromLibrary(recovered))
        assertNull(component.database().bookCacheDao().getByCacheKey(recovered.uniqueKey))
        assertFalse(directory.exists())
    }

    private fun importer(target: ProfileRuntimeComponent) = CompletedFileImporter(
        target.audioStorage(), target.comicStorage(), target.database(), target.storageLocations(),
    ) {
        target.downloads().refreshCompletedDownloads()
        target.comicDownloads().refreshCompletedDownloads()
    }

    private suspend fun openProfile(id: String = "cache-test-${UUID.randomUUID()}"): ProfileRuntimeComponent {
        val resources = ProfileResources.open(context, id)
        opened += resources
        return DaggerProfileRuntimeComponent.factory().create(resources)
    }

    private fun book(id: String) = Book(id = id, title = id, source = BookSource.GRIMMORY, mediaType = AppMediaType.AUDIOBOOK)

    private suspend fun awaitFlags(target: ProfileRuntimeComponent, expected: Map<String, Boolean>) {
        withTimeout(10_000) {
            target.database().bookCacheDao().observeDownloadStates().first { rows ->
                expected.all { (key, downloaded) -> rows.any { it.cacheKey == key && it.isDownloaded == downloaded } }
            }
        }
    }

    private fun saveAudio(target: ProfileRuntimeComponent, book: Book) {
        val storage = target.audioStorage()
        val track = storage.createTrackFinalFile(book.offlineDownloadKey, 0, "mp3").apply { writeText("complete audio") }
        storage.saveManifest(OfflineAudioManifest(
            bookId = book.id, title = book.title, source = book.source.name, downloadedAtEpochMs = 1,
            connectionId = book.connectionId, downloadKey = book.offlineDownloadKey,
            tracks = listOf(OfflineAudioTrackManifest(index = 0, relativePath = storage.relativePath(track), bytes = track.length())),
        ))
    }

    private fun saveEbook(target: ProfileRuntimeComponent, book: Book) {
        val storage = target.comicStorage()
        storage.commit(storage.createTempFile(book.offlineDownloadKey, "epub").apply { writeText("complete ebook") })
        storage.saveManifest(book.copy(mediaType = AppMediaType.EBOOK))
    }
}
