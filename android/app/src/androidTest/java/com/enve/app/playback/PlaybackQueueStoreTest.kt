package com.enve.app.playback

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.local.ReaderDatabase
import com.enve.engine.playback.PlaybackQueueOrigin
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlaybackQueueStoreTest {
    private lateinit var context: Context
    private lateinit var database: ReaderDatabase

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        context.deleteDatabase(DATABASE_NAME)
        database = openDatabase()
    }

    @After
    fun tearDown() {
        database.close()
        context.deleteDatabase(DATABASE_NAME)
    }

    @Test
    fun queueSurvivesDatabaseReopen() = runBlocking {
        PlaybackQueueStore(database).replace(
            bookKeys = listOf("one", "two", "three"),
            origin = PlaybackQueueOrigin.PLAY_ALL,
            groupKey = "SERIES:Example",
        )

        database.close()
        database = openDatabase()
        val restored = PlaybackQueueStore(database).snapshot()

        assertEquals(listOf("one", "two", "three"), restored.map(PlaybackQueueEntry::bookKey))
        assertEquals(listOf(0, 1, 2), restored.map(PlaybackQueueEntry::position))
        assertEquals("SERIES:Example", restored.first().groupKey)
    }

    @Test
    fun addMoveAndAdvancePreserveEveryItemInOrder() = runBlocking {
        val store = PlaybackQueueStore(database)
        store.replace(listOf("one", "two", "three"), PlaybackQueueOrigin.PLAY_ALL)
        store.addNext("three")
        store.addLast("one")
        store.move("one", -2)

        assertEquals(listOf("one", "three", "two"), store.snapshot().map(PlaybackQueueEntry::bookKey))
        assertEquals("one", store.takeNext()?.bookKey)
        val remaining = store.snapshot()
        assertEquals(listOf("three", "two"), remaining.map(PlaybackQueueEntry::bookKey))
        assertEquals(listOf(0, 1), remaining.map(PlaybackQueueEntry::position))
    }

    private fun openDatabase(): ReaderDatabase =
        Room.databaseBuilder(context, ReaderDatabase::class.java, DATABASE_NAME)
            .allowMainThreadQueries()
            .build()

    private companion object {
        const val DATABASE_NAME = "playback-queue-test.db"
    }
}
