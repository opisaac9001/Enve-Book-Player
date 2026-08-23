package com.enve.app.data.local

import com.enve.app.data.local.ReaderDatabase
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.BookMetadataOverride
import com.enve.core.data.local.BookMetadataOverrideDao
import com.enve.core.data.local.CustomSmartCollection
import com.enve.core.data.local.CustomSmartCollectionDao
import com.enve.core.data.local.LinkedBookPair
import com.enve.core.data.local.LinkedBookPairDao
import com.enve.core.data.local.UserCollection
import com.enve.core.data.local.UserCollectionBook
import com.enve.core.data.local.UserCollectionDao
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.first
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BookCacheDaoTest {

    private lateinit var db: ReaderDatabase
    private lateinit var dao: BookCacheDao
    private lateinit var linkedBookPairDao: LinkedBookPairDao
    private lateinit var userCollectionDao: UserCollectionDao
    private lateinit var metadataOverrideDao: BookMetadataOverrideDao
    private lateinit var customSmartCollectionDao: CustomSmartCollectionDao

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        db = Room.inMemoryDatabaseBuilder(context, ReaderDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        dao = db.bookCacheDao()
        linkedBookPairDao = db.linkedBookPairDao()
        userCollectionDao = db.userCollectionDao()
        metadataOverrideDao = db.bookMetadataOverrideDao()
        customSmartCollectionDao = db.customSmartCollectionDao()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun groupBySeries_aggregates_books_with_same_seriesName() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", seriesName = "Mistborn"),
            cachedBook(id = "2", seriesName = "Mistborn"),
            cachedBook(id = "3", seriesName = "Stormlight"),
            cachedBook(id = "4", seriesName = null),
            cachedBook(id = "5", seriesName = ""),
        ))
        val rows = dao.groupBySeries()
        assertEquals(2, rows.size)
        val byName = rows.associateBy { it.name }
        assertEquals(2, byName["Mistborn"]?.count)
        assertEquals(1, byName["Stormlight"]?.count)
    }

    @Test
    fun groupBySeries_excludes_null_and_empty_seriesName() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", seriesName = null),
            cachedBook(id = "2", seriesName = ""),
        ))
        assertEquals(0, dao.groupBySeries().size)
    }

    @Test
    fun groupByAuthor_aggregates_distinct_author_strings() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", author = "Brandon Sanderson"),
            cachedBook(id = "2", author = "Brandon Sanderson"),
            cachedBook(id = "3", author = "Janci Patterson"),
            cachedBook(id = "4", author = null),
        ))
        val rows = dao.groupByAuthor()
        assertEquals(2, rows.size)
        val byName = rows.associateBy { it.name }
        assertEquals(2, byName["Brandon Sanderson"]?.count)
        assertEquals(1, byName["Janci Patterson"]?.count)
    }

    @Test
    fun groupByNarrator_aggregates_distinct_narrator_strings() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", narrator = "Michael Kramer"),
            cachedBook(id = "2", narrator = "Michael Kramer"),
            cachedBook(id = "3", narrator = "Kate Reading"),
            cachedBook(id = "4", narrator = null),
        ))
        val rows = dao.groupByNarrator()
        assertEquals(2, rows.size)
        val byName = rows.associateBy { it.name }
        assertEquals(2, byName["Michael Kramer"]?.count)
        assertEquals(1, byName["Kate Reading"]?.count)
    }

    @Test
    fun firstCoverForSeries_returns_lowest_seriesNumber_then_oldest() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "a", seriesName = "Mistborn", seriesNumber = "2", coverUrl = "cover-2"),
            cachedBook(id = "b", seriesName = "Mistborn", seriesNumber = "1", coverUrl = "cover-1"),
            cachedBook(id = "c", seriesName = "Mistborn", seriesNumber = "3", coverUrl = "cover-3"),
        ))
        assertEquals("cover-1", dao.firstCoverForSeries("Mistborn"))
    }

    @Test
    fun firstCoverForSeries_returns_null_for_unknown_series() = runBlocking {
        dao.upsert(listOf(cachedBook(id = "a", seriesName = "Mistborn", coverUrl = "cover-1")))
        assertNull(dao.firstCoverForSeries("Stormlight"))
    }

    @Test
    fun firstCoverForAuthor_returns_most_recently_added_match() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "a", author = "Brandon Sanderson", coverUrl = "old", addedOn = 1000L),
            cachedBook(id = "b", author = "Brandon Sanderson", coverUrl = "new", addedOn = 9000L),
        ))
        assertEquals("new", dao.firstCoverForAuthor("Brandon Sanderson"))
    }

    @Test
    fun booksWhereSeries_returns_only_matching_rows() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", seriesName = "Mistborn"),
            cachedBook(id = "2", seriesName = "Mistborn"),
            cachedBook(id = "3", seriesName = "Stormlight"),
        ))
        val matches = dao.booksWhereSeries("Mistborn")
        assertEquals(2, matches.size)
        assertEquals(setOf("1", "2"), matches.map { it.id }.toSet())
    }

    @Test
    fun booksWhereAuthorLike_handles_comma_separated_authors() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", author = "Brandon Sanderson, Janci Patterson"),
            cachedBook(id = "2", author = "Brandon Sanderson"),
            cachedBook(id = "3", author = "Other"),
        ))
        val matches = dao.booksWhereAuthorLike("%Brandon%")
        assertEquals(2, matches.size)
        assertEquals(setOf("1", "2"), matches.map { it.id }.toSet())
    }

    @Test
    fun booksWhereNarratorLike_filters_by_LIKE_substring() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", narrator = "Michael Kramer"),
            cachedBook(id = "2", narrator = "Kate Reading"),
        ))
        val matches = dao.booksWhereNarratorLike("%Michael%")
        assertEquals(1, matches.size)
        assertEquals("1", matches.first().id)
    }

    @Test
    fun deleteByConnection_removes_only_that_connections_books() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", connectionId = "conn-a"),
            cachedBook(id = "2", connectionId = "conn-a"),
            cachedBook(id = "3", connectionId = "conn-b"),
        ))
        dao.deleteByConnection("conn-a")
        assertEquals(1, dao.count())
        assertEquals(0, dao.countForConnection("conn-a"))
        assertEquals(1, dao.countForConnection("conn-b"))
    }

    @Test
    fun getConnectionIds_returns_distinct_non_local_connections() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "1", connectionId = "conn-a"),
            cachedBook(id = "2", connectionId = "conn-a"),
            cachedBook(id = "3", connectionId = "conn-b"),
            cachedBook(id = "4", connectionId = null),
        ))

        assertEquals(setOf("conn-a", "conn-b"), dao.getConnectionIds().toSet())
    }

    @Test
    fun linkedBookPairs_upsert_and_lookup_by_both_sides() = runBlocking {
        linkedBookPairDao.upsert(
            LinkedBookPair(
                ebookKey = "conn:ebook-1",
                audiobookKey = "conn:audio-1",
                chapterOffset = 2,
                updatedAt = 1000L,
            )
        )

        val byEbook = linkedBookPairDao.getForEbook("conn:ebook-1")
        val byAudiobook = linkedBookPairDao.getForAudiobook("conn:audio-1")

        assertNotNull(byEbook)
        assertEquals("conn:audio-1", byEbook?.audiobookKey)
        assertEquals(2, byAudiobook?.chapterOffset)
    }

    @Test
    fun linkedBookPairs_delete_for_ebook_removes_pair() = runBlocking {
        linkedBookPairDao.upsert(
            LinkedBookPair(
                ebookKey = "conn:ebook-1",
                audiobookKey = "conn:audio-1",
                updatedAt = 1000L,
            )
        )

        linkedBookPairDao.deleteForEbook("conn:ebook-1")

        assertNull(linkedBookPairDao.getForEbook("conn:ebook-1"))
        assertNull(linkedBookPairDao.getForAudiobook("conn:audio-1"))
    }

    @Test
    fun userCollections_summary_membership_and_books_query() = runBlocking {
        dao.upsert(listOf(cachedBook(id = "1", title = "Manual Book")))
        userCollectionDao.upsertCollection(
            UserCollection(
                id = "collection-1",
                name = "Favorites",
                description = null,
                iconName = "folder",
                colorHex = "#F5921A",
                createdAt = 1000L,
                updatedAt = 1000L,
            )
        )
        userCollectionDao.addBook(
            UserCollectionBook(
                collectionId = "collection-1",
                bookKey = "test-conn:1",
                addedAt = 2000L,
            )
        )

        val summary = userCollectionDao.getSummaries().single()
        val membership = userCollectionDao.getMembershipsForBook("test-conn:1").single()
        val books = userCollectionDao.booksInCollection("collection-1")

        assertEquals("Favorites", summary.name)
        assertEquals(1, summary.bookCount)
        assertEquals(true, membership.containsBook)
        assertEquals("Manual Book", books.single().title)
    }

    @Test
    fun userCollections_delete_cascades_memberships() = runBlocking {
        userCollectionDao.upsertCollection(
            UserCollection(
                id = "collection-1",
                name = "Favorites",
                description = null,
                iconName = "folder",
                colorHex = "#F5921A",
                createdAt = 1000L,
                updatedAt = 1000L,
            )
        )
        userCollectionDao.addBook(
            UserCollectionBook(
                collectionId = "collection-1",
                bookKey = "test-conn:1",
                addedAt = 2000L,
            )
        )

        userCollectionDao.deleteCollection("collection-1")

        assertEquals(0, userCollectionDao.getSummaries().size)
        assertEquals(0, userCollectionDao.getMembershipsForBook("test-conn:1").size)
    }

    @Test
    fun metadataOverrides_persist_and_update_cached_row() = runBlocking {
        dao.upsert(listOf(cachedBook(id = "1", title = "Original Title", author = "Original Author")))

        metadataOverrideDao.upsert(
            BookMetadataOverride(
                bookKey = "test-conn:1",
                title = "Edited Title",
                subtitle = "Edited Subtitle",
                author = "Edited Author",
                narrator = null,
                description = "Edited description",
                seriesName = "Edited Series",
                seriesNumber = "2",
                publisher = "Edited Publisher",
                publishedDate = "2026",
                isbn13 = "9781234567890",
                language = "en",
                pageCount = 321,
                updatedAt = 3000L,
            )
        )
        dao.updateLocalMetadata(
            bookKey = "test-conn:1",
            title = "Edited Title",
            subtitle = "Edited Subtitle",
            author = "Edited Author",
            narrator = null,
            coverUrl = "edited-cover",
            duration = 1234L,
            description = "Edited description",
            seriesName = "Edited Series",
            seriesNumber = "2",
            publisher = "Edited Publisher",
            publishedDate = "2026",
            isbn13 = "9781234567890",
            language = "en",
            pageCount = 321,
            categoriesJson = """["Fantasy","Adventure"]""",
            nowMs = 4000L,
        )

        val override = metadataOverrideDao.getForBook("test-conn:1")
        val cached = dao.getByCacheKey("test-conn:1")

        assertEquals("Edited Title", override?.title)
        assertEquals("Edited Title", cached?.title)
        assertEquals("Edited Series", cached?.seriesName)
        assertEquals("edited-cover", cached?.coverUrl)
        assertEquals("""["Fantasy","Adventure"]""", cached?.categoriesJson)
        assertEquals(321, cached?.pageCount)
    }

    @Test
    fun updateUnifiedProgress_keeps_downloaded_audio_inProgress_when_duration_is_unknown() = runBlocking {
        dao.upsert(listOf(
            cachedBook(
                id = "downloaded-audio",
                mediaType = "AUDIOBOOK",
                isDownloaded = true,
            )
        ))

        dao.updateUnifiedProgress(
            bookId = "downloaded-audio",
            connectionId = "test-conn",
            progress = 0f,
            currentTimeSec = 125L,
            locatorJson = null,
            nowMs = 5000L,
        )

        val cached = dao.getByCacheKey("test-conn:downloaded-audio")

        assertEquals(125L, cached?.currentTime)
        assertEquals(0f, cached?.readProgress)
        assertEquals(true, cached?.inProgress)
    }

    @Test
    fun updateUnifiedProgress_preservesExactAudioTimeForEbookOnlyUpdate() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "read-aloud").copy(
                duration = 10_000L,
                currentTime = 6_543L,
                readProgress = 0.6543f,
            )
        ))

        dao.updateUnifiedProgress(
            bookId = "read-aloud",
            connectionId = "test-conn",
            progress = 0.2f,
            currentTimeSec = -1L,
            locatorJson = "{\"href\":\"chapter.xhtml\"}",
            nowMs = 5000L,
        )

        val cached = dao.getByCacheKey("test-conn:read-aloud")

        assertEquals(6_543L, cached?.currentTime)
        assertEquals(0.2f, cached?.epubProgress)
        assertEquals("{\"href\":\"chapter.xhtml\"}", cached?.epubLocator)
    }

    @Test
    fun observeCountExcludingLibrariesUsesCompositeLibraryIdentity() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "hidden").copy(libraryId = "connection-a::manga"),
            cachedBook(id = "visible").copy(libraryId = "connection-b::manga"),
            cachedBook(id = "unscoped").copy(libraryId = null),
        ))

        val count = dao.observeCountExcludingLibraries(listOf("connection-a::manga")).first()

        assertEquals(2, count)
    }

    @Test
    fun exclusionAwareListQueriesApplyVisibilityBeforeLimit() = runBlocking {
        dao.upsert(listOf(
            cachedBook(id = "hidden-newest").copy(
                libraryId = "connection-a::hidden",
                addedOn = 2_000L,
            ),
            cachedBook(id = "visible-older").copy(
                libraryId = "connection-b::visible",
                addedOn = 1_000L,
            ),
        ))

        val recent = dao.observeRecentlyAddedExcludingLibraries(
            excludedLibraryIds = listOf("connection-a::hidden"),
            limit = 1,
        ).first()
        val all = dao.observeAllForListExcludingLibraries(
            excludedLibraryIds = listOf("connection-a::hidden"),
            limit = 1,
        ).first()

        assertEquals(listOf("visible-older"), recent.map { it.id })
        assertEquals(listOf("visible-older"), all.map { it.id })
    }

    @Test
    fun customSmartCollections_persist_update_and_delete() = runBlocking {
        customSmartCollectionDao.upsert(
            CustomSmartCollection(
                id = "smart-1",
                name = "Recent Ebooks",
                description = "Books · Added in 30d",
                mediaType = "EBOOK",
                status = "ANY",
                length = "ANY",
                addedWithinDays = 30,
                query = "codex",
                createdAt = 1000L,
                updatedAt = 1000L,
            )
        )

        val inserted = customSmartCollectionDao.get("smart-1")
        assertEquals("Recent Ebooks", inserted?.name)
        assertEquals("codex", inserted?.query)

        customSmartCollectionDao.upsert(
            inserted!!.copy(
                name = "Updated Smart Rule",
                status = "UNFINISHED",
                updatedAt = 2000L,
            )
        )

        val updated = customSmartCollectionDao.getAll().single()
        assertEquals("Updated Smart Rule", updated.name)
        assertEquals("UNFINISHED", updated.status)

        customSmartCollectionDao.delete("smart-1")
        assertEquals(0, customSmartCollectionDao.getAll().size)
    }

    private fun cachedBook(
        id: String,
        title: String = "Title $id",
        connectionId: String? = "test-conn",
        seriesName: String? = null,
        seriesNumber: String? = null,
        author: String? = null,
        narrator: String? = null,
        coverUrl: String? = null,
        addedOn: Long = 0L,
        mediaType: String = "EBOOK",
        isDownloaded: Boolean = false,
    ) = CachedBook(
        cacheKey = "${connectionId.orEmpty()}:$id",
        id = id,
        connectionId = connectionId,
        source = "GRIMMORY",
        mediaType = mediaType,
        title = title,
        author = author,
        narrator = narrator,
        coverUrl = coverUrl,
        duration = 0L,
        currentTime = 0L,
        isFinished = false,
        readProgress = 0f,
        epubProgress = null,
        epubLocator = null,
        lastReadTime = 0L,
        addedOn = addedOn,
        libraryId = null,
        libraryName = null,
        seriesName = seriesName,
        seriesNumber = seriesNumber,
        publisher = null,
        publishedDate = null,
        description = null,
        language = null,
        pageCount = null,
        isDownloaded = isDownloaded,
        hideFromContinue = false,
        readAlongAvailable = false,
        categoriesJson = "[]",
        subtitle = null,
        isbn13 = null,
        personalRating = null,
        goodreadsRating = null,
        primaryFileType = null,
        inProgress = false,
        cachedAt = 0L,
    )
}
