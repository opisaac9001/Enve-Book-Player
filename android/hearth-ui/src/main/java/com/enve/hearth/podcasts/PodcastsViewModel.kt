package com.enve.hearth.podcasts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.podcasts.PodcastDirectoryShow
import com.enve.engine.podcasts.PodcastHome
import com.enve.engine.podcasts.PodcastSubscription
import com.enve.engine.podcasts.PodcastsFacade
import com.enve.engine.library.LibraryFacade
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.HistorySession
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import javax.inject.Inject

data class PodcastsUiState(
    val home: PodcastHome? = null,
    val directory: List<PodcastDirectoryShow> = emptyList(),
    val subscriptions: List<PodcastSubscription> = emptyList(),
    val loadingHome: Boolean = true,
    val loadingDirectory: Boolean = false,
    val error: String? = null,
    val query: String = "",
    val genreId: Int? = null,
)

data class PodcastListeningStats(
    val totalSeconds: Long = 0,
    val sessions: Int = 0,
    val finished: Int = 0,
    val shows: Int = 0,
    val topShows: List<Pair<String, Long>> = emptyList(),
    val topEpisodes: List<Pair<Book, Long>> = emptyList(),
) {
    val level: Int get() = (totalSeconds / 300L + finished * 20 + shows * 8).toInt() / 150 + 1
    val rank: String get() = when (level) {
        in 1..3 -> "Rookie Listener"
        in 4..8 -> "Show Hopper"
        in 9..15 -> "Binge Explorer"
        in 16..25 -> "Podcast Pro"
        in 26..40 -> "Audio Addict"
        else -> "Podcast Legend"
    }
}

@HiltViewModel
class PodcastsViewModel @Inject constructor(
    private val podcasts: PodcastsFacade,
    private val library: LibraryFacade,
) : ViewModel() {
    private val mutableState = MutableStateFlow(PodcastsUiState())
    val state: StateFlow<PodcastsUiState> = mutableState
    private val mutableStats = MutableStateFlow(PodcastListeningStats())
    val stats: StateFlow<PodcastListeningStats> = mutableStats
    private var directoryJob: Job? = null

    init {
        viewModelScope.launch {
            combine(
                library.historySessions,
                library.allBooks,
                mutableState.map { it.home }.distinctUntilChanged(),
            ) { sessions, books, home ->
                calculateStats(sessions, books + home?.shows.orEmpty().flatMap { it.episodes })
            }.collect { mutableStats.value = it }
        }
        viewModelScope.launch {
            podcasts.subscriptions.collect { subscriptions ->
                mutableState.value = mutableState.value.copy(subscriptions = subscriptions)
                refreshHome()
            }
        }
        top()
    }

    private fun calculateStats(sessions: List<HistorySession>, books: List<Book>): PodcastListeningStats {
        val byKey = books.associateBy(Book::uniqueKey)
        val podcastSessions = sessions.filter { it.mediaType == AppMediaType.PODCAST }
        val byEpisode = podcastSessions.groupBy(HistorySession::bookKey)
        val episodes = byEpisode.mapNotNull { (key, entries) ->
            byKey[key]?.let { book -> book to entries.sumOf(HistorySession::activeDurationSeconds) }
        }
        val byShow = episodes.groupBy { (book, _) -> book.podcastName ?: book.author ?: "Unknown show" }
        return PodcastListeningStats(
            totalSeconds = podcastSessions.sumOf(HistorySession::activeDurationSeconds),
            sessions = podcastSessions.size,
            finished = episodes.count { (book, _) -> book.isFinished },
            shows = byShow.size,
            topShows = byShow.map { (name, values) -> name to values.sumOf { it.second } }.sortedByDescending { it.second },
            topEpisodes = episodes.sortedByDescending { it.second },
        )
    }

    fun refreshHome() {
        viewModelScope.launch {
            mutableState.value = mutableState.value.copy(loadingHome = true)
            try {
                val home = podcasts.home()
                mutableState.value = mutableState.value.copy(home = home, loadingHome = false, error = null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.value = mutableState.value.copy(loadingHome = false, error = e.message)
            }
        }
    }

    fun search(query: String) {
        mutableState.value = mutableState.value.copy(query = query)
        directoryJob?.cancel()
        if (query.isBlank()) {
            top()
            return
        }
        directoryJob = viewModelScope.launch {
            delay(300)
            mutableState.value = mutableState.value.copy(loadingDirectory = true)
            try {
                val results = podcasts.searchPodcasts(query)
                mutableState.value = mutableState.value.copy(directory = results, loadingDirectory = false, error = null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.value = mutableState.value.copy(loadingDirectory = false, error = e.message)
            }
        }
    }

    fun setGenre(id: Int?) {
        mutableState.value = mutableState.value.copy(genreId = id, query = "")
        top()
    }

    private fun top() {
        directoryJob?.cancel()
        directoryJob = viewModelScope.launch {
            mutableState.value = mutableState.value.copy(loadingDirectory = true)
            try {
                val results = podcasts.topPodcasts(mutableState.value.genreId)
                mutableState.value = mutableState.value.copy(directory = results, loadingDirectory = false, error = null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.value = mutableState.value.copy(loadingDirectory = false, error = e.message)
            }
        }
    }

    fun subscribe(show: PodcastDirectoryShow) {
        viewModelScope.launch {
            podcasts.subscribe(show)
        }
    }

    fun subscribeToFeed(url: String) {
        viewModelScope.launch {
            try {
                podcasts.subscribeToFeed(url)
                mutableState.value = mutableState.value.copy(error = null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableState.value = mutableState.value.copy(error = e.message)
            }
        }
    }

    fun unsubscribe(url: String) {
        viewModelScope.launch { podcasts.unsubscribe(url) }
    }
}
