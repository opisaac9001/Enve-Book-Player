package com.enve.hearth.journal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.engine.library.LibraryFacade
import com.enve.engine.servertools.ServerFeature
import com.enve.engine.servertools.ServerStatGroup
import com.enve.engine.servertools.ServerToolsFacade
import com.enve.engine.servertools.ServerToolsTarget
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import javax.inject.Inject

data class JournalStats(
    val finished: Int = 0,
    val reading: Int = 0,
    val downloaded: Int = 0,
    val total: Int = 0,
    val authors: Int = 0,
    val series: Int = 0,
    val audiobooks: Int = 0,
    val ebooks: Int = 0,
    val listeningMinutes: Int = 0,
    val readingMinutes: Int = 0,
    val streakNights: Int = 0,
)

@HiltViewModel
class HearthJournalViewModel @Inject constructor(
    library: LibraryFacade,
    private val serverTools: ServerToolsFacade,
) : ViewModel() {

    val books: StateFlow<List<Book>> =
        library.allBooks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val sessions: StateFlow<List<HistorySession>> =
        library.historySessions.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val statsTargets: StateFlow<List<ServerToolsTarget>> = serverTools.targets
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    private val _serverStats = MutableStateFlow<Map<BookSource, List<ServerStatGroup>>>(emptyMap())
    val serverStats = _serverStats.asStateFlow()

    private val _loadingServerStats = MutableStateFlow<Set<BookSource>>(emptySet())
    val loadingServerStats = _loadingServerStats.asStateFlow()

    fun loadServerStats(source: BookSource) {
        if (source in _serverStats.value || source in _loadingServerStats.value) return
        val target = statsTargets.value.firstOrNull {
            it.source == source && it.enabled && ServerFeature.STATS in it.features
        } ?: return
        viewModelScope.launch {
            _loadingServerStats.update { it + source }
            try {
                _serverStats.update { it + (source to serverTools.stats(target.connectionId)) }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                _serverStats.update { it + (source to emptyList()) }
            } finally {
                _loadingServerStats.update { it - source }
            }
        }
    }

    val stats: StateFlow<JournalStats> = combine(books, sessions) { books, history ->
        JournalActivityPolicy.stats(books, history)
    }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), JournalStats())

    val achievements: StateFlow<JournalAchievements> = combine(books, sessions) { books, history ->
        JournalAchievementPolicy.achievements(books, history)
    }
        .flowOn(Dispatchers.Default)
        .stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5000),
            JournalAchievements(earned = 0, available = 0, achievements = emptyList()),
        )

    val almostFinished: StateFlow<List<Book>> = books.map { CompletionCenterPolicy.almostFinished(it) }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val finished: StateFlow<List<Book>> = books.map { CompletionCenterPolicy.recentlyFinished(it) }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val mantel: StateFlow<List<Book>> = books.map { books ->
        books.sortedWith(
            compareByDescending<Book> { inProgress(it) }
                .thenByDescending { it.lastReadTime }
                .thenBy { it.title },
        ).take(6)
    }.flowOn(Dispatchers.Default).stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val heatmap: StateFlow<List<Float>> = sessions.map { JournalActivityPolicy.heatmap(it) }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), List(HEATMAP_DAYS) { 0f })

    private fun inProgress(b: Book): Boolean =
        !b.isFinished && (b.readProgress in 0.01f..0.99f || b.currentTime > 0L || (b.epubProgress ?: 0f) in 0.01f..0.99f)

    private companion object {
        const val HEATMAP_DAYS = 52 * 7
    }
}

internal object JournalActivityPolicy {
    private const val HEATMAP_DAYS = 52 * 7

