package com.enve.app.data.fileimport

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.offline.OfflineAudioStorage
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompletedFileImporterTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var root: File
    private lateinit var database: ReaderDatabase
    private lateinit var locations: ProfileStorageLocations
    private lateinit var audio: OfflineAudioStorage
    private lateinit var ebooks: ComicOfflineStorage
    private val refreshes = AtomicInteger()

    @Before
    fun setUp() {
        root = File(context.cacheDir, "completed-file-import-${UUID.randomUUID()}")
        check(root.mkdirs())
        database = Room.inMemoryDatabaseBuilder(context, ReaderDatabase::class.java).build()
        locations = ProfileStorageLocations.forProfile(
            profileId = "cloud-import-child",
            filesDirectory = File(root, "files"),
            cacheDirectory = File(root, "cache"),
            databaseDirectory = File(root, "databases"),
        )
        audio = OfflineAudioStorage(locations)
        ebooks = ComicOfflineStorage(locations)
    }

    @After
    fun tearDown() {
        database.close()
        root.deleteRecursively()
    }

    private fun importer() = CompletedFileImporter(audio, ebooks, database, locations) { refreshes.incrementAndGet() }

    private fun source(name: String, bytes: ByteArray, identity: String? = "test:$name", opens: AtomicInteger? = null) =
        ImportFile(name, bytes.size.toLong(), identity) {
            opens?.incrementAndGet()
            ByteArrayInputStream(bytes)
        }

    private fun epubBytes(): ByteArray {
        val output = ByteArrayOutputStream()
        ZipOutputStream(output).use { zip ->
            fun put(name: String, bytes: ByteArray) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
            put("mimetype", "application/epub+zip".toByteArray())
            put(
                "META-INF/container.xml",
                """<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf"/></rootfiles></container>""".toByteArray(),
            )
            put(
                "content.opf",
                """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Imported Serial</dc:title><dc:creator>Writer</dc:creator></metadata><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/><item id="art" href="cover.jpg" media-type="image/jpeg" properties="cover-image"/></manifest></package>""".toByteArray(),
            )
            put("c.xhtml", "<html/>".toByteArray())
            put("cover.jpg", byteArrayOf(1, 2, 3))
        }
        return output.toByteArray()
    }

    @Test
    fun epubBecomesAnOfflineLocalBookInThisProfile() = runBlocking {
        val bytes = epubBytes()

        val book = importer().import(ImportItem.Document(source("serial.epub", bytes)))

        assertEquals(BookSource.LOCAL, book.source)
        assertNull(book.connectionId)
        assertEquals(AppMediaType.EBOOK, book.mediaType)
        assertEquals("Imported Serial", book.title)
        assertEquals("Writer", book.author)
        assertEquals("EPUB", book.primaryFileType)
        assertTrue(book.isDownloaded)
        assertTrue(ebooks.isDownloaded(book.id))
        assertEquals(bytes.toList(), checkNotNull(ebooks.getDownloadedFile(book.id)).readBytes().toList())
        assertEquals(listOf<Byte>(1, 2, 3), File(checkNotNull(android.net.Uri.parse(book.coverUrl).path)).readBytes().toList())
        assertNotNull(database.bookCacheDao().getByCacheKey(book.uniqueKey))
        assertEquals(1, refreshes.get())
        val owner = ProfileStorageLocations.forProfile(
            profileId = DEFAULT_ADULT_PROFILE_ID,
            filesDirectory = File(root, "files"),
            cacheDirectory = File(root, "cache"),
            databaseDirectory = File(root, "databases"),
        )
        assertTrue(ComicOfflineStorage(owner).listManifests().isEmpty())
    }

    @Test
    fun reimportingTheSameSourceReusesTheOfflineCopy() = runBlocking {
        val opens = AtomicInteger()
        val bytes = "%PDF-1.7 test".toByteArray()

        val first = importer().import(ImportItem.Document(source("Manual.pdf", bytes, opens = opens)))
        val second = importer().import(ImportItem.Document(source("Manual.pdf", bytes, opens = opens)))

        assertEquals(first.id, second.id)
        assertEquals(1, opens.get())
        assertEquals(1, ebooks.listManifests().size)
        assertEquals("Manual", second.title)
    }

    @Test
    fun audiobookTracksAreStoredInOrderUnderOneBook() = runBlocking {
        val tracks = listOf(
            source("Chapter 1.mp3", "one".toByteArray()),
            source("Chapter 2.mp3", "two!".toByteArray()),
        )

        val book = importer().import(ImportItem.Audiobook("Grouped", tracks))

        val manifest = checkNotNull(audio.getManifest(book.id))
        assertEquals(AppMediaType.AUDIOBOOK, book.mediaType)
        assertEquals("Grouped", book.title)
        assertEquals(BookSource.LOCAL.name, manifest.source)
        assertEquals(listOf("Chapter 1", "Chapter 2"), manifest.tracks.map { it.title })
        assertEquals(listOf(3L, 4L), manifest.tracks.map { it.bytes })
        assertEquals("two!", audio.absolutePath(manifest.tracks[1].relativePath).readText())
        assertTrue(audio.isDownloaded(book.id))
        assertTrue(checkNotNull(audio.bookDirectory(book.id).list()).none { it.endsWith(".part") })
        assertNotNull(database.bookCacheDao().getByCacheKey(book.uniqueKey))
    }

    @Test
    fun failedCopyLeavesNoPartialBook() = runBlocking {
        val failing = ImportFile("Broken.mp3", 100L, "test:broken") {
            object : InputStream() {
                private var sent = 0
                override fun read(): Int = if (sent++ < 10) 1 else throw IOException("connection reset")
            }
        }
        val item = ImportItem.Audiobook("Broken", listOf(source("Good.mp3", "ok".toByteArray()), failing))

        try {
            importer().import(item)
            fail("Expected the import to fail")
        } catch (expected: IOException) {
            assertEquals("connection reset", expected.message)
        }

        val id = ImportPlanner.bookId(item)
        assertFalse(audio.bookDirectory(id).exists())
        assertNull(database.bookCacheDao().getByCacheKey("LOCAL:$id"))
        assertEquals(0, refreshes.get())
    }

    @Test
    fun truncatedDownloadsAreRejected() = runBlocking {
        val short = ImportFile("Short.epub", 1_000L, "test:short") { ByteArrayInputStream(ByteArray(10)) }

        try {
            importer().import(ImportItem.Document(short))
            fail("Expected the import to fail")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message.orEmpty().contains("changed"))
        }

        assertTrue(ebooks.listManifests().isEmpty())
        assertFalse(ebooks.isDownloaded(ImportPlanner.bookId(ImportItem.Document(short))))
    }

    @Test
    fun cancellationRemovesTheStagedFiles() = runBlocking {
        val started = CountDownLatch(1)
        val slow = ImportFile("Slow.m4b", -1L, "test:slow") {
            object : InputStream() {
                override fun read(): Int = 1
                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    started.countDown()
                    Thread.sleep(5)
                    buffer.fill(1, offset, offset + minOf(length, 64))
                    return minOf(length, 64)
                }
            }
        }
        val item = ImportItem.Audiobook("Slow", listOf(slow))
        val job = async(Dispatchers.Default) { importer().import(item) }

        assertTrue(started.await(5, TimeUnit.SECONDS))
        job.cancelAndJoin()

        assertTrue(job.isCancelled)
        assertFalse(audio.bookDirectory(ImportPlanner.bookId(item)).exists())
        assertTrue(audio.listManifests().isEmpty())
    }

    @Test
    fun webStoryFilesImportWithoutReusingTheirTemporaryPath() = runBlocking {
        val file = File(root, "story.epub").apply { writeBytes(epubBytes()) }

        val first = importer().importFile(file)
        val second = importer().importFile(file)

        assertEquals("Imported Serial", first.title)
        assertTrue(first.id != second.id)
        assertTrue(file.isFile)
    }

    @Test
    fun concurrentImportersOfTheSameSourceShareOneCopy() = runBlocking {
        val gate = CountDownLatch(1)
        val bytes = ByteArray(512 * 1_024) { (it % 251).toByte() }
        fun slowSource() = ImportFile("Shared.mp3", bytes.size.toLong(), "test:shared") {
            gate.await(5, TimeUnit.SECONDS)
            ByteArrayInputStream(bytes)
        }
        val first = async(Dispatchers.Default) { importer().import(ImportItem.Audiobook("Shared", listOf(slowSource()))) }
        val second = async(Dispatchers.Default) { importer().import(ImportItem.Audiobook("Shared", listOf(slowSource()))) }
        gate.countDown()

        val books = listOf(first.await(), second.await())

        assertEquals(1, books.map { it.id }.distinct().size)
        assertEquals(1, audio.listManifests().size)
        val manifest = checkNotNull(audio.getManifest(books.first().id))
        assertEquals(bytes.toList(), audio.absolutePath(manifest.tracks.single().relativePath).readBytes().toList())
        assertTrue(audio.isDownloaded(books.first().id))
    }

    @Test
    fun failedImportKeepsEarlierCompletedCopies() = runBlocking {
        val good = importer().import(ImportItem.Document(source("Kept.pdf", "%PDF-1.7".toByteArray())))
        val broken = ImportFile("Broken.pdf", 100L, "test:broken-pdf") {
            object : InputStream() {
                override fun read(): Int = throw IOException("connection reset")
            }
        }

        try {
            importer().import(ImportItem.Document(broken))
            fail("Expected the import to fail")
        } catch (_: IOException) {
        }

        assertTrue(ebooks.isDownloaded(good.id))
        assertNotNull(database.bookCacheDao().getByCacheKey(good.uniqueKey))
    }

    @Test
    fun webStoryImportRejectsUnsupportedFiles() = runBlocking {
        val file = File(root, "story.html").apply { writeText("<html/>") }

        try {
            importer().importFile(file)
            fail("Expected the import to fail")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message.orEmpty().contains("story.html"))
        }
    }
}
