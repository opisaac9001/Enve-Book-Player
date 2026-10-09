package com.enve.audiobookshelf

import com.enve.audiobookshelf.listening.AbsListeningEntry
import com.enve.audiobookshelf.listening.AbsLocalListeningLedger
import com.enve.audiobookshelf.listening.AbsLocalListeningSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

class AbsLocalListeningLedgerTest {
    private val day = LocalDate.of(2026, 10, 2)
    private fun entry(listenedMs: Long, item: String = "item-1") = AbsListeningEntry(
        connectionId = "conn",
        libraryItemId = item,
        episodeId = null,
        displayTitle = "Title",
        displayAuthor = "Author",
        durationSec = 3_600.0,
        currentTimeSec = 120.0,
        listenedMs = listenedMs,
    )

    @Test
    fun sameItemSameDayAccumulatesIntoOneSession() {
        var sessions = AbsLocalListeningLedger.record(emptyList(), entry(42_000), nowMs = 1_000_000, today = day) { "a" }
        sessions = AbsLocalListeningLedger.record(sessions, entry(8_000), nowMs = 1_010_000, today = day) { "b" }

        assertEquals(1, sessions.size)
        assertEquals("a", sessions.single().id)
        assertEquals(50.0, sessions.single().timeListeningSec, 0.001)
        assertEquals("Friday", sessions.single().dayOfWeek)
        assertEquals("2026-10-02", sessions.single().day)
    }

    @Test
    fun nativeListeningDoesNotMutateCrossProviderReceipt() {
        val transferred = AbsLocalListeningSession(
            id = "receipt", connectionId = "conn", libraryItemId = "item-1",
            displayTitle = "Title", day = day.toString(), dayOfWeek = "Friday",
            durationSec = 3_600.0, timeListeningSec = 20.0, currentTimeSec = 120.0,
            startedAtMs = 1L, updatedAtMs = 2L, accountId = "account", sourceBookKey = "source:book",
        )
        val sessions = AbsLocalListeningLedger.record(listOf(transferred), entry(10_000), nowMs = 10_000, today = day) { "native" }

        assertEquals(2, sessions.size)
        assertEquals(20.0, sessions.first().timeListeningSec, 0.001)
        assertEquals("native", sessions.last().id)
    }

    @Test
    fun newDayStartsANewSession() {
        var sessions = AbsLocalListeningLedger.record(emptyList(), entry(10_000), nowMs = 1, today = day) { "a" }
        sessions = AbsLocalListeningLedger.record(sessions, entry(10_000), nowMs = 2, today = day.plusDays(1)) { "b" }

        assertEquals(listOf("a", "b"), sessions.map { it.id })
    }

    @Test
    fun uploadAcknowledgesOnlyTheVersionThatWasSent() {
        var sessions = AbsLocalListeningLedger.record(emptyList(), entry(10_000), nowMs = 1, today = day) { "a" }
        val sent = sessions
        sessions = AbsLocalListeningLedger.record(sessions, entry(5_000), nowMs = 2, today = day) { "unused" }

        sessions = AbsLocalListeningLedger.markUploaded(sessions, sent, rejectedIds = emptySet())
        assertTrue(sessions.single().needsUpload)

        sessions = AbsLocalListeningLedger.markUploaded(sessions, sessions, rejectedIds = emptySet())
        assertFalse(sessions.single().needsUpload)
    }

    @Test
    fun rejectedSessionsAreDropped() {
        val sessions = AbsLocalListeningLedger.record(emptyList(), entry(10_000), nowMs = 1, today = day) { "gone" }

        assertTrue(AbsLocalListeningLedger.markUploaded(sessions, emptyList(), rejectedIds = setOf("gone")).isEmpty())
    }

    @Test
    fun zeroListeningIsIgnored() {
        assertTrue(AbsLocalListeningLedger.record(emptyList(), entry(0), nowMs = 1, today = day).isEmpty())
    }
}