    fun stats(
        books: List<Book>,
        sessions: List<HistorySession>,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): JournalStats {
        val weekStart = Instant.ofEpochMilli(nowMs)
            .atZone(zone)
            .toLocalDate()
            .with(TemporalAdjusters.previousOrSame(DayOfWeek.MONDAY))
            .atStartOfDay(zone)
            .toInstant()
            .toEpochMilli()
        val thisWeek = sessions.filter { it.endTimeMs in weekStart..nowMs }
        return JournalStats(
            finished = books.count { it.isFinished },
            reading = books.count(::inProgress),
            downloaded = books.count { it.isDownloaded },
            total = books.size,
            authors = books.mapNotNull { it.author?.trim()?.takeIf(String::isNotEmpty) }.distinct().size,
            series = books.mapNotNull { it.seriesName?.trim()?.takeIf(String::isNotEmpty) }.distinct().size,
            audiobooks = books.count { it.mediaType == AppMediaType.AUDIOBOOK },
            ebooks = books.count { it.mediaType == AppMediaType.EBOOK },
            listeningMinutes = (thisWeek
                .filter { it.mediaType == AppMediaType.AUDIOBOOK }
                .sumOf(HistorySession::activeDurationSeconds) / 60L).toInt(),
            readingMinutes = (thisWeek
                .filter { it.mediaType == AppMediaType.EBOOK }
                .sumOf(HistorySession::activeDurationSeconds) / 60L).toInt(),
            streakNights = streak(sessions, nowMs, zone),
        )
    }

    fun heatmap(
        sessions: List<HistorySession>,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): List<Float> {
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        val firstDay = today.minusDays((HEATMAP_DAYS - 1).toLong())
        val dailySeconds = sessions
            .asSequence()
            .filter { it.activeDurationSeconds > 0L }
            .map { it to Instant.ofEpochMilli(it.endTimeMs).atZone(zone).toLocalDate() }
            .filter { (_, day) -> !day.isBefore(firstDay) && !day.isAfter(today) }
            .groupBy(keySelector = { it.second }, valueTransform = { it.first })
            .mapValues { (_, entries) -> entries.sumOf(HistorySession::activeDurationSeconds) }
        val maximum = dailySeconds.values.maxOrNull()?.coerceAtLeast(1L) ?: 1L
        return List(HEATMAP_DAYS) { index ->
            val day = firstDay.plusDays(index.toLong())
            (dailySeconds[day] ?: 0L).toFloat() / maximum.toFloat()
        }
    }

    private fun streak(sessions: List<HistorySession>, nowMs: Long, zone: ZoneId): Int {
        val activeDays = sessions.asSequence()
            .filter { it.activeDurationSeconds > 0L }
            .map { Instant.ofEpochMilli(it.endTimeMs).atZone(zone).toLocalDate() }
            .toSet()
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        var cursor = when {
            today in activeDays -> today
            today.minusDays(1) in activeDays -> today.minusDays(1)
            else -> return 0
        }
        var count = 0
        while (cursor in activeDays) {
            count += 1
            cursor = cursor.minusDays(1)
        }
        return count
    }

    private fun inProgress(book: Book): Boolean =
        !book.isFinished &&
            (book.readProgress in 0.01f..0.99f || book.currentTime > 0L || (book.epubProgress ?: 0f) in 0.01f..0.99f)
}

internal object CompletionCenterPolicy {
    fun almostFinished(books: List<Book>, limit: Int = 60): List<Book> =
        books.asSequence()
            .filter { it.mediaType != AppMediaType.PODCAST && !it.isFinished }
            .filter { progress(it) in 0.75f..<0.99f }
            .distinctBy(Book::uniqueKey)
            .sortedWith(
                compareByDescending<Book>(::progress)
                    .thenByDescending { it.lastReadTime }
                    .thenBy { it.title },
            )
            .take(limit)
            .toList()

    fun recentlyFinished(books: List<Book>, limit: Int = 100): List<Book> =
        books.asSequence()
            .filter { it.mediaType != AppMediaType.PODCAST && it.isFinished }
            .distinctBy(Book::uniqueKey)
            .sortedWith(compareByDescending<Book> { it.lastReadTime }.thenBy { it.title })
            .take(limit)
            .toList()

    fun progress(book: Book): Float {
        val timedProgress =
            if (book.duration > 0L) book.currentTime.toFloat() / book.duration else 0f
        val progress = when (book.mediaType) {
            AppMediaType.EBOOK -> maxOf(book.epubProgress ?: 0f, book.readProgress)
            else -> maxOf(book.readProgress, timedProgress)
        }
        return progress.coerceIn(0f, 1f)
    }
}
