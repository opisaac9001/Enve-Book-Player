package com.enve.app.hearth

import com.enve.bookorbit.BookOrbitAnnotationHubFilter
import com.enve.bookorbit.BookOrbitAnnotationHubRepository
import com.enve.bookorbit.BookOrbitDashboard
import com.enve.bookorbit.BookOrbitDiscoveryRepository
import com.enve.bookorbit.BookOrbitInsightsRepository
import com.enve.bookorbit.BookOrbitRelatedBook as BookOrbitRelatedBookDto
import com.enve.bookorbit.BookOrbitRepository
import com.enve.bookorbit.dto.BookOrbitAchievementCatalogueDto
import com.enve.bookorbit.dto.BookOrbitAnnotationHubItemDto
import com.enve.bookorbit.dto.BookOrbitAnnotationHubPageDto
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.engine.bookorbit.BookOrbitAchievement
import com.enve.engine.bookorbit.BookOrbitAchievementCategory
import com.enve.engine.bookorbit.BookOrbitAchievements
import com.enve.engine.bookorbit.BookOrbitChallenge
import com.enve.engine.bookorbit.BookOrbitCompletionLatency
import com.enve.engine.bookorbit.BookOrbitDailyHighlight
import com.enve.engine.bookorbit.BookOrbitDailyPoint
import com.enve.engine.bookorbit.BookOrbitDiversity
import com.enve.engine.bookorbit.BookOrbitExportFormat
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitFunnel
import com.enve.engine.bookorbit.BookOrbitFunnelStage
import com.enve.engine.bookorbit.BookOrbitGenreSlice
import com.enve.engine.bookorbit.BookOrbitGoal
import com.enve.engine.bookorbit.BookOrbitHighlight
import com.enve.engine.bookorbit.BookOrbitHighlightBookFacet
import com.enve.engine.bookorbit.BookOrbitHighlightExport
import com.enve.engine.bookorbit.BookOrbitHighlightPage
import com.enve.engine.bookorbit.BookOrbitHighlightQuery
import com.enve.engine.bookorbit.BookOrbitHourSlice
import com.enve.engine.bookorbit.BookOrbitInsights
import com.enve.engine.bookorbit.BookOrbitLibraryOverview
import com.enve.engine.bookorbit.BookOrbitMonthlyCount
import com.enve.engine.bookorbit.BookOrbitOriginCount
import com.enve.engine.bookorbit.BookOrbitReadingDna
import com.enve.engine.bookorbit.BookOrbitRelated
import com.enve.engine.bookorbit.BookOrbitRelatedBook
import com.enve.engine.bookorbit.BookOrbitRhythm
import com.enve.engine.bookorbit.BookOrbitScoreFacet
import com.enve.engine.bookorbit.BookOrbitSourceSlice
import com.enve.engine.bookorbit.BookOrbitStreak
import com.enve.engine.bookorbit.BookOrbitSummary
import com.enve.engine.bookorbit.BookOrbitWeekdaySlice
import com.enve.engine.bookorbit.BookOrbitYearProjection
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

private const val HIGHLIGHT_PAGE_SIZE = 40

