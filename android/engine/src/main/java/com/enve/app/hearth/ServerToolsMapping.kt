package com.enve.app.hearth

import com.enve.app.data.servertools.GrimmoryNote
import com.enve.app.data.servertools.GrimmoryReadingStats
import com.enve.app.data.servertools.KavitaAnnotation
import com.enve.app.data.servertools.KavitaReadingStats
import com.enve.audiobookshelf.AbsBookmark
import com.enve.audiobookshelf.AbsListeningStats
import com.enve.engine.bookorbit.BookOrbitAchievements
import com.enve.engine.bookorbit.BookOrbitHighlightPage
import com.enve.engine.bookorbit.BookOrbitInsights
import com.enve.engine.servertools.ServerAchievement
import com.enve.engine.servertools.ServerAchievementSummary
import com.enve.engine.servertools.ServerBookmark
import com.enve.engine.servertools.ServerHighlight
import com.enve.engine.servertools.ServerHistoryEntry
import com.enve.engine.servertools.ServerStat
import com.enve.engine.servertools.ServerStatGroup
import com.enve.silo.SiloHistoryItem
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlin.math.roundToLong

internal object ServerToolsMapping {

    fun bookOrbitStats(insights: BookOrbitInsights): List<ServerStatGroup> = buildList {
        val reading = buildList {
            insights.summary?.let { summary ->
                add(ServerStat("Tracked", summary.trackedBooks.toString()))
                add(ServerStat("In progress", summary.inProgressBooks.toString()))
                add(ServerStat("Finished", summary.completedBooks.toString()))
            }
            val window = insights.totalWindowSeconds
            if (window > 0L) {
                add(ServerStat("Last ${insights.days} days", duration(window)))
            }
        }
        if (reading.isNotEmpty()) add(ServerStatGroup("Reading", reading))

        val rhythm = buildList {
            insights.streak?.let { streak ->
                add(ServerStat("Current streak", "${streak.currentStreak} d"))
                add(ServerStat("Longest streak", "${streak.longestStreak} d"))
            }
            insights.rhythm?.let { rhythm ->
                add(
                    ServerStat(
                        label = "Consistency",
                        value = "${rhythm.consistencyPercent.roundToLong()}%",
                        detail = "${rhythm.activeDays} of ${rhythm.totalDays} days",
                    ),
                )
            }
            insights.goal?.let { goal ->
                add(ServerStat("${goal.year} goal", "${goal.completedBooks} / ${goal.goalBooks}"))
            }
        }
        if (rhythm.isNotEmpty()) add(ServerStatGroup("Rhythm", rhythm))

        insights.library?.let { library ->
            add(
                ServerStatGroup(
                    title = "Library",
                    stats = listOf(
                        ServerStat("Books", library.totalBooks.toString()),
                        ServerStat("Authors", library.totalAuthors.toString()),
                        ServerStat("Series", library.totalSeries.toString()),
                        ServerStat("Added this year", library.booksAddedThisYear.toString()),
                    ),
                ),
            )
        }
    }

    fun bookOrbitAchievements(catalogue: BookOrbitAchievements): ServerAchievementSummary =
        ServerAchievementSummary(
            earned = catalogue.totalEarned,
            available = catalogue.totalAvailable,
            achievements = catalogue.categories.flatMap { category ->
                category.achievements.map { achievement ->
                    ServerAchievement(
                        key = achievement.key,
                        name = achievement.name,
                        description = achievement.description,
                        earned = achievement.earned,
                        awardedAtMs = achievement.awardedAtMs,
                        progress = achievement.currentProgress,
                        threshold = achievement.threshold,
                    )
                }
            },
        )

    fun bookOrbitHighlights(page: BookOrbitHighlightPage): List<ServerHighlight> = page.items.map { highlight ->
        ServerHighlight(
            id = highlight.id.toString(),
            bookTitle = highlight.bookTitle,
            author = highlight.author,
            chapterTitle = highlight.chapterTitle,
            text = highlight.text,
            note = highlight.note,
            createdAtMs = highlight.createdAtMs,
        )
    }

