package com.enve.app.readium

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderNarrationKey
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReaderNarrationStoreTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var root: File
    private lateinit var locations: ProfileStorageLocations
    private lateinit var offline: ComicOfflineStorage
    private lateinit var store: ReaderNarrationStore

    private val first = ReaderNarrationKey(BookSource.AUDIOBOOKSHELF, "abs-a", "42")
    private val second = ReaderNarrationKey(BookSource.AUDIOBOOKSHELF, "abs-b", "42")

    @Before
    fun setUp() {
        root = File(context.cacheDir, "reader-narration-${UUID.randomUUID()}")
        check(root.mkdirs())
        locations = ProfileStorageLocations.forProfile(
            profileId = "reader-narration-child",
            filesDirectory = File(root, "files"),
            cacheDirectory = File(root, "cache"),
            databaseDirectory = File(root, "databases"),
        )
        offline = ComicOfflineStorage(locations)
        store = ReaderNarrationStore(context, offline, locations)
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    @Test
    fun offlineAssetBelongsOnlyToItsConnection() {
        val book = Book(id = "42", title = "Shared", source = BookSource.AUDIOBOOKSHELF, mediaType = AppMediaType.EBOOK, connectionId = "abs-a")
        val key = offlineDownloadKey(book.source, book.connectionId, book.id)
        val committed = offline.commit(offline.createTempFile(key, "epub").apply { writeBytes(byteArrayOf(0x50, 0x4b, 0x03, 0x04)) })
        offline.saveManifest(book)

        assertEquals(committed, store.existingReaderAsset(first))
        assertNull(store.existingReaderAsset(second))
    }

    @Test
    fun unscopedCachedEbookIsIgnoredForRemoteConnection() {
        File(locations.cacheDirectory, "ebooks").apply { mkdirs() }.resolve("42.epub").writeBytes(byteArrayOf(1))

        assertNull(store.existingReaderAsset(first))
        assertEquals(
            File(locations.cacheDirectory, "ebooks/42.epub"),
            store.existingReaderAsset(ReaderNarrationKey(BookSource.LOCAL, null, "42")),
        )
    }

    @Test
    fun narrationTimeIsKeyedByConnection() {
        store.recordNarration(first, 12.5)

        assertEquals(12.5, store.narrationTime(first)!!, 0.0)
        assertNull(store.narrationTime(second))
        store.clearNarration(second)
        assertEquals(12.5, store.narrationTime(first)!!, 0.0)
    }
}
