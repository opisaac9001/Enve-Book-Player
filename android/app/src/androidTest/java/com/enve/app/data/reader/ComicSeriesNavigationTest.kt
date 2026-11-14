package com.enve.app.data.reader

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicMetadata
import com.enve.core.data.model.ComicSection
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComicSeriesNavigationTest {

    private lateinit var db: ReaderDatabase
    private lateinit var dao: BookCacheDao

    @Before
    fun setUp() {
        db = Room.inMemoryDatabaseBuilder(ApplicationProvider.getApplicationContext(), ReaderDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        dao = db.bookCacheDao()
    }

    @After
    fun tearDown() {
        db.close()
    }

    @Test
    fun nextIssueFollowsTheTypedRunAcrossSectionsWithoutJoiningASameTitledRun() = runBlocking {
        var added = 0L
        fun issue(
            id: String,
            seriesId: String,
            comic: ComicMetadata,
            connectionId: String = "conn-a",
            libraryId: String = "lib-1",
            finished: Boolean = false,
        ) = Book(
            id = id,
            title = "Saga $id",
            source = BookSource.KAVITA,
            mediaType = AppMediaType.EBOOK,
            primaryFileType = "CBZ",
            seriesName = "Saga",
            connectionId = connectionId,
            libraryId = libraryId,
            isFinished = finished,
            addedOn = ++added,
            comic = comic.copy(seriesId = seriesId),
        ).toCachedBook(nowMs = 1L)

        fun issues(order: Double) = ComicMetadata(seriesId = "", issueOrder = order)
        fun volume(id: String, order: Double) =
            ComicMetadata(seriesId = "", section = ComicSection.VOLUMES, volumeId = id, volumeOrder = order, issueOrder = 1.0)
        val special = ComicMetadata(seriesId = "", section = ComicSection.SPECIALS, issueOrder = 1.0)

        dao.upsert(
            listOf(
                issue("a-special", "s-a", special),
                issue("a-vol2", "s-a", volume("v2", 2.0)),
                issue("a-vol1", "s-a", volume("v1", 1.0)),
                issue("a-3", "s-a", issues(3.0), finished = true),
                issue("a-2", "s-a", issues(2.0)),
                issue("a-1", "s-a", issues(1.0)),
                issue("b-1", "s-b", issues(1.5)),
                issue("b-2", "s-b", issues(2.5)),
                issue("other-lib", "s-a", issues(2.5), libraryId = "lib-2"),
                issue("a-2", "s-a", issues(2.0), connectionId = "conn-b"),
                issue("b-conn-9", "s-a", issues(9.0), connectionId = "conn-b"),
            ),
        )

        assertNext("a-2", "conn-a", from = "a-1", connectionId = "conn-a")
        assertNext("a-vol1", "conn-a", from = "a-2", connectionId = "conn-a")
        assertNext("a-vol2", "conn-a", from = "a-vol1", connectionId = "conn-a")
        assertNext("a-special", "conn-a", from = "a-vol2", connectionId = "conn-a")
        assertNull(dao.nextBookInSeries("a-special", "conn-a"))
        assertNext("b-2", "conn-a", from = "b-1", connectionId = "conn-a")
        assertNull(dao.nextBookInSeries("b-2", "conn-a"))
        assertNext("b-conn-9", "conn-b", from = "a-2", connectionId = "conn-b")
        assertNull(dao.nextBookInSeries("a-1", "conn-c"))
    }

    @Test
    fun untypedBooksKeepSeriesNumberOrder() = runBlocking {
        fun book(id: String, number: String) = Book(
            id = id,
            title = "Mistborn $number",
            source = BookSource.KOMGA,
            mediaType = AppMediaType.EBOOK,
            seriesName = "Mistborn",
            seriesNumber = number,
            connectionId = "conn-a",
        ).toCachedBook(nowMs = 1L)
        dao.upsert(listOf(book("m-2", "2"), book("m-1", "1"), book("m-3", "3")))

        assertNext("m-2", "conn-a", from = "m-1", connectionId = "conn-a")
        assertNext("m-3", "conn-a", from = "m-2", connectionId = "conn-a")
    }

    private suspend fun assertNext(expectedId: String, expectedConnection: String, from: String, connectionId: String) {
        val next = dao.nextBookInSeries(from, connectionId)
        assertEquals(expectedId, next?.id)
        assertEquals(expectedConnection, next?.connectionId)
    }
}