@Singleton
class BookOrbitFacadeImpl @Inject constructor(
    private val connectionRegistry: ConnectionRegistry,
    private val bookCache: BookCacheDao,
    private val repository: BookOrbitRepository,
    private val insightsRepository: BookOrbitInsightsRepository,
    private val discoveryRepository: BookOrbitDiscoveryRepository,
    private val annotationHub: BookOrbitAnnotationHubRepository,
) : BookOrbitFacade {

    override val accounts: Flow<List<BookOrbitAccount>> = connectionRegistry.connections.map { connections ->
        connections
            .filter { it.enabled && it.source == BookSource.BOOKORBIT }
            .map { BookOrbitAccount(it.id, it.name.ifBlank { it.serverUrl }) }
    }

    override suspend fun insights(connectionId: String, days: Int): BookOrbitInsights? = scoped(connectionId) {
        insightsRepository.getDashboard(days).getOrThrow().takeIf { it.hasAnyData }?.toInsights(days)
    }

    override suspend fun achievements(connectionId: String): BookOrbitAchievements? = scoped(connectionId) {
        insightsRepository.getAchievements().getOrThrow()?.toAchievements()
    }

    override suspend fun related(book: Book): BookOrbitRelated? {
        if (book.source != BookSource.BOOKORBIT) return null
        val connectionId = book.connectionId ?: return null
        return scoped(connectionId) {
            val related = discoveryRepository.getRelatedBooks(book.id).getOrNull() ?: return@scoped null
            if (!related.supported) return@scoped null
            BookOrbitRelated(
                recommendations = related.recommendations.map { it.toUiBook() },
                seriesBooks = related.seriesBooks.map { it.toUiBook() },
                authorBooks = related.authorBooks.map { it.toUiBook() },
            )
        }
    }

    override suspend fun highlights(
        connectionId: String,
        query: BookOrbitHighlightQuery,
    ): BookOrbitHighlightPage? = scoped(connectionId) {
        annotationHub.list(query.toFilter()).getOrThrow()?.toPage()
    }

    override suspend fun highlightBooks(
        connectionId: String,
        trashed: Boolean,
        search: String,
    ): List<BookOrbitHighlightBookFacet> = scoped(connectionId) {
        annotationHub.books(trashed, search).getOrDefault(emptyList()).map { facet ->
            BookOrbitHighlightBookFacet(
                bookId = facet.bookId,
                title = facet.bookTitle?.takeIf { it.isNotBlank() } ?: "Untitled",
                author = facet.author?.takeIf { it.isNotBlank() },
                count = facet.count,
            )
        }
    }

    override suspend fun trashHighlights(connectionId: String, ids: List<Int>): Int = scoped(connectionId) {
        annotationHub.trash(ids).getOrDefault(0)
    }

    override suspend fun restoreHighlights(connectionId: String, ids: List<Int>): Int = scoped(connectionId) {
        annotationHub.restoreAll(ids).getOrDefault(0)
    }

    override suspend fun deleteHighlight(connectionId: String, id: Int): Boolean = scoped(connectionId) {
        annotationHub.purge(id).isSuccess
    }

    override suspend fun exportHighlights(
        connectionId: String,
        query: BookOrbitHighlightQuery,
        format: BookOrbitExportFormat,
    ): BookOrbitHighlightExport? = scoped(connectionId) {
        annotationHub.export(query.toFilter(), format.wire).getOrNull()?.let { export ->
            BookOrbitHighlightExport(export.filename, export.content, format)
        }
    }

    override suspend fun openBook(connectionId: String, bookId: Int): Book? {
        bookCache.getByIdAndConnection(bookId.toString(), connectionId)?.let { return it.toBook() }
        return scoped(connectionId) { repository.getBook(bookId.toString(), null).getOrNull() }
    }

    private suspend fun <T> scoped(connectionId: String, block: suspend () -> T): T =
        withContext(ConnectionScope.asContextElement(connectionId)) { block() }

    private fun BookOrbitRelatedBookDto.toUiBook(): BookOrbitRelatedBook = BookOrbitRelatedBook(
        bookId = id,
        title = title,
        authors = authors.joinToString(", ").takeIf { it.isNotBlank() },
        coverUrl = coverUrl,
        seriesLabel = seriesIndex?.let { index ->
            if (index % 1.0 == 0.0) "Book ${index.toInt()}" else "Book $index"
        },
    )

    private fun BookOrbitHighlightQuery.toFilter(): BookOrbitAnnotationHubFilter = BookOrbitAnnotationHubFilter(
        page = page,
        pageSize = HIGHLIGHT_PAGE_SIZE,
        trashed = trashed,
        search = search,
        bookId = bookId,
        colors = colors,
        origins = origins,
        notesOnly = notesOnly,
    )

    private fun BookOrbitAnnotationHubPageDto.toPage(): BookOrbitHighlightPage = BookOrbitHighlightPage(
        items = items.map { it.toHighlight() },
        total = total,
        page = page,
        hasMore = page * pageSize < total,
        books = stats.books,
        withNotes = stats.withNotes,
        origins = stats.originBreakdown.map { BookOrbitOriginCount(it.origin, it.count) },
    )

    private fun BookOrbitAnnotationHubItemDto.toHighlight(): BookOrbitHighlight = BookOrbitHighlight(
        id = id,
        bookId = bookId,
        bookTitle = bookTitle?.takeIf { it.isNotBlank() },
        author = author?.takeIf { it.isNotBlank() },
        text = text,
        note = note?.takeIf { it.isNotBlank() },
        colorHex = color.normalizedHighlightColor(),
        chapterTitle = chapterTitle?.takeIf { it.isNotBlank() },
        origin = origin,
        createdAtMs = parseDateMillis(createdAt),
        trashed = deletedAt != null,
    )

    private fun BookOrbitAchievementCatalogueDto.toAchievements(): BookOrbitAchievements = BookOrbitAchievements(
        categories = categories.map { category ->
            BookOrbitAchievementCategory(
                key = category.key,
                label = category.label,
                earnedCount = category.earnedCount,
                totalCount = category.totalCount,
                achievements = category.achievements
                    .filterNot { it.hidden && !it.earned }
                    .sortedWith(compareBy({ !it.earned }, { it.sortOrder }, { it.name }))
                    .map { item ->
                        BookOrbitAchievement(
                            key = item.key,
                            name = item.name,
                            description = item.description,
                            rarity = item.rarity,
                            earned = item.earned,
                            awardedAtMs = parseDateMillis(item.awardedAt),
                            currentProgress = item.currentProgress,
                            threshold = item.threshold,
                        )
                    },
            )
        }.filter { it.achievements.isNotEmpty() },
        totalEarned = totalEarned,
        totalAvailable = totalAvailable,
    )

    private fun BookOrbitDashboard.toInsights(days: Int): BookOrbitInsights = BookOrbitInsights(
        days = days,
        summary = summary?.let {
            BookOrbitSummary(
                trackedBooks = it.trackedBooks,
                startedBooks = it.startedBooks,
                inProgressBooks = it.inProgressBooks,
                completedBooks = it.completedBooks,
                meanProgressPercent = it.meanProgressPercent,
            )
        },
        streak = streak?.let {
            BookOrbitStreak(it.currentStreak, it.longestStreak, it.lastSevenDays)
        },
        goal = goal?.let { widget ->
            widget.goalBooks?.let { target -> BookOrbitGoal(target, widget.completedBooks, widget.year) }
        },
        library = libraryOverview?.let {
            BookOrbitLibraryOverview(
                totalBooks = it.totalBooks,
                totalAuthors = it.totalAuthors,
                totalSeries = it.totalSeries,
                totalStorageBytes = it.totalStorageBytes,
                booksAddedThisYear = it.booksAddedThisYear,
            )
        },
        projection = yearProjection?.let {
            BookOrbitYearProjection(
                projectedBooks = it.projectedBooks,
                projectedHours = it.projectedHours,
                booksCompletedYtd = it.booksCompletedYtd,
                daysRemaining = it.daysRemaining,
                trend = it.trend,
            )
        },
        rhythm = rhythm?.let {
            BookOrbitRhythm(
                consistencyPercent = it.consistencyPercent,
                averageSecondsPerDay = it.avgSecondsPerDay.roundToLong(),
                activeDays = it.activeDays,
                totalDays = it.totalDays,
            )
        },
        challenge = monthlyChallenge?.takeIf { it.title.isNotBlank() }?.let {
            BookOrbitChallenge(it.title, it.description, it.progress, it.target, it.completed)
        },
        diversity = diversity?.takeIf { it.booksAnalyzed > 0 }?.let {
            BookOrbitDiversity(
                score = it.score,
                label = it.label,
                facets = listOf(
                    BookOrbitScoreFacet("Genres", it.genreScore),
                    BookOrbitScoreFacet("Authors", it.authorScore),
                    BookOrbitScoreFacet("Eras", it.eraScore),
                    BookOrbitScoreFacet("Languages", it.languageScore),
                ),
                booksAnalyzed = it.booksAnalyzed,
            )
        },
        readingDna = readingDna?.takeIf { it.booksAnalyzed > 0 }?.let {
            BookOrbitReadingDna(
                archetype = it.archetype,
                facets = listOf(
                    BookOrbitScoreFacet(it.lengthLabel, it.lengthScore),
                    BookOrbitScoreFacet(it.varietyLabel, it.varietyScore),
                    BookOrbitScoreFacet(it.rhythmLabel, it.rhythmScore),
                    BookOrbitScoreFacet(it.timeLabel, it.timeScore),
                    BookOrbitScoreFacet(it.speedLabel, it.speedScore),
                ).filter { facet -> facet.label.isNotBlank() },
                booksAnalyzed = it.booksAnalyzed,
            )
        },
        highlightOfTheDay = highlightOfTheDay?.takeIf { it.text.isNotBlank() }?.let {
            BookOrbitDailyHighlight(
                bookId = it.bookId,
                bookTitle = it.bookTitle?.takeIf { title -> title.isNotBlank() },
                chapterTitle = it.chapterTitle?.takeIf { chapter -> chapter.isNotBlank() },
                text = it.text,
                note = it.note?.takeIf { note -> note.isNotBlank() },
            )
        },
        dailyReading = dailyReading.map { BookOrbitDailyPoint(it.day, it.readingSeconds, it.eventsCount) },
        heatmap = heatmap.map { BookOrbitDailyPoint(it.day, it.readingSeconds, it.eventsCount) },
        sources = sourceDistribution?.slices.orEmpty()
            .filter { it.readingSeconds > 0L }
            .map { BookOrbitSourceSlice(it.bucket, it.bucket.sourceLabel(), it.readingSeconds) }
            .sortedByDescending(BookOrbitSourceSlice::readingSeconds),
        peakHours = peakHours
            .filter { it.readingSeconds > 0L }
            .map { BookOrbitHourSlice(it.hour, it.readingSeconds) }
            .sortedBy(BookOrbitHourSlice::hour),
        favoriteDays = favoriteDays
            .filter { it.readingSeconds > 0L }
            .map { BookOrbitWeekdaySlice(it.dayOfWeek, weekdayLabel(it.dayOfWeek), it.readingSeconds) }
            .sortedBy(BookOrbitWeekdaySlice::dayOfWeek),
        genres = genreReadingTime
            .filter { it.readingSeconds > 0L }
            .map { BookOrbitGenreSlice(it.genre, it.readingSeconds) }
            .sortedByDescending(BookOrbitGenreSlice::readingSeconds)
            .take(8),
        completions = completionTimeline
            .filter { it.count > 0 }
            .map { BookOrbitMonthlyCount(it.year, it.month, it.count) },
        funnel = progressFunnel?.let { comparison ->
            comparison.current.takeIf { it.started > 0 }?.let { current ->
                BookOrbitFunnel(
                    stages = listOf(
                        BookOrbitFunnelStage("Started", current.started),
                        BookOrbitFunnelStage("25%", current.reached25),
                        BookOrbitFunnelStage("50%", current.reached50),
                        BookOrbitFunnelStage("75%", current.reached75),
                        BookOrbitFunnelStage("Finished", current.completed),
                    ),
                    previousCompleted = comparison.previous?.completed,
                )
            }
        },
        completionLatency = completionLatency?.takeIf { it.totalCompletions > 0 }?.let {
            BookOrbitCompletionLatency(it.totalCompletions, it.medianDays, it.percentile90Days)
        },
    )
}

