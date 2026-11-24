package com.enve.app.data.local

import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.local.PendingProgressPush
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class PendingSyncRecoveryTest {
    @Test
    fun failureSurvivesReopenAndCapturedActionsCannotChangeANewerCheckpoint() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val name = "sync-recovery-${UUID.randomUUID()}.db"
        fun open() = Room.databaseBuilder(context, ReaderDatabase::class.java, name).build()
        var db = open()
        try {
            val original = PendingProgressPush("42", connectionKey = "server-a", mediaType = "EBOOK",
                percentage = 0.4f, isFinished = false, createdAt = 100L)
            val other = original.copy(connectionKey = "server-b")
            var dao = db.pendingProgressPushDao()
            dao.upsert(original)
            dao.upsert(other)
            assertEquals(1, dao.recordFailureIfUnchanged("42", original.source, "server-a", 100L, 0.4f, original.mediaType, original.isFinished, 200L, "Try again."))
            db.close()
            db = open()
            dao = db.pendingProgressPushDao()
            assertEquals("Try again.", dao.get("42", original.source, "server-a")?.lastError)
            assertNull(dao.get("42", original.source, "server-b")?.lastError)
            val newer = original.copy(createdAt = 300L, percentage = 0.2f)
            dao.upsert(newer)
            assertEquals(0, dao.deleteIfUnchanged("42", original.source, "server-a", 100L, 0.4f, original.mediaType, original.isFinished))
            assertEquals(0, dao.recordFailureIfUnchanged("42", original.source, "server-a", 100L, 0.4f, original.mediaType, original.isFinished, 400L, "Old failure"))
            assertEquals(newer, dao.get("42", original.source, "server-a"))
            val finished = newer.copy(isFinished = true)
            dao.upsert(finished)
            assertEquals(0, dao.deleteIfUnchanged("42", newer.source, "server-a", newer.createdAt, newer.percentage, newer.mediaType, false))
            assertEquals(0, dao.recordFailureIfUnchanged("42", newer.source, "server-a", newer.createdAt, newer.percentage,
                newer.mediaType, false, 500L, "Old failure"))
            assertEquals(finished, dao.get("42", original.source, "server-a"))
            assertEquals(1, dao.deleteIfUnchanged("42", original.source, "server-a", 300L, 0.2f, finished.mediaType, finished.isFinished))
            assertEquals(listOf(other), dao.observeAll().first())
        } finally {
            db.close()
            context.deleteDatabase(name)
        }
    }
}
