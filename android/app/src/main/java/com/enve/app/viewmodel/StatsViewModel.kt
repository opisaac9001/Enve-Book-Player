package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.local.PreferencesManager
import com.enve.app.data.repository.GrimmoryRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlin.math.floor
import kotlin.math.pow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class StatsState(
    val mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
    val totalHoursListened: Float = 0f,
    val totalSessions: Int = 0,
    val booksFinished: Int = 0,
    val uniqueAuthors: Int = 0,
    val currentStreak: Int = 0,
    val longestStreak: Int = 0,
    val weeklyActivityHours: Float = 0f,
    val weeklyGoalHours: Float = 0f,
    val level: Int = 1,
    val xp: Int = 0,
    val xpToNextLevel: Int = 100,
    val rankTitle: String = "Page Turner",
    val achievements: List<Achievement> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
)

data class Achievement(
    val id: String,
    val name: String,
    val description: String,
    val icon: String,
    val isUnlocked: Boolean,
    val progress: Float = 0f,
)

@HiltViewModel
class StatsViewModel @Inject constructor(
    private val repository: GrimmoryRepository,
    private val prefs: PreferencesManager,
) : ViewModel() {

    private var hasLoaded = false

    private val _state = MutableStateFlow(StatsState())
    val state: StateFlow<StatsState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            combine(prefs.isConnected, prefs.mediaType, prefs.weeklyGoalHours) { connected, mediaType, weeklyGoalHours ->
                Triple(connected, mediaType, weeklyGoalHours)
            }.collect { (connected, mediaType, weeklyGoalHours) ->
                val parsedType = runCatching { AppMediaType.valueOf(mediaType) }
                    .getOrDefault(AppMediaType.AUDIOBOOK)
                    .let { if (it == AppMediaType.PODCAST) AppMediaType.AUDIOBOOK else it }

                _state.update { it.copy(mediaType = parsedType, weeklyGoalHours = weeklyGoalHours) }

                if (connected && !hasLoaded) {
                    hasLoaded = true
                    loadStats()
                }
            }
        }
    }

    fun setMediaType(type: AppMediaType) {
        val safeType = if (type == AppMediaType.PODCAST) AppMediaType.AUDIOBOOK else type
        viewModelScope.launch {
            prefs.setMediaType(safeType.name)
            _state.update { it.copy(mediaType = safeType) }
            if (prefs.isConnected.first()) {
                loadStats()
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            repository.invalidateListCaches()
            loadStats()
        }
    }

    fun setWeeklyGoal(hours: Float) {
        viewModelScope.launch {
            prefs.setWeeklyGoalHours(hours)
            _state.update { it.copy(weeklyGoalHours = hours.coerceIn(0f, 168f)) }
        }
    }

    private suspend fun loadStats() {
        _state.update { it.copy(isLoading = true, error = null) }

        runCatching {
            val mediaType = _state.value.mediaType
            val fullLibrary = repository.getBooks(size = 500).getOrDefault(emptyList())
            val stats = repository.getUserStats().getOrNull()

            val scopedBooks = when (mediaType) {
                AppMediaType.AUDIOBOOK -> fullLibrary.filter { it.mediaType == AppMediaType.AUDIOBOOK }
                AppMediaType.EBOOK -> fullLibrary.filter { it.mediaType == AppMediaType.EBOOK }
                AppMediaType.PODCAST -> fullLibrary.filter { it.mediaType == AppMediaType.PODCAST }
            }

            val computedHours = computeHours(scopedBooks, mediaType)
            val totalHours = when (mediaType) {
                AppMediaType.AUDIOBOOK -> {
                    val serverHours = (stats?.totalListeningTimeMs ?: 0L) / 3_600_000.0
                    if (serverHours > 0.0) serverHours else computedHours
                }
                else -> computedHours
            }

            val booksFinished = when (mediaType) {
                AppMediaType.AUDIOBOOK -> stats?.booksFinished ?: scopedBooks.count { it.isFinished }
                else -> scopedBooks.count { it.isFinished }
            }

            val sessions = when (mediaType) {
                AppMediaType.AUDIOBOOK -> stats?.sessionsCount ?: scopedBooks.count { it.progress > 0f }
                else -> scopedBooks.count { it.progress > 0f }
            }

            val uniqueAuthors = scopedBooks.mapNotNull { it.author }.toSet().size
            val streak = stats?.currentStreak ?: 0
            val longestStreak = stats?.longestStreak ?: streak
            val weeklyActivityHours = stats?.weeklyActivityTimeMs
                ?.let { it / 3_600_000.0 }
                ?: totalHours

            val totalXP = (totalHours * 10).toInt() + (booksFinished * 35) + (uniqueAuthors * 6)
            val leveling = statsRunescapeLeveling(totalXP)

            _state.update {
                it.copy(
                    totalHoursListened = totalHours.toFloat(),
                    totalSessions = sessions,
                    booksFinished = booksFinished,
                    uniqueAuthors = uniqueAuthors,
                    currentStreak = streak,
                    longestStreak = longestStreak,
                    weeklyActivityHours = weeklyActivityHours.toFloat(),
                    level = leveling.level,
                    xp = leveling.xpIntoLevel,
                    xpToNextLevel = leveling.xpForNextLevel,
                    rankTitle = leveling.rankTitle,
                    achievements = buildAchievements(totalHours, booksFinished, sessions),
                    isLoading = false,
                    error = null,
                )
            }
        }.onFailure { error ->
            _state.update { it.copy(isLoading = false, error = error.message) }
        }
    }

    private fun computeHours(books: List<Book>, mediaType: AppMediaType): Double {
        return when (mediaType) {
            AppMediaType.AUDIOBOOK, AppMediaType.PODCAST ->
                books.sumOf { (it.currentTime.coerceAtLeast(0L) / 3600.0) }

            AppMediaType.EBOOK ->
                books.sumOf { book ->
                    val pages = book.pageCount
                    val estimatedBookHours = when {
                        book.duration > 0L -> book.duration / 3600.0
                        pages != null && pages > 0 -> pages / 45.0
                        else -> 0.0
                    }
                    estimatedBookHours * book.progress.coerceIn(0f, 1f)
                }
        }
    }

    private fun buildAchievements(totalHours: Double, booksFinished: Int, sessions: Int): List<Achievement> {
        val hour1 = (totalHours / 1.0).toFloat().coerceIn(0f, 1f)
        val hour10 = (totalHours / 10.0).toFloat().coerceIn(0f, 1f)
        val hour50 = (totalHours / 50.0).toFloat().coerceIn(0f, 1f)
        val finished5 = (booksFinished / 5f).coerceIn(0f, 1f)
        val finished10 = (booksFinished / 10f).coerceIn(0f, 1f)
        val session25 = (sessions / 25f).coerceIn(0f, 1f)

        return listOf(
            Achievement("first_hour", "First Hour", "Listen/read for 1 hour", "⏱️", hour1 >= 1f, hour1),
            Achievement("ten_hours", "Dedicated Listener", "Reach 10 total hours", "🎧", hour10 >= 1f, hour10),
            Achievement("fifty_hours", "Bookworm", "Reach 50 total hours", "📚", hour50 >= 1f, hour50),
            Achievement("five_finished", "Completionist", "Finish 5 books", "✅", finished5 >= 1f, finished5),
            Achievement("ten_finished", "Voracious Reader", "Finish 10 books", "🏆", finished10 >= 1f, finished10),
            Achievement("session_starter", "Session Starter", "Complete 25 sessions", "🔥", session25 >= 1f, session25),
        )
    }
}

private data class StatsLevelResult(
    val level: Int,
    val xpIntoLevel: Int,
    val xpForNextLevel: Int,
    val rankTitle: String,
)

private fun statsRunescapeLeveling(totalXP: Int): StatsLevelResult {
    val safeXP = maxOf(0, totalXP)
    var level = 1
    var points = 0.0
    var currentLevelXP = 0
    var nextLevelXP = 83

    while (level < 200) {
        points += floor(level.toDouble() + 300.0 * 2.0.pow(level.toDouble() / 7.0))
        nextLevelXP = floor(points / 4.0).toInt()
        if (safeXP < nextLevelXP) break
        currentLevelXP = nextLevelXP
        level += 1
    }

    val xpIntoLevel = maxOf(0, safeXP - currentLevelXP)
    val xpForNextLevel = maxOf(1, nextLevelXP - currentLevelXP)
    val rankTitle = when (level) {
        in 1..3 -> "Page Turner"
        in 4..8 -> "Night Reader"
        in 9..15 -> "Story Chaser"
        in 16..25 -> "Chapter Champion"
        in 26..40 -> "Library Hero"
        else -> "Audiobook Legend"
    }
    return StatsLevelResult(level, xpIntoLevel, xpForNextLevel, rankTitle)
}
