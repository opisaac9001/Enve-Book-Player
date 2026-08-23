package com.enve.app.hearth

import com.enve.app.data.servertools.GrimmoryNote
import com.enve.app.data.servertools.GrimmoryReadingStats
import com.enve.app.data.servertools.KavitaAnnotation
import com.enve.app.data.servertools.KavitaReadingStats
import com.enve.audiobookshelf.AbsBookmark
import com.enve.audiobookshelf.AbsListeningStats
import com.enve.engine.bookorbit.BookOrbitAchievement
import com.enve.engine.bookorbit.BookOrbitAchievementCategory
import com.enve.engine.bookorbit.BookOrbitAchievements
import com.enve.silo.SiloHistoryItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerToolsMappingTest {

    @Test
    fun durationFormatsHoursMinutesAndSeconds() {
        assertEquals("2h 5m", ServerToolsMapping.duration(7_500L))
        assertEquals("25m", ServerToolsMapping.duration(1_500L))
        assertEquals("42s", ServerToolsMapping.duration(42L))
        assertEquals("0s", ServerToolsMapping.duration(-10L))
    }

    @Test
    fun isoMillisAcceptsInstantAndOffsetForms() {
        assertEquals(1_754_992_800_000L, ServerToolsMapping.isoMillis("2025-08-12T10:00:00Z"))
        assertEquals(1_754_992_800_000L, ServerToolsMapping.isoMillis("2025-08-12T12:00:00+02:00"))
        assertNull(ServerToolsMapping.isoMillis(null))
        assertNull(ServerToolsMapping.isoMillis("not a date"))
    }

    @Test
    fun grimmoryStatsOmitEmptyGroups() {
        val groups = ServerToolsMapping.grimmoryStats(
            GrimmoryReadingStats(
                year = 2026,
                currentStreak = 4,
                longestStreak = 12,
                totalReadingDays = null,
                totalAudiobooks = null,
                completedAudiobooks = null,
                inProgressAudiobooks = null,
            ),
        )

        assertEquals(1, groups.size)
        assertEquals("Your Grimmory year", groups.single().title)
        assertEquals(listOf("Current streak", "Longest streak"), groups.single().stats.map { it.label })
    }

    @Test
    fun kavitaStatsReportHoursAndSkipZeroes() {
        val groups = ServerToolsMapping.kavitaStats(
            KavitaReadingStats(
                booksRead = 3,
                comicsRead = 0,
                pagesRead = 900L,
                wordsRead = 0L,
                authorsRead = 2,
                hoursSpentReading = 14L,
                averageHoursPerWeek = 2.25,
                lastActiveUtc = "2025-08-12T10:00:00Z",
            ),
        )

        val read = groups.single { it.title == "Read" }
        assertEquals(listOf("Books read", "Pages", "Authors"), read.stats.map { it.label })
        val pace = groups.single { it.title == "Pace" }
        assertEquals("14 h", pace.stats.single { it.label == "Time read" }.value)
        assertEquals("2.3 h", pace.stats.single { it.label == "Weekly average" }.value)
        assertEquals("2025-08-12", pace.stats.single { it.label == "Last active" }.value)
    }

    @Test
    fun absStatsFormatListeningTotals() {
        val groups = ServerToolsMapping.absStats(
            AbsListeningStats(
                totalSeconds = 7_500L,
                todaySeconds = 0L,
                activeDays = 4,
                bestDay = "2025-08-10",
                bestDaySeconds = 3_600L,
                busiestWeekday = "Sunday",
            ),
        )

        val stats = groups.single().stats
        assertEquals("2h 5m", stats.single { it.label == "Total listened" }.value)
        assertEquals("2025-08-10", stats.single { it.label == "Best day" }.detail)
        assertTrue(stats.none { it.label == "Today" })
    }

    @Test
    fun absBookmarksResolveTitlesAndKeys() {
        val bookmarks = ServerToolsMapping.absBookmarks(
            listOf(AbsBookmark("item-1", "Chapter three", 930L, 1_754_992_800_000L)),
            mapOf("item-1" to "The Long Walk"),
        )

        val bookmark = bookmarks.single()
        assertEquals("item-1:930", bookmark.id)
        assertEquals("The Long Walk", bookmark.bookTitle)
        assertEquals(930L, bookmark.positionSeconds)
    }

    @Test
    fun grimmoryNotesCarryBookContext() {
        val highlights = ServerToolsMapping.grimmoryHighlights(
            listOf(
                GrimmoryNote(
                    id = "7",
                    bookTitle = "Piranesi",
                    author = "Susanna Clarke",
                    chapterTitle = "Part 1",
                    text = "The Beauty of the House",
                    note = "opening line",
                    createdAt = "2025-08-12T10:00:00Z",
                ),
            ),
        )

        val highlight = highlights.single()
        assertEquals("Piranesi", highlight.bookTitle)
        assertEquals(1_754_992_800_000L, highlight.createdAtMs)
    }

    @Test
    fun kavitaAnnotationsFallBackToSeriesName() {
        val highlights = ServerToolsMapping.kavitaHighlights(
            listOf(
                KavitaAnnotation(
                    id = 4,
                    seriesName = null,
                    chapterTitle = "Volume 2",
                    text = "A line worth keeping",
                    note = null,
                    createdUtc = null,
                ),
            ),
        )

        val highlight = highlights.single()
        assertEquals("4", highlight.id)
        assertNull(highlight.bookTitle)
        assertNull(highlight.createdAtMs)
    }

    @Test
    fun siloHistoryKeepsOrderAndOmitsUnknownTimestamps() {
        val entries = ServerToolsMapping.siloHistory(
            listOf(
                SiloHistoryItem("c1", "First", "A Series", "ebook", 0L),
                SiloHistoryItem("c2", "Second", null, "audiobook", 3_600L),
            ),
        )

        assertEquals(listOf("First", "Second"), entries.map { it.title })
        assertEquals("A Series", entries[0].subtitle)
        assertEquals("audiobook", entries[1].subtitle)
        assertNull(entries[0].durationSeconds)
        assertNull(entries[0].occurredAtMs)
        assertEquals(3_600L, entries[1].durationSeconds)
    }

    @Test
    fun bookOrbitAchievementsFlattenCategories() {
        val summary = ServerToolsMapping.bookOrbitAchievements(
            BookOrbitAchievements(
                categories = listOf(
                    BookOrbitAchievementCategory(
                        key = "reading",
                        label = "Reading",
                        earnedCount = 1,
                        totalCount = 2,
                        achievements = listOf(
                            achievement("first", earned = true),
                            achievement("ten", earned = false),
                        ),
                    ),
                ),
                totalEarned = 1,
                totalAvailable = 2,
            ),
        )

        assertEquals(1, summary.earned)
        assertEquals(2, summary.available)
        assertEquals(listOf("first", "ten"), summary.achievements.map { it.key })
    }

    private fun achievement(key: String, earned: Boolean) = BookOrbitAchievement(
        key = key,
        name = key,
        description = "desc",
        rarity = "common",
        earned = earned,
        awardedAtMs = null,
        currentProgress = 1.0,
        threshold = 10.0,
    )
}
