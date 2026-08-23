package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class JournalAchievementPolicyTest {

    @Test
    fun duplicateSessionIdsCountOnce() {
        val sessions = listOf(
            session("a", "2026-07-27T10:00:00Z", 3_600L),
            session("a", "2026-07-27T10:00:00Z", 3_600L),
            session("b", "2026-07-28T10:00:00Z", 3_600L),
        )

        val hours = achievement(sessions, "hours-10")

        assertEquals(2L, hours.progress)
    }

    @Test
    fun streakUsesLongestConsecutiveRun() {
        val sessions = listOf(
            session("d1", "2026-07-01T10:00:00Z", 60L),
            session("d2", "2026-07-02T10:00:00Z", 60L),
            session("d3", "2026-07-03T10:00:00Z", 60L),
            session("gap", "2026-07-20T10:00:00Z", 60L),
        )

        assertEquals(3L, achievement(sessions, "streak-3").progress)
        assertTrue(achievement(sessions, "streak-3").earned)
        assertFalse(achievement(sessions, "streak-7").earned)
    }

    @Test
    fun zeroDurationSessionsAreIgnored() {
        val sessions = listOf(
            session("idle", "2026-07-01T10:00:00Z", 0L),
            session("real", "2026-07-02T10:00:00Z", 120L),
        )

        assertEquals(1L, achievement(sessions, "sessions-25").progress)
        assertEquals(1L, achievement(sessions, "streak-3").progress)
    }

    @Test
    fun finishedCountsSplitByMediaTypeAndDedupeByKey() {
        val books = listOf(
            book("1", finished = true, mediaType = AppMediaType.EBOOK),
            book("1", finished = true, mediaType = AppMediaType.EBOOK),
            book("2", finished = true, mediaType = AppMediaType.AUDIOBOOK),
            book("3", finished = false, mediaType = AppMediaType.EBOOK),
        )

        val result = JournalAchievementPolicy.achievements(books, emptyList(), ZoneOffset.UTC)

        assertEquals(2L, result.achievements.single { it.key == "finished-10" }.progress)
        assertEquals(1L, result.achievements.single { it.key == "ebooks-5" }.progress)
        assertEquals(1L, result.achievements.single { it.key == "audiobooks-5" }.progress)
        assertTrue(result.achievements.single { it.key == "finished-1" }.earned)
    }

    @Test
    fun emptyHistoryEarnsNothingButStillListsTiers() {
        val result = JournalAchievementPolicy.achievements(emptyList(), emptyList(), ZoneOffset.UTC)

        assertEquals(0, result.earned)
        assertTrue(result.available > 0)
        assertTrue(result.achievements.all { it.fraction == 0f })
    }

    private fun achievement(sessions: List<HistorySession>, key: String) =
        JournalAchievementPolicy.achievements(emptyList(), sessions, ZoneOffset.UTC)
            .achievements
            .single { it.key == key }

    private fun session(id: String, endedAt: String, durationSeconds: Long) = HistorySession(
        id = id,
        bookId = id,
        bookKey = "LOCAL:$id",
        source = BookSource.LOCAL,
        mediaType = AppMediaType.EBOOK,
        startTimeMs = Instant.parse(endedAt).toEpochMilli() - durationSeconds * 1_000L,
        endTimeMs = Instant.parse(endedAt).toEpochMilli(),
        activeDurationSeconds = durationSeconds,
    )

    private fun book(id: String, finished: Boolean, mediaType: AppMediaType) = Book(
        id = id,
        title = id,
        isFinished = finished,
        mediaType = mediaType,
    )
}