private fun String.normalizedHighlightColor(): String {
    val trimmed = trim()
    if (trimmed.startsWith("#") && (trimmed.length == 7 || trimmed.length == 4)) return trimmed
    return NAMED_HIGHLIGHT_COLORS[trimmed.lowercase()] ?: DEFAULT_HIGHLIGHT_COLOR
}

private const val DEFAULT_HIGHLIGHT_COLOR = "#FACC15"

private val NAMED_HIGHLIGHT_COLORS = mapOf(
    "yellow" to "#FACC15",
    "green" to "#4ADE80",
    "blue" to "#38BDF8",
    "pink" to "#F472B6",
    "orange" to "#FB923C",
    "red" to "#F87171",
    "olive" to "#84CC16",
    "cyan" to "#22D3EE",
    "purple" to "#C084FC",
    "gray" to "#9CA3AF",
)

private fun String.sourceLabel(): String = when (lowercase()) {
    "bookorbit" -> "BookOrbit"
    "koreader" -> "KOReader"
    "kobo" -> "Kobo"
    else -> replaceFirstChar { it.titlecase(Locale.getDefault()) }
}

private fun weekdayLabel(dayOfWeek: Int): String {
    val day = DayOfWeek.of(if (dayOfWeek == 0) 7 else dayOfWeek.coerceIn(1, 7))
    return day.getDisplayName(TextStyle.SHORT, Locale.getDefault())
}

private fun parseDateMillis(raw: String?): Long? {
    if (raw.isNullOrBlank()) return null
    return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
        ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
        ?: runCatching {
            LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME).toInstant(ZoneOffset.UTC).toEpochMilli()
        }.getOrNull()
}
