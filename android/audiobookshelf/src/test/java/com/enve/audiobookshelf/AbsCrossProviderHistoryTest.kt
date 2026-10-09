package com.enve.audiobookshelf

import com.enve.audiobookshelf.listening.AbsCrossProviderHistory
import com.enve.audiobookshelf.listening.AbsLocalListeningLedger
import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.assertFalse
import org.junit.Test

class AbsCrossProviderHistoryTest {
    private val source = HistorySession(
        id = "played-session",
        bookId = "grimmory-book",
        bookKey = "grimmory:book",
        connectionId = "grimmory",
        source = BookSource.GRIMMORY,
        mediaType = AppMediaType.AUDIOBOOK,
        startTimeMs = 1_000L,
        endTimeMs = 61_000L,
        activeDurationSeconds = 28L,
    )

    private fun convert(account: String = "account") = AbsCrossProviderHistory.session(
        source = source,
        targetConnectionId = "abs",
        targetAccountId = account,
        targetItemId = "item",
        targetTitle = "Title",
        targetAuthor = null,
        targetDurationSec = 3_600L,
        currentProgressSec = 500.0,
    )!!

    @Test
    fun usesActualListeningAndStableAccountScopedId() {
        val first = convert()
        assertEquals(28.0, first.timeListeningSec, 0.001)
        assertEquals(500.0, first.currentTimeSec, 0.001)
        assertEquals(first.id, convert().id)
        assertEquals(4, java.util.UUID.fromString(first.id).version())
        assertNotEquals(first.id, convert("another-account").id)
        assertEquals(1, AbsCrossProviderHistory.enqueue(listOf(first), convert()).size)
    }

    @Test
    fun backfillRequiresNewerTargetProgressButCurrentSessionDoesNot() {
        val backfill = convert().copy(historicalBackfill = true)
        assertFalse(AbsCrossProviderHistory.mayUpload(backfill, null))
        assertFalse(AbsCrossProviderHistory.mayUpload(backfill, backfill.updatedAtMs))
        assertTrue(AbsCrossProviderHistory.mayUpload(backfill, backfill.updatedAtMs + 1))
        assertTrue(AbsCrossProviderHistory.mayUpload(convert(), null))
    }

    @Test
    fun failedCrossItemLookupDoesNotBlockNativeOrOtherItems() {
        val native = convert().copy(id = "native", accountId = null, sourceBookKey = null, historicalBackfill = false)
        val failed = convert().copy(id = "failed", libraryItemId = "unavailable")
        val eligible = convert().copy(id = "eligible", libraryItemId = "available")
        val pending = listOf(native, failed, eligible)
        val progress = mapOf(
            "unavailable" to Result.failure<AbsMediaProgressDto?>(IllegalStateException("HTTP 500")),
            "available" to Result.success<AbsMediaProgressDto?>(null),
        )

        val ready = AbsCrossProviderHistory.readyForUpload(pending, progress)
        assertEquals(listOf("native", "eligible"), ready.map { it.id })
        val afterUpload = AbsLocalListeningLedger.markUploaded(pending, ready, emptySet())
        assertTrue(afterUpload.single { it.id == "failed" }.needsUpload)
        assertFalse(afterUpload.single { it.id == "native" }.needsUpload)
    }

    @Test
    fun failedBackfillLookupRemainsPendingEvenWhenNativeIsReady() {
        val native = convert().copy(id = "native", accountId = null, sourceBookKey = null)
        val backfill = convert().copy(id = "backfill", historicalBackfill = true)
        val pending = listOf(native, backfill)

        assertEquals(listOf("native"), AbsCrossProviderHistory.readyForUpload(
            pending, mapOf("item" to Result.failure<AbsMediaProgressDto?>(IllegalStateException("HTTP 500"))),
        ).map { it.id })
    }

    @Test
    fun delayedNativeHistoryCannotRestoreItsRecordedPosition() {
        val native = convert().copy(accountId = null, sourceBookKey = null, currentTimeSec = 120.0)
        assertEquals(240.0, AbsCrossProviderHistory.uploadPosition(native, 240.0, null), 0.001)
        assertEquals(0.0, AbsCrossProviderHistory.uploadPosition(native, 240.0, 0.0), 0.001)
        assertEquals(0.0, AbsCrossProviderHistory.uploadPosition(native, null, null), 0.001)
    }

    @Test
    fun crossProviderHistoryAndPodcastUseTheirOwnCurrentRemoteProgress() {
        assertEquals(80.0, AbsCrossProviderHistory.uploadPosition(convert(), 80.0, 900.0), 0.001)
        val episode = convert().copy(accountId = null, episodeId = "episode")
        assertEquals(40.0, AbsCrossProviderHistory.uploadPosition(episode, 40.0, 900.0), 0.001)
        assertEquals(0.0, AbsCrossProviderHistory.uploadPosition(episode, 0.0, 900.0), 0.001)
    }

    @Test
    fun capsAtWallClockAndRejectsShortOrSameConnection() {
        val longer = source.copy(activeDurationSeconds = 90L)
        val capped = AbsCrossProviderHistory.session(longer, "abs", "account", "item", "Title", null, 3_600L, 500.0)
        assertEquals(60.0, capped!!.timeListeningSec, 0.001)
        assertNull(AbsCrossProviderHistory.session(source, "grimmory", "account", "item", "Title", null, 3_600L, 500.0))
        assertNull(AbsCrossProviderHistory.session(source.copy(activeDurationSeconds = 3), "abs", "account", "item", "Title", null, 3_600L, 500.0))
    }
}
