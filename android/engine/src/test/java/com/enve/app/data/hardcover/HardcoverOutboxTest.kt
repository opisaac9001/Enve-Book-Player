package com.enve.app.data.hardcover

import com.enve.core.data.model.AppMediaType
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HardcoverOutboxTest {
    private class Disk {
        val rows = MutableStateFlow<List<HardcoverOutboxEvent>>(emptyList())
        var nextId = 1L
    }

    private class DiskDao(private val disk: Disk) : HardcoverOutboxDao {
        private fun update(transform: (List<HardcoverOutboxEvent>) -> List<HardcoverOutboxEvent>) {
            disk.rows.value = transform(disk.rows.value)
        }

        private fun edit(predicate: (HardcoverOutboxEvent) -> Boolean, change: (HardcoverOutboxEvent) -> HardcoverOutboxEvent) =
            update { rows -> rows.map { if (predicate(it)) change(it) else it } }

        override suspend fun insert(event: HardcoverOutboxEvent): Long {
            val id = disk.nextId++
            update { it + event.copy(id = id) }
            return id
        }

        override suspend fun forAccount(accountKey: String) = disk.rows.value.filter { it.accountKey == accountKey }.sortedBy { it.id }

        override fun observe(accountKey: String): Flow<List<HardcoverOutboxEvent>> =
            disk.rows.map { rows -> rows.filter { it.accountKey == accountKey }.sortedBy { it.id } }

        override suspend fun forBook(accountKey: String, localKey: String) =
            forAccount(accountKey).filter { it.localKey == localKey }

        override suspend fun delete(ids: List<Long>) = update { rows -> rows.filterNot { it.id in ids } }

        override suspend fun defer(id: Long, attempts: Int, nextAttemptAt: Long, waitingForNetwork: Boolean, error: String) =
            edit({ it.id == id }) { it.copy(attempts = attempts, nextAttemptAt = nextAttemptAt, waitingForNetwork = waitingForNetwork, lastError = error) }

        override suspend fun fail(id: Long, error: String) = edit({ it.id == id }) { it.copy(failed = true, lastError = error) }

        override suspend fun retryFailed(accountKey: String) =
            edit({ it.accountKey == accountKey && it.failed }) { it.copy(failed = false, attempts = 0, nextAttemptAt = 0, waitingForNetwork = false, lastError = null) }

        override suspend fun retryBook(accountKey: String, localKey: String) =
            edit({ it.accountKey == accountKey && it.localKey == localKey && it.failed }) {
                it.copy(failed = false, attempts = 0, nextAttemptAt = 0, waitingForNetwork = false, lastError = null)
            }

        override suspend fun discardFailed(accountKey: String) = update { rows -> rows.filterNot { it.accountKey == accountKey && it.failed } }

        override suspend fun deleteBook(localKey: String) = update { rows -> rows.filterNot { it.localKey == localKey } }

        override suspend fun networkRestored(accountKey: String, now: Long) =
            edit({ it.accountKey == accountKey && it.waitingForNetwork && !it.failed }) { it.copy(nextAttemptAt = now) }

        override suspend fun clear() = update { emptyList() }
    }

    private fun event(
        localKey: String = "ABS:conn:book-1",
        fraction: Float = 0.3f,
        finished: Boolean = false,
        accountKey: String = "account-a",
        occurredAt: Long = 1_000L,
    ) = HardcoverOutboxEvent(
        accountKey = accountKey,
        localKey = localKey,
        bookId = localKey.substringAfterLast(':'),
        connectionId = "conn",
        mediaType = AppMediaType.EBOOK,
        title = "Dune",
        author = "Frank Herbert",
        isbn10 = null,
        isbn13 = "9780441172719",
        asin = null,
        fraction = fraction,
        finished = finished,
        occurredAt = occurredAt,
    )

    private fun schedule(dao: HardcoverOutboxDao, now: Long = 10_000L, lastSentAt: Map<String, Long> = emptyMap()) =
        runBlocking { hardcoverOutboxSchedule(dao.forAccount("account-a"), now, lastSentAt, progressIntervalMs = 60_000) }

    @Test fun persistedEventsSurviveRestartWithSnapshotAndOriginalDate() = runBlocking {
        val disk = Disk()
        DiskDao(disk).enqueue(event(occurredAt = 1_700_000_000_000))
        DiskDao(disk).enqueue(event(localKey = "ABS:conn:book-2", finished = true, fraction = 1f, occurredAt = 1_700_000_100_000))

        val restarted = DiskDao(disk)
        val replay = restarted.forAccount("account-a")
        assertEquals(listOf("ABS:conn:book-1", "ABS:conn:book-2"), replay.map { it.localKey })
        assertEquals(1_700_000_000_000L, replay.first().occurredAt)
        assertEquals("9780441172719", replay.first().isbn13)
        assertEquals("Frank Herbert", replay.first().author)
        assertEquals(replay.first(), schedule(restarted).ready)
    }

    @Test fun progressCoalescesButCompletedReadStaysAheadOfReread() = runBlocking {
        val dao = DiskDao(Disk())
        dao.enqueue(event(fraction = 0.3f))
        dao.enqueue(event(fraction = 0.6f))
        assertEquals(listOf(0.6f), dao.forAccount("account-a").map { it.fraction })

        dao.enqueue(event(fraction = 1f, finished = true, occurredAt = 2_000))
        dao.enqueue(event(fraction = 1f, finished = true, occurredAt = 3_000))
        dao.enqueue(event(fraction = 0.02f, occurredAt = 4_000))
        dao.enqueue(event(fraction = 0.05f, occurredAt = 5_000))

        val queued = dao.forAccount("account-a")
        assertEquals(listOf(false, true, false), queued.map { it.finished })
        assertEquals(2_000L, queued[1].occurredAt)
        assertEquals(0.05f, queued.last().fraction)
        assertEquals(0.6f, schedule(dao).ready!!.fraction)
    }

    @Test fun olderRequestFinishingNeverRemovesNewerEvent() = runBlocking {
        val dao = DiskDao(Disk())
        val inFlight = dao.enqueue(event(fraction = 0.2f))
        val newer = dao.enqueue(event(fraction = 0.4f))

        dao.delete(listOf(inFlight))
        dao.defer(inFlight, attempts = 1, nextAttemptAt = 99_999, waitingForNetwork = true, error = "offline")

        val remaining = dao.forAccount("account-a").single()
        assertEquals(newer, remaining.id)
        assertEquals(0.4f, remaining.fraction)
        assertEquals(0, remaining.attempts)
    }

    @Test fun finishedEventInFlightIsNotSupersededByLaterProgress() = runBlocking {
        val dao = DiskDao(Disk())
        val finish = dao.enqueue(event(fraction = 1f, finished = true))
        dao.enqueue(event(fraction = 0.03f))
        dao.delete(listOf(finish))
        assertEquals(listOf(0.03f), dao.forAccount("account-a").map { it.fraction })
    }

    @Test fun accountsNeverShareQueuedWork() = runBlocking {
        val dao = DiskDao(Disk())
        dao.enqueue(event(accountKey = "account-a", fraction = 0.3f))
        dao.enqueue(event(accountKey = "account-b", fraction = 0.9f))
        val failedB = dao.enqueue(event(accountKey = "account-b", localKey = "ABS:conn:book-2"))
        dao.fail(failedB, "rejected")

        assertEquals(listOf(0.3f), dao.forAccount("account-a").map { it.fraction })
        dao.discardFailed("account-a")
        dao.retryFailed("account-a")
        assertTrue(dao.forAccount("account-b").single { it.id == failedB }.failed)
        assertEquals(2, dao.forAccount("account-b").size)
        assertEquals(0.3f, schedule(dao).ready!!.fraction)
    }

    @Test fun failedHeadBlocksOnlyItsOwnBookUntilRetried() = runBlocking {
        val dao = DiskDao(Disk())
        val finish = dao.enqueue(event(fraction = 1f, finished = true))
        dao.enqueue(event(fraction = 0.04f))
        dao.enqueue(event(localKey = "ABS:conn:book-2", fraction = 0.5f))
        dao.fail(finish, "No exact Hardcover match.")

        assertEquals("ABS:conn:book-2", schedule(dao).ready!!.localKey)
        val blocked = schedule(dao, lastSentAt = mapOf("ABS:conn:book-2" to 10_000L))
        assertNull(blocked.ready)
        assertEquals(70_000L, blocked.wakeAt)

        dao.retryBook("account-a", "ABS:conn:book-1")
        assertEquals(finish, schedule(dao).ready!!.id)
    }

    @Test fun deferredEventsWaitForBackoffAndNetworkRestoreExpeditesOnlyOfflineRows() = runBlocking {
        val dao = DiskDao(Disk())
        val offline = dao.enqueue(event())
        val throttled = dao.enqueue(event(localKey = "ABS:conn:book-2"))
        dao.defer(offline, attempts = 3, nextAttemptAt = 500_000, waitingForNetwork = true, error = "offline")
        dao.defer(throttled, attempts = 1, nextAttemptAt = 3_610_000, waitingForNetwork = false, error = "rate limited")

        val waiting = schedule(dao)
        assertNull(waiting.ready)
        assertEquals(500_000L, waiting.wakeAt)

        dao.networkRestored("account-a", now = 10_000)
        assertEquals(offline, schedule(dao).ready!!.id)
        assertEquals(3_610_000L, dao.forAccount("account-a").single { it.id == throttled }.nextAttemptAt)
    }

    @Test fun backoffGrowsAndIsBounded() {
        assertEquals(30_000L, hardcoverBackoffMs(1))
        assertEquals(60_000L, hardcoverBackoffMs(2))
        assertEquals(480_000L, hardcoverBackoffMs(5))
        assertEquals(30 * 60_000L, hardcoverBackoffMs(7))
        assertEquals(30 * 60_000L, hardcoverBackoffMs(50))
    }

    @Test fun progressIsThrottledPerBookButFinishIsNot() {
        val dao = DiskDao(Disk())
        runBlocking {
            dao.enqueue(event(fraction = 0.5f))
            dao.enqueue(event(localKey = "ABS:conn:book-2", fraction = 1f, finished = true))
        }
        val sent = mapOf("ABS:conn:book-1" to 9_000L, "ABS:conn:book-2" to 9_000L)
        assertEquals("ABS:conn:book-2", schedule(dao, lastSentAt = sent).ready!!.localKey)
    }

    @Test fun summaryCountsPendingFailuresAndStorageErrors() {
        val events = listOf(
            event().copy(id = 1),
            event(localKey = "ABS:conn:book-2").copy(id = 2, failed = true, lastError = "Hardcover rejected it."),
        )
        assertEquals(
            HardcoverQueueSummary(
                pending = 1,
                failed = listOf(HardcoverQueueFailure(2, "Dune", "Hardcover rejected it.")),
                storageError = "disk full",
            ),
            hardcoverQueueSummary(events, "disk full"),
        )
    }
    @Test fun secondOfflineCompletionKeepsTheRereadBetweenFinishes() = runBlocking {
        val dao = DiskDao(Disk())
        dao.enqueue(event(fraction = 1f, finished = true, occurredAt = 100))
        dao.enqueue(event(fraction = 0.02f, occurredAt = 200))
        dao.enqueue(event(fraction = 0.8f, occurredAt = 300))
        dao.enqueue(event(fraction = 1f, finished = true, occurredAt = 400))
        val rows = dao.forAccount("account-a")
        assertEquals(listOf(true, false, true), rows.map { it.finished })
        assertEquals(0.02f, rows[1].initialFraction)
        assertEquals(200L, rows[1].startedAt)
        assertEquals(300L, rows[1].occurredAt)
    }

    @Test fun newerProgressCannotEraseAPermanentFailureOrBackoff() = runBlocking {
        val dao = DiskDao(Disk())
        val failed = dao.enqueue(event())
        dao.fail(failed, "Invalid edition")
        dao.enqueue(event(fraction = 0.5f))
        assertNull(schedule(dao).ready)
        assertTrue(dao.forAccount("account-a").first().failed)
        val waiting = dao.enqueue(event(localKey = "other"))
        dao.defer(waiting, 3, 500_000, false, "rate limit")
        dao.enqueue(event(localKey = "other", fraction = 0.7f))
        assertNull(schedule(dao).ready)
        assertEquals(500_000L, schedule(dao).wakeAt)
    }

}
