package com.enve.hearth.player

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AudiobookBookmark
import com.enve.core.data.model.Chapter
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.NowPlaying
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlaybackQueueItem
import com.enve.engine.playback.PlaybackTransport
import com.enve.engine.playback.PlayerSessionFacade
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.sleep.SleepDataAccess
import com.enve.engine.sleep.SleepDataFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HearthPlayerViewModel @Inject constructor(
    private val playback: PlaybackFacade,
    private val session: PlayerSessionFacade,
    private val prefs: PreferencesFacade,
    private val sleepData: SleepDataFacade,
    private val library: LibraryFacade,
) : ViewModel() {
    val transport: StateFlow<PlaybackTransport> = playback.transport
    val nowPlaying: StateFlow<NowPlaying?> = playback.nowPlaying
    val queue: StateFlow<List<PlaybackQueueItem>> = playback.queue
    val chapters: StateFlow<List<Chapter>> = session.chapters
    val currentChapterIndex: StateFlow<Int> = session.currentChapterIndex
    val bookmarks: StateFlow<List<AudiobookBookmark>> = session.bookmarks
    val sleepRemainingSec: StateFlow<Long?> = session.sleepRemainingSec
    private val mutableSleepTracker = MutableStateFlow(SleepTrackerUiState())
    private var sleepTrackerJob: Job? = null
    val sleepTracker: StateFlow<SleepTrackerUiState> = mutableSleepTracker.asStateFlow()
    val scrubChapter: StateFlow<Boolean> =
        prefs.scrubScopeChapter.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)
    val skipForwardSeconds: StateFlow<Int> =
        prefs.skipForwardSeconds.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 30)
    val skipBackwardSeconds: StateFlow<Int> =
        prefs.skipBackwardSeconds.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 30)

    fun togglePlay() = playback.togglePlayPause()
    fun seekTo(ms: Long) = playback.seekTo(ms)
    fun skipForward() = playback.skipForward()
    fun skipBackward() = playback.skipBackward()
    fun setSpeed(speed: Float) = playback.setSpeed(speed)
    fun playQueued(bookKey: String) = playback.playQueued(bookKey)
    fun removeQueued(bookKey: String) = playback.removeQueued(bookKey)
    fun moveQueuedUp(bookKey: String) = playback.moveQueued(bookKey, -1)
    fun moveQueuedDown(bookKey: String) = playback.moveQueued(bookKey, 1)
    fun clearQueue() = playback.clearQueue()

    fun seekToChapter(c: Chapter) = session.seekToChapter(c)
    fun nextChapter() = session.nextChapter()
    fun previousChapter() = session.previousChapter()

    fun addBookmark(note: String? = null) = session.addBookmark(note)
    fun deleteBookmark(b: AudiobookBookmark) = session.deleteBookmark(b)
    fun seekToBookmark(b: AudiobookBookmark) = session.seekToBookmark(b)

    fun startSleep(minutes: Int) = session.startSleepTimer(minutes)
    fun startChapterSleep(endPositionSec: Long) = session.startChapterSleepTimer(endPositionSec)
    fun cancelSleep() = session.cancelSleepTimer()

    fun refreshSleepTracker() {
        if (mutableSleepTracker.value.loading) return
        sleepTrackerJob = viewModelScope.launch {
            val current = mutableSleepTracker.value
            mutableSleepTracker.value = current.copy(
                loading = true,
                summary = if (current.isDemo) null else current.summary,
                isDemo = false,
            )
            val snapshot = sleepData.load()
            val summary = SleepInsightsPolicy.build(
                periods = snapshot.periods,
                sessions = library.historySessions.first(),
                books = library.allBooks.first(),
            )
            mutableSleepTracker.value = SleepTrackerUiState(
                access = snapshot.access,
                loading = false,
                summary = summary,
            )
        }
    }

    fun loadDemoSleepTracker() {
        sleepTrackerJob?.cancel()
        mutableSleepTracker.value = SleepTrackerUiState(
            access = SleepDataAccess.AVAILABLE,
            summary = SleepDemoData.build(),
            isDemo = true,
        )
    }

    fun setScrubChapter(chapter: Boolean) {
        viewModelScope.launch { prefs.setScrubScopeChapter(chapter) }
    }
}
