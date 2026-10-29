package com.enve.app.data.hardcover

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.model.AppMediaType
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HardcoverOutboxDatabaseTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var file: File

    @Before fun createFile() {
        file = File(context.cacheDir, "hardcover-outbox-test-${System.nanoTime()}.db")
    }

    @After fun deleteFile() {
        context.deleteDatabase(file.absolutePath)
    }

    private fun open() = Room.databaseBuilder(context, HardcoverOutboxDatabase::class.java, file.absolutePath).build()

    private fun event(localKey: String, fraction: Float, finished: Boolean, accountKey: String = "account-a", occurredAt: Long = 1_000L) =
        HardcoverOutboxEvent(
            accountKey = accountKey,
            localKey = localKey,
            bookId = localKey,
            connectionId = null,
            mediaType = AppMediaType.AUDIOBOOK,
            title = "Book $localKey",
            author = "Author",
            isbn10 = null,
            isbn13 = "9780441172719",
            asin = null,
            fraction = fraction,
            finished = finished,
            occurredAt = occurredAt,
        )

    @Test fun queuedEventsSurviveReopenInOrderPerAccount() = runBlocking {
        val first = open()
        first.outboxDao().apply {
            enqueue(event("book-1", 0.4f, finished = false))
            enqueue(event("book-1", 1f, finished = true, occurredAt = 2_000))
            enqueue(event("book-1", 0.02f, finished = false, occurredAt = 3_000))
            enqueue(event("book-1", 0.05f, finished = false, occurredAt = 4_000))
            enqueue(event("book-1", 0.9f, finished = false, accountKey = "account-b"))
            val failed = enqueue(event("book-2", 0.5f, finished = false))
            fail(failed, "No exact Hardcover match.")
        }
        first.close()

        val reopened = open()
        try {
            val dao = reopened.outboxDao()
            val replay = dao.forAccount("account-a")
            assertEquals(listOf("book-1", "book-1", "book-1", "book-2"), replay.map { it.localKey })
            assertEquals(listOf(false, true, false, false), replay.map { it.finished })
            assertEquals(2_000L, replay[1].occurredAt)
            assertEquals(0.05f, replay[2].fraction)
            assertTrue(replay.last().failed)
            assertEquals(1, dao.forAccount("account-b").size)

            dao.retryFailed("account-a")
            assertTrue(dao.forAccount("account-a").none { it.failed })
            dao.clear()
            assertTrue(dao.forAccount("account-b").isEmpty())
        } finally {
            reopened.close()
        }
    }
}
