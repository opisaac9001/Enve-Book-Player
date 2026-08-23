package com.enve.app.data.duplicates

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.BookMetadataOverride
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.LinkedBookPair
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.UserCollection
import com.enve.core.data.local.UserCollectionBook
import com.enve.core.data.local.toBook
import com.enve.core.data.model.DuplicateBookAnalyzer
import com.enve.core.data.model.MergeAggressiveness
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.VocabEntry
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DuplicateMergeRepositoryTest {

    private lateinit var db: ReaderDatabase
    private lateinit var repository: DuplicateMergeRepository

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        db = Room.inMemoryDatabaseBuilder(context, ReaderDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        repository = DuplicateMergeRepository(db)
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun mergeCluster_removesLoserRowAndMovesRoomBackedLocalState() = runBlocking {
        val keep = cachedBook(
            id = "keep",
            title = "Dune",
            author = null,
            readProgress = 0.1f,
            categoriesJson = """["Classic"]""",
        )
        val drop = cachedBook(
            id = "drop",
            title = "Dune",
            author = "Frank Herbert",
            description = "A rich desert planet novel.",
            publisher = "Ace",
            currentTime = 600L,
            duration = 1000L,
            readProgress = 0.6f,
            lastReadTime = 5000L,
            categoriesJson = """["Science Fiction"]""",
        )

        db.bookCacheDao().upsert(listOf(keep, drop))
        db.userCollectionDao().upsertCollection(
            UserCollection(
                id = "favorites",
                name = "Favorites",
                description = null,
                iconName = "folder",
                colorHex = "#F5921A",
                createdAt = 1000L,
                updatedAt = 1000L,
            )
        )
        db.userCollectionDao().addBook(
            UserCollectionBook(
                collectionId = "favorites",
                bookKey = drop.cacheKey,
                addedAt = 2000L,
            )
        )
        db.linkedBookPairDao().upsert(
            LinkedBookPair(
                ebookKey = drop.cacheKey,
                audiobookKey = "audio:companion",
                updatedAt = 3000L,
            )
        )
        db.annotationDao().upsert(
            ReaderAnnotation(
                id = "annotation-1",
                bookId = drop.cacheKey,
                selectedText = "Fear is the mind-killer.",
            )
        )
        db.vocabEntryDao().upsert(
            VocabEntry(
                id = "vocab-1",
                bookStableId = drop.cacheKey,
                word = "kwisatz",
                sentence = "Kwisatz Haderach",
            )
        )
        db.pendingProgressPushDao().upsert(
            PendingProgressPush(
                bookId = drop.id,
                source = drop.source,
                connectionKey = drop.connectionId.orEmpty(),
                mediaType = "EBOOK",
                percentage = 0.6f,
                isFinished = false,
                createdAt = 4000L,
            )
        )
        db.bookExtrasDao().upsert(
            BookExtras(
                cacheKey = keep.cacheKey,
                audioTracksJson = """[{"file":"keeper.mp3"}]""",
                updatedAt = 4500L,
            )
        )
        db.bookExtrasDao().upsert(
            BookExtras(
                cacheKey = drop.cacheKey,
                chaptersJson = """[{"title":"Arrakis"}]""",
                updatedAt = 5000L,
            )
        )
        db.bookMetadataOverrideDao().upsert(
            BookMetadataOverride(
                bookKey = drop.cacheKey,
                title = "Dune",
                subtitle = null,
                author = "Frank Herbert",
                narrator = null,
                description = "A rich desert planet novel.",
                seriesName = "Dune",
                seriesNumber = "1",
                publisher = "Ace",
                publishedDate = "1965",
                isbn13 = "9780441172719",
                language = "en",
                pageCount = 896,
                updatedAt = 6000L,
            )
        )

        val cluster = DuplicateBookAnalyzer.findClusters(
            books = listOf(keep.toBook(), drop.toBook()),
            aggressiveness = MergeAggressiveness.NORMAL,
        ).single()

        val result = repository.mergeCluster(cluster, keep.cacheKey)

        val merged = db.bookCacheDao().getByCacheKey(keep.cacheKey)
        assertEquals(listOf(drop.cacheKey), result.removedBookKeys)
        assertNull(db.bookCacheDao().getByCacheKey(drop.cacheKey))
        assertNotNull(merged)
        assertEquals("Frank Herbert", merged?.author)
        assertEquals("A rich desert planet novel.", merged?.description)
        assertEquals("Ace", merged?.publisher)
        assertEquals(0.6f, merged?.readProgress ?: 0f, 0.001f)
        assertEquals(600L, merged?.currentTime)
        assertTrue(merged?.categoriesJson.orEmpty().contains("Science Fiction"))

        assertEquals(keep.cacheKey, db.userCollectionDao().booksInCollection("favorites").single().cacheKey)
        assertNotNull(db.linkedBookPairDao().getForEbook(keep.cacheKey))
        assertNull(db.linkedBookPairDao().getForEbook(drop.cacheKey))
        assertEquals(keep.cacheKey, db.annotationDao().getByBook(keep.cacheKey).single().bookId)
        assertTrue(db.annotationDao().getByBook(drop.cacheKey).isEmpty())
        assertEquals(keep.cacheKey, db.vocabEntryDao().getAll().single().bookStableId)
        assertNotNull(db.pendingProgressPushDao().get(keep.id, keep.source, keep.connectionId.orEmpty()))
        assertNull(db.pendingProgressPushDao().get(drop.id, drop.source, drop.connectionId.orEmpty()))
        val mergedExtras = db.bookExtrasDao().get(keep.cacheKey)
        assertNotNull(mergedExtras)
        assertTrue(mergedExtras?.chaptersJson.orEmpty().contains("Arrakis"))
        assertTrue(mergedExtras?.audioTracksJson.orEmpty().contains("keeper.mp3"))
        assertNull(db.bookExtrasDao().get(drop.cacheKey))
        assertNotNull(db.bookMetadataOverrideDao().getForBook(keep.cacheKey))
        assertNull(db.bookMetadataOverrideDao().getForBook(drop.cacheKey))
    }

    private fun cachedBook(
        id: String,
        title: String,
        author: String? = null,
        description: String? = null,
        publisher: String? = null,
        currentTime: Long = 0L,
        duration: Long = 0L,
        readProgress: Float = 0f,
        lastReadTime: Long = 0L,
        categoriesJson: String = "[]",
    ) = CachedBook(
        cacheKey = "test-conn:$id",
        id = id,
        connectionId = "test-conn",
        source = "GRIMMORY",
        mediaType = "EBOOK",
        title = title,
        author = author,
        narrator = null,
        coverUrl = null,
        duration = duration,
        currentTime = currentTime,
        isFinished = false,
        readProgress = readProgress,
        epubProgress = null,
        epubLocator = null,
        lastReadTime = lastReadTime,
        addedOn = 0L,
        libraryId = null,
        libraryName = null,
        seriesName = null,
        seriesNumber = null,
        publisher = publisher,
        publishedDate = null,
        description = description,
        language = null,
        pageCount = null,
        isDownloaded = false,
        hideFromContinue = false,
        readAlongAvailable = false,
        categoriesJson = categoriesJson,
        subtitle = null,
        isbn13 = null,
        personalRating = null,
        goodreadsRating = null,
        primaryFileType = null,
        inProgress = readProgress > 0f,
        cachedAt = 0L,
    )
}