    fun grimmoryStats(stats: GrimmoryReadingStats): List<ServerStatGroup> = buildList {
        val readingSeconds = stats.bookTimeline.sumOf { it.totalDurationSeconds }
        val sessionCount = stats.bookTimeline.sumOf { it.totalSessions }
        val finishedThisYear = stats.completionTimeline.sumOf { it.finishedBooks }
        val reading = buildList {
            if (readingSeconds > 0L) add(ServerStat("Time with books", duration(readingSeconds)))
            if (sessionCount > 0) add(ServerStat("Sessions", sessionCount.toString()))
            if (finishedThisYear > 0) add(ServerStat("Finished in ${stats.year}", finishedThisYear.toString()))
            stats.currentStreak?.let { add(ServerStat("Current streak", it.toString())) }
            stats.longestStreak?.let { add(ServerStat("Longest streak", it.toString())) }
            stats.totalReadingDays?.let { add(ServerStat("Reading days", it.toString())) }
        }
        if (reading.isNotEmpty()) add(ServerStatGroup("Your Grimmory year", reading))

        val peakHour = stats.readingPeakHours.maxByOrNull { it.totalDurationSeconds }
        val favoriteDay = stats.readingFavoriteDays.maxByOrNull { it.totalDurationSeconds }
        val rhythm = listOfNotNull(
            peakHour?.let { ServerStat("Favorite hour", hour(it.hourOfDay), "${duration(it.totalDurationSeconds)} across ${it.sessionCount} sessions") },
            favoriteDay?.let { ServerStat("Favorite day", it.dayName, duration(it.totalDurationSeconds)) },
            stats.readingSessions.maxByOrNull { it.durationMinutes }
                ?.let { ServerStat("Longest session", duration((it.durationMinutes * 60).roundToLong())) },
        )
        if (rhythm.isNotEmpty()) add(ServerStatGroup("Your reading rhythm", rhythm))

        val genres = stats.readingGenres.sortedByDescending { it.totalDurationSeconds }.take(5)
        if (genres.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "What keeps you turning pages",
                    genres.map { ServerStat(cleanGenre(it.genre), duration(it.totalDurationSeconds), "${it.totalSessions} sessions") },
                ),
            )
        }

        val pageTurners = stats.pageTurners.sortedByDescending { it.gripScore }.take(5)
        if (pageTurners.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "The books that had you",
                    pageTurners.map { ServerStat(it.bookTitle, "${it.gripScore} grip", "${it.totalSessions} sessions") },
                ),
            )
        }

        val distributions = stats.distributions
        val momentum = buildList {
            stats.completionTimeline.maxByOrNull { it.finishedBooks }?.takeIf { it.finishedBooks > 0 }?.let {
                add(ServerStat("Best finishing month", month(it.month), "${it.finishedBooks} finished · ${it.completionRate.roundToLong()}% completion"))
            }
            val historicFinishes = stats.completionHeatmap.sumOf { it.count }
            if (historicFinishes > 0) {
                add(ServerStat("Finished in the record", historicFinishes.toString(), "Across ${stats.completionHeatmap.map { it.year }.distinct().size} years"))
            }
            val funnel = stats.listeningFunnel
            if (funnel != null && funnel.totalStarted > 0) {
                add(ServerStat("Audiobooks started", funnel.totalStarted.toString()))
                add(ServerStat("Reached halfway", funnel.reached50.toString()))
                add(ServerStat("Finished", funnel.completed.toString()))
            }
        }
        if (momentum.isNotEmpty()) add(ServerStatGroup("Momentum", momentum))

        if (distributions != null) {
            val shelves = distributions.statusDistribution.map { bucket ->
                ServerStat(friendly(bucket.status), bucket.count.toString())
            }
            if (shelves.isNotEmpty()) add(ServerStatGroup("Across the shelves", shelves))

            val progress = distributions.progressDistribution.map { bucket ->
                ServerStat(bucket.range, bucket.count.toString())
            }
            if (progress.isNotEmpty()) add(ServerStatGroup("Reading progress", progress))

            val ratings = distributions.ratingDistribution.filter { it.count > 0 }.sortedByDescending { it.rating }
            if (ratings.isNotEmpty()) {
                add(ServerStatGroup("Your ratings", ratings.map { ServerStat("${it.rating} stars", it.count.toString()) }))
            }
        }

        val journeys = stats.bookTimeline.sortedByDescending { it.totalDurationSeconds }.take(6)
        if (journeys.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "Reading lives",
                    journeys.map {
                        ServerStat(
                            label = it.title,
                            value = duration(it.totalDurationSeconds),
                            detail = "${it.totalSessions} sessions · ${dateSpan(it.firstSessionDate, it.lastSessionDate)} · ${progress(it.maxProgress)}%",
                        )
                    },
                ),
            )
        }

        val allSessions = stats.readingSessions + stats.listeningSessions
        val sessionShape = buildList {
            if (allSessions.isNotEmpty()) {
                val averageMinutes = allSessions.map { it.durationMinutes }.average()
                val longestMinutes = allSessions.maxOf { it.durationMinutes }
                add(ServerStat("Typical session", duration((averageMinutes * 60).roundToLong())))
                add(ServerStat("Longest session", duration((longestMinutes * 60).roundToLong())))
            }
            stats.readingSpeed.lastOrNull()?.let {
                add(ServerStat("Latest pace", "${round2(it.avgProgressPerMinute)}% / min", it.date))
            }
            if (stats.completionRace.isNotEmpty()) {
                add(ServerStat("Finishing stories", stats.completionRace.map { it.bookId }.distinct().size.toString(), "Mapped session by session"))
            }
        }
        if (sessionShape.isNotEmpty()) add(ServerStatGroup("The shape of a session", sessionShape))

        val listening = buildList {
            stats.totalAudiobooks?.let { add(ServerStat("Audiobooks", it.toString())) }
            stats.completedAudiobooks?.let { add(ServerStat("Finished", it.toString())) }
            stats.inProgressAudiobooks?.let { add(ServerStat("In progress", it.toString())) }
            val trendSeconds = stats.listeningTrend.sumOf { it.totalDurationSeconds }
            if (trendSeconds > 0L) add(ServerStat("Last 26 weeks", duration(trendSeconds)))
        }
        if (listening.isNotEmpty()) add(ServerStatGroup("The listening shelf", listening))

        val listeningRhythm = buildList {
            stats.listeningPeakHours.maxByOrNull { it.totalDurationSeconds }?.let {
                add(ServerStat("Favorite hour", hour(it.hourOfDay), "${duration(it.totalDurationSeconds)} across ${it.sessionCount} sessions"))
            }
            stats.listeningFavoriteDays.maxByOrNull { it.totalDurationSeconds }?.let {
                add(ServerStat("Favorite day", it.dayName, duration(it.totalDurationSeconds)))
            }
            val completed = stats.listeningPace.sumOf { it.booksCompleted }
            if (completed > 0) add(ServerStat("Finished in 12 months", completed.toString()))
        }
        if (listeningRhythm.isNotEmpty()) add(ServerStatGroup("Your listening rhythm", listeningRhythm))

        val listeningProgress = stats.listeningInProgress.sortedByDescending { it.progressPercent }.take(6)
        if (listeningProgress.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "Still in your ears",
                    listeningProgress.map {
                        ServerStat(it.title, "${it.progressPercent.roundToLong()}%", "${duration(it.listenedDurationSeconds)} listened")
                    },
                ),
            )
        }

        val authors = stats.listeningAuthors.sortedByDescending { it.totalDurationSeconds }.take(5)
        if (authors.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "Voices you return to",
                    authors.map { ServerStat(it.author, duration(it.totalDurationSeconds), bookCount(it.bookCount)) },
                ),
            )
        }

        val listeningGenres = stats.listeningGenres.sortedByDescending { it.totalDurationSeconds }.take(5)
        if (listeningGenres.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "Listening taste",
                    listeningGenres.map { ServerStat(cleanGenre(it.genre), duration(it.totalDurationSeconds), bookCount(it.bookCount)) },
                ),
            )
        }

        val longest = stats.longestAudiobooks.sortedByDescending { it.listenedDurationSeconds }.take(5)
        if (longest.isNotEmpty()) {
            add(
                ServerStatGroup(
                    "Longest listens",
                    longest.map { ServerStat(it.title, duration(it.listenedDurationSeconds), "${it.progressPercent.roundToLong()}% complete") },
                ),
            )
        }
    }

    fun grimmoryHighlights(notes: List<GrimmoryNote>): List<ServerHighlight> = notes.map { note ->
        ServerHighlight(
            id = note.id,
            bookTitle = note.bookTitle,
            author = note.author,
            chapterTitle = note.chapterTitle,
            text = note.text,
            note = note.note,
            createdAtMs = isoMillis(note.createdAt),
        )
    }

    fun kavitaStats(stats: KavitaReadingStats): List<ServerStatGroup> = buildList {
        val read = buildList {
            if (stats.booksRead > 0) add(ServerStat("Books read", stats.booksRead.toString()))
            if (stats.comicsRead > 0) add(ServerStat("Comics read", stats.comicsRead.toString()))
            if (stats.pagesRead > 0L) add(ServerStat("Pages", stats.pagesRead.toString()))
            if (stats.wordsRead > 0L) add(ServerStat("Words", stats.wordsRead.toString()))
            if (stats.authorsRead > 0) add(ServerStat("Authors", stats.authorsRead.toString()))
        }
        if (read.isNotEmpty()) add(ServerStatGroup("Read", read))

        val pace = buildList {
            if (stats.hoursSpentReading > 0L) {
                add(ServerStat("Time read", "${stats.hoursSpentReading} h", detail = "Estimated by Kavita"))
            }
            if (stats.averageHoursPerWeek > 0.0) {
                add(ServerStat("Weekly average", "${round1(stats.averageHoursPerWeek)} h"))
            }
            isoMillis(stats.lastActiveUtc)?.let { add(ServerStat("Last active", isoDay(it))) }
        }
        if (pace.isNotEmpty()) add(ServerStatGroup("Pace", pace))
    }

    fun kavitaHighlights(annotations: List<KavitaAnnotation>): List<ServerHighlight> = annotations.map { annotation ->
        ServerHighlight(
            id = annotation.id.toString(),
            bookTitle = annotation.seriesName,
            author = null,
            chapterTitle = annotation.chapterTitle,
            text = annotation.text,
            note = annotation.note,
            createdAtMs = isoMillis(annotation.createdUtc),
        )
    }

    fun absStats(stats: AbsListeningStats): List<ServerStatGroup> {
        val listening = buildList {
            if (stats.totalSeconds > 0L) add(ServerStat("Total listened", duration(stats.totalSeconds)))
            if (stats.todaySeconds > 0L) add(ServerStat("Today", duration(stats.todaySeconds)))
            if (stats.activeDays > 0) add(ServerStat("Active days", stats.activeDays.toString()))
            if (stats.bestDaySeconds > 0L) {
                add(ServerStat("Best day", duration(stats.bestDaySeconds), detail = stats.bestDay))
            }
            stats.busiestWeekday?.let { add(ServerStat("Busiest weekday", it)) }
        }
        return if (listening.isEmpty()) emptyList() else listOf(ServerStatGroup("Listening", listening))
    }

    fun absBookmarks(bookmarks: List<AbsBookmark>, titles: Map<String, String>): List<ServerBookmark> =
        bookmarks.map { bookmark ->
            ServerBookmark(
                id = "${bookmark.libraryItemId}:${bookmark.timeSeconds}",
                bookTitle = titles[bookmark.libraryItemId],
                label = bookmark.title,
                positionSeconds = bookmark.timeSeconds,
                createdAtMs = bookmark.createdAtMs,
            )
        }

    fun siloHistory(items: List<SiloHistoryItem>): List<ServerHistoryEntry> = items.map { item ->
        ServerHistoryEntry(
            id = item.contentId,
            title = item.title,
            subtitle = item.seriesTitle ?: item.type.takeIf { it.isNotBlank() },
            occurredAtMs = null,
            durationSeconds = item.runtimeSeconds.takeIf { it > 0L },
        )
    }

    fun duration(seconds: Long): String {
        val safe = seconds.coerceAtLeast(0L)
        val hours = safe / 3600
        val minutes = (safe % 3600) / 60
        return when {
            hours > 0L -> "${hours}h ${minutes}m"
            minutes > 0L -> "${minutes}m"
            else -> "${safe}s"
        }
    }

    fun isoMillis(raw: String?): Long? {
        if (raw.isNullOrBlank()) return null
        return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
            ?: runCatching {
                LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME).toInstant(ZoneOffset.UTC).toEpochMilli()
            }.getOrNull()
    }

    private fun isoDay(millis: Long): String =
        Instant.ofEpochMilli(millis).atOffset(ZoneOffset.UTC).toLocalDate().toString()

    private fun round1(value: Double): String = ((value * 10.0).roundToLong() / 10.0).toString()

    private fun round2(value: Double): String = ((value * 100.0).roundToLong() / 100.0).toString()

    private fun progress(value: Double): Long = (if (value <= 1.0) value * 100.0 else value).roundToLong()

    private fun dateSpan(first: String, last: String): String = if (first == last) first else "$first – $last"

    private fun month(value: Int): String = java.time.Month.of(value).name.lowercase().replaceFirstChar(Char::uppercase)

    private fun friendly(value: String): String = value.replace('_', ' ').lowercase().replaceFirstChar(Char::uppercase)

    private fun bookCount(value: Int): String = "$value ${if (value == 1) "book" else "books"}"

    private fun hour(hour: Int): String = when {
        hour == 0 -> "12 AM"
        hour < 12 -> "$hour AM"
        hour == 12 -> "12 PM"
        else -> "${hour - 12} PM"
    }

    private fun cleanGenre(genre: String): String = if (genre == "BLOB") "Audiobooks" else genre
}
