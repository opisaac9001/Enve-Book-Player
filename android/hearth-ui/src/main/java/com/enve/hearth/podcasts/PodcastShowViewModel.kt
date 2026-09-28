package com.enve.hearth.podcasts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastShow
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlaybackTransport
import com.enve.engine.podcasts.PodcastsFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

sealed interface PodcastShowLoad {
    data object Loading : PodcastShowLoad
    data object Failed : PodcastShowLoad
    data class Loaded(val show: PodcastShow) : PodcastShowLoad
}

data class PodcastShowUiState(
    val load: PodcastShowLoad = PodcastShowLoad.Loading,
    val episodes: List<Book> = emptyList(),
    val inProgress: List<Book> = emptyList(),
    val visibleEpisodes: List<Book> = emptyList(),
    val query: String = "",
    val newestFirst: Boolean = true,
) {
    val playedCount: Int get() = episodes.count { it.isFinished }
    val playingCount: Int get() = inProgress.size
    val unplayedCount: Int get() = episodes.size - playedCount - playingCount
    val totalHours: Long get() = episodes.sumOf { it.duration } / 3600L
}

private data class PlayedEpisodeProgress(val positionSec: Long, val progress: Float, val observedAtMs: Long)

@HiltViewModel
class PodcastShowViewModel @Inject constructor(
    private val podcasts: PodcastsFacade,
    private val playback: PlaybackFacade,
) : ViewModel() {
    private val load = MutableStateFlow<PodcastShowLoad>(PodcastShowLoad.Loading)
    private val query = MutableStateFlow("")
    private val newestFirst = MutableStateFlow(true)
    private val feeds = mutableMapOf<String, List<PodcastFeedEpisode>>()
    private val played = MutableStateFlow<Map<String, PlayedEpisodeProgress>>(emptyMap())
    private var loadedShow: Book? = null
    private var loadJob: Job? = null

    private val listing = combine(load, query, newestFirst) { load, query, newestFirst ->
        val episodes = (load as? PodcastShowLoad.Loaded)?.show?.episodes.orEmpty()
        PodcastShowUiState(
            load = load,
            episodes = episodes,
            visibleEpisodes = PodcastsFormat.sortedAndFiltered(episodes, query, newestFirst),
            query = query,
            newestFirst = newestFirst,
        )
    }

    val state: StateFlow<PodcastShowUiState> =
        combine(listing, playback.transport, played) { listing, transport, played ->
            val episodes = listing.episodes.map { it.withLiveProgress(transport, played) }
            listing.copy(
                episodes = episodes,
                inProgress = episodes.filter(PodcastsFormat::isInProgress).sortedByDescending { it.lastReadTime },
                visibleEpisodes = listing.visibleEpisodes.map { it.withLiveProgress(transport, played) },
            )
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), PodcastShowUiState())

    init {
        viewModelScope.launch {
            playback.transport.collect { transport ->
                val id = transport.bookId ?: return@collect
                val episodes = (load.value as? PodcastShowLoad.Loaded)?.show?.episodes ?: return@collect
                if (transport.durationMs <= 0L || episodes.none { it.id == id }) return@collect
                played.update {
                    it + (id to PlayedEpisodeProgress(transport.positionMs / 1000L, transport.progress, System.currentTimeMillis()))
                }
            }
        }
    }

    fun load(show: Book) {
        loadedShow = show
        fetch(show)
    }

    fun retry() {
        loadedShow?.let(::fetch)
    }

    fun refresh() {
        if (loadJob?.isActive == true) return
        loadedShow?.let(::fetch)
    }

    fun setQuery(value: String) {
        query.value = value
    }

    fun toggleOrder() {
        newestFirst.value = !newestFirst.value
    }

    private fun fetch(show: Book) {
        loadJob?.cancel()
        val current = load.value
        if (current !is PodcastShowLoad.Loaded || current.show.id != show.id) load.value = PodcastShowLoad.Loading
        loadJob = viewModelScope.launch {
            val stored = podcasts.show(show).getOrElse {
                load.value = PodcastShowLoad.Failed
                return@launch
            }
            val cachedFeed = feeds[show.uniqueKey]
            if (cachedFeed != null) {
                load.value = PodcastShowLoad.Loaded(podcasts.withFeedEpisodes(show, stored, cachedFeed))
                return@launch
            }
            load.value = PodcastShowLoad.Loaded(stored)
            if (stored.feedUrl == null) return@launch
            podcasts.feed(stored).onSuccess { feed ->
                feeds[show.uniqueKey] = feed
                load.value = PodcastShowLoad.Loaded(podcasts.withFeedEpisodes(show, stored, feed))
            }
        }
    }

    private fun Book.withLiveProgress(transport: PlaybackTransport, played: Map<String, PlayedEpisodeProgress>): Book {
        if (transport.bookId == id && transport.durationMs > 0L) {
            return copy(currentTime = transport.positionMs / 1000L, readProgress = transport.progress)
        }
        val last = played[id]?.takeIf { it.observedAtMs > lastReadTime } ?: return this
        return copy(currentTime = last.positionSec, readProgress = last.progress, lastReadTime = last.observedAtMs)
    }
}
