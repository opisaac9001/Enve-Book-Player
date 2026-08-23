package com.enve.hearth.journal

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.HistorySession
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

data class JournalAchievement(
    val key: String,
    val name: String,
    val description: String,
    val progress: Long,
    val threshold: Long,
) {
    val earned: Boolean
        get() = progress >= threshold

    val fraction: Float
        get() = (progress.toFloat() / threshold.coerceAtLeast(1L).toFloat()).coerceIn(0f, 1f)
}

data class JournalAchievements(
    val earned: Int,
    val available: Int,
    val achievements: List<JournalAchievement>,
) {
    val nextUp: List<JournalAchievement>
        get() = achievements.filterNot(JournalAchievement::earned).sortedByDescending(JournalAchievement::fraction)

    val topEarned: List<JournalAchievement>
        get() = achievements.filter(JournalAchievement::earned).sortedByDescending(JournalAchievement::threshold)
}

internal object JournalAchievementPolicy {

    fun achievements(
        books: List<Book>,
        sessions: List<HistorySession>,
        zone: ZoneId = ZoneId.systemDefault(),
    ): JournalAchievements {
        val distinctSessions = sessions.distinctBy(HistorySession::id).filter { it.activeDurationSeconds > 0L }
        val distinctBooks = books.distinctBy(Book::uniqueKey)
        val finished = distinctBooks.filter(Book::isFinished)

        val entries = STREAK_TIERS.map { tier ->
            tier.toAchievement("streak", longestStreak(distinctSessions, zone).toLong())
        } + HOUR_TIERS.map { tier ->
            tier.toAchievement("hours", distinctSessions.sumOf(HistorySession::activeDurationSeconds) / 3600L)
        } + SESSION_TIERS.map { tier ->
            tier.toAchievement("sessions", distinctSessions.size.toLong())
        } + FINISHED_TIERS.map { tier ->
            tier.toAchievement("finished", finished.size.toLong())
        } + EBOOK_TIERS.map { tier ->
            tier.toAchievement("ebooks", finished.count { it.mediaType == AppMediaType.EBOOK }.toLong())
        } + AUDIOBOOK_TIERS.map { tier ->
            tier.toAchievement("audiobooks", finished.count { it.mediaType == AppMediaType.AUDIOBOOK }.toLong())
        }

        return JournalAchievements(
            earned = entries.count(JournalAchievement::earned),
            available = entries.size,
            achievements = entries,
        )
    }

    private fun longestStreak(sessions: List<HistorySession>, zone: ZoneId): Int {
        val days: Set<LocalDate> = sessions
            .map { Instant.ofEpochMilli(it.endTimeMs).atZone(zone).toLocalDate() }
            .toSet()
        if (days.isEmpty()) return 0
        var longest = 0
        for (day in days) {
            if (day.minusDays(1) in days) continue
            var cursor = day
            var run = 0
            while (cursor in days) {
                run += 1
                cursor = cursor.plusDays(1)
            }
            longest = maxOf(longest, run)
        }
        return longest
    }

    private fun Tier.toAchievement(metric: String, progress: Long) = JournalAchievement(
        key = "$metric-$threshold",
        name = name,
        description = description,
        progress = progress.coerceAtLeast(0L),
        threshold = threshold,
    )

    private data class Tier(
        val threshold: Long,
        val name: String,
        val description: String,
    )

    private val STREAK_TIERS = listOf(
        Tier(3, "Three nights running", "Read or listen three days in a row"),
        Tier(7, "A week by the fire", "Keep a seven-day streak"),
        Tier(30, "A month of embers", "Keep a thirty-day streak"),
        Tier(100, "A hundred nights", "Keep a hundred-day streak"),
    )

    private val HOUR_TIERS = listOf(
        Tier(10, "Ten hours in", "Spend ten hours with your library"),
        Tier(50, "Fifty hours deep", "Spend fifty hours with your library"),
        Tier(200, "Two hundred hours", "Spend two hundred hours with your library"),
    )

    private val SESSION_TIERS = listOf(
        Tier(25, "Twenty-five sittings", "Finish twenty-five reading or listening sessions"),
        Tier(100, "A hundred sittings", "Finish a hundred reading or listening sessions"),
        Tier(500, "Five hundred sittings", "Finish five hundred reading or listening sessions"),
    )

    private val FINISHED_TIERS = listOf(
        Tier(1, "First finish", "Finish your first book"),
        Tier(10, "Ten finished", "Finish ten books"),
        Tier(50, "Fifty finished", "Finish fifty books"),
        Tier(100, "A hundred finished", "Finish a hundred books"),
    )

    private val EBOOK_TIERS = listOf(
        Tier(5, "Five ebooks read", "Finish five ebooks"),
        Tier(25, "Twenty-five ebooks read", "Finish twenty-five ebooks"),
    )

    private val AUDIOBOOK_TIERS = listOf(
        Tier(5, "Five audiobooks heard", "Finish five audiobooks"),
        Tier(25, "Twenty-five audiobooks heard", "Finish twenty-five audiobooks"),
    )
}
