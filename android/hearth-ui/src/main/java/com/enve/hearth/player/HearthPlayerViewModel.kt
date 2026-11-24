package com.enve.hearth.player

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AudiobookBookmark
import com.enve.core.data.model.Chapter
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.AmbientAudioState
import com.enve.engine.playback.AudiobookClip
import com.enve.engine.playback.AudiobookClipException
import com.enve.engine.playback.ClipShare
import com.enve.engine.playback.ClipTranscriptionModel
import com.enve.engine.playback.NowPlaying
import com.enve.engine.playback.PlayerExtrasFacade
import com.enve.engine.playback.SleepAutomationSettings
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlaybackQueueItem
import com.enve.engine.playback.PlaybackTransport
import com.enve.engine.playback.PlayerReadAloudState
import com.enve.engine.playback.PlayerSessionFacade
import com.enve.engine.playback.ReadAloudLyricLine
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.sleep.SleepDataFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.IOException
import javax.inject.Inject

@HiltViewModel
class HearthPlayerViewModel @Inject constructor(
    private val playback: PlaybackFacade,
    private val session: PlayerSessionFacade,
    private val prefs: PreferencesFacade,
    private val sleepData: SleepDataFacade,
    private val library: LibraryFacade,
    private val extras: PlayerExtrasFacade,
) : ViewModel() {
    val transport: StateFlow<PlaybackTransport> = playback.transport
    val nowPlaying: StateFlow<NowPlaying?> = playback.nowPlaying
    val queue: StateFlow<List<PlaybackQueueItem>> = playback.queue
    val chapters: StateFlow<List<Chapter>> = session.chapters
    val currentChapterIndex: StateFlow<Int> = session.currentChapterIndex
    val bookmarks: StateFlow<List<AudiobookBookmark>> = session.bookmarks
    val sleepRemainingSec: StateFlow<Long?> = session.sleepRemainingSec
    val readAloud: StateFlow<PlayerReadAloudState> = session.readAloud
    private val mutableSleepTracker = MutableStateFlow(SleepTrackerUiState())
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
    fun seekToReadAloudLine(line: ReadAloudLyricLine) = session.seekToReadAloudLine(line)

    fun addBookmark(note: String? = null) = session.addBookmark(note)
    fun deleteBookmark(b: AudiobookBookmark) = session.deleteBookmark(b)
    fun seekToBookmark(b: AudiobookBookmark) = session.seekToBookmark(b)

    fun startSleep(minutes: Int) = session.startSleepTimer(minutes)
    fun startChapterSleep(endPositionSec: Long) = session.startChapterSleepTimer(endPositionSec)
    fun cancelSleep() = session.cancelSleepTimer()

    fun refreshSleepTracker() {
        if (mutableSleepTracker.value.loading) return
        viewModelScope.launch {
            mutableSleepTracker.value = mutableSleepTracker.value.copy(loading = true)
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

    fun setScrubChapter(chapter: Boolean) {
        viewModelScope.launch { prefs.setScrubScopeChapter(chapter) }
    }

    val clips: StateFlow<List<AudiobookClip>> = extras.clips
    val clipBookKey: StateFlow<String?> = extras.clipBookKey
    val transcriptionModel: StateFlow<ClipTranscriptionModel> = extras.transcriptionModel
    private val mutableClipBusyId = MutableStateFlow<String?>(null)
    val clipBusyId: StateFlow<String?> = mutableClipBusyId.asStateFlow()
    private val mutableClipMessage = MutableStateFlow<String?>(null)
    val clipMessage: StateFlow<String?> = mutableClipMessage.asStateFlow()
    private val mutableClipTranscript = MutableStateFlow<ClipTranscript?>(null)
    val clipTranscript: StateFlow<ClipTranscript?> = mutableClipTranscript.asStateFlow()
    private val mutableClipShares = MutableSharedFlow<ClipShare>(extraBufferCapacity = 1)
    val clipShares: SharedFlow<ClipShare> = mutableClipShares.asSharedFlow()

    fun saveClip(bookKey: String, bookmarkId: String?, anchorMs: Long, startMs: Long, endMs: Long, note: String?) =
        runClipAction(bookmarkId) { extras.saveClip(bookKey, bookmarkId, anchorMs, startMs, endMs, note) }

    fun deleteClip(clip: AudiobookClip) = runClipAction(clip.bookmarkId) { extras.deleteClip(clip.bookKey, clip.bookmarkId) }

    fun shareClip(clip: AudiobookClip) = runClipAction(clip.bookmarkId) {
        mutableClipShares.emit(extras.exportClip(clip.bookKey, clip.bookmarkId))
    }

    fun showTranscript(clip: AudiobookClip, title: String) = runClipAction(clip.bookmarkId) {
        mutableClipTranscript.value = ClipTranscript(title, extras.transcribeClip(clip.bookKey, clip.bookmarkId))
    }

    fun installModelAndTranscribe(clip: AudiobookClip, title: String) = runClipAction(clip.bookmarkId) {
        extras.installTranscriptionModel()
        mutableClipTranscript.value = ClipTranscript(title, extras.transcribeClip(clip.bookKey, clip.bookmarkId))
    }

    fun dismissClipMessage() {
        mutableClipMessage.value = null
    }

    fun dismissClipTranscript() {
        mutableClipTranscript.value = null
    }

    private fun runClipAction(bookmarkId: String?, action: suspend () -> Unit) {
        if (mutableClipBusyId.value != null) return
        mutableClipBusyId.value = bookmarkId ?: NEW_CLIP_ID
        viewModelScope.launch {
            try {
                action()
            } catch (error: AudiobookClipException) {
                mutableClipMessage.value = error.message
            } finally {
                mutableClipBusyId.value = null
            }
        }
    }

    val sleepAutomation: StateFlow<SleepAutomationSettings> = extras.sleepAutomation
    val shakeAvailable: Boolean get() = extras.shakeAvailable

    fun updateSleepAutomation(transform: (SleepAutomationSettings) -> SleepAutomationSettings) {
        viewModelScope.launch {
            try {
                extras.updateSleepAutomation(transform(extras.sleepAutomation.value))
            } catch (_: IOException) {
                mutableClipMessage.value = "Sleep settings couldn't be saved on this device."
            }
        }
    }

    val ambient: StateFlow<AmbientAudioState> = extras.ambient
    fun attachAmbientPreset(presetId: String) = extras.attachAmbientPreset(presetId)
    fun attachAmbientTrack(uri: String) {
        viewModelScope.launch { extras.attachAmbientTrack(uri) }
    }
    fun removeAmbient() = extras.removeAmbient()
    fun setAmbientVolume(volume: Float) = extras.setAmbientVolume(volume)
    fun clearAmbientError() = extras.clearAmbientError()

    private companion object {
        const val NEW_CLIP_ID = "new-clip"
    }
}

data class ClipTranscript(val title: String, val text: String)
