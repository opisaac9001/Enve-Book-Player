package com.enve.hearth.shell

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.model.Book
import com.enve.engine.eink.EinkFacade
import com.enve.engine.eink.EinkState
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.NowPlaying
import com.enve.engine.playback.PlaybackFacade
import com.enve.engine.playback.PlaybackTransport
import com.enve.engine.playback.PlayerSessionFacade
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.observeLastOpenedBook
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HearthShellViewModel @Inject constructor(
    private val playback: PlaybackFacade,
    private val prefs: PreferencesFacade,
    session: PlayerSessionFacade,
    private val eink: EinkFacade,
    library: LibraryFacade,
    lastOpenedBookStore: LastOpenedBookStore,
) : ViewModel() {

    val transport: StateFlow<PlaybackTransport> = playback.transport
    val nowPlaying: StateFlow<NowPlaying?> = playback.nowPlaying
    val lastOpenedBook: StateFlow<Book?> =
        library.observeLastOpenedBook(lastOpenedBookStore)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
    val einkState: StateFlow<EinkState> = eink.state

    private val _playbackNotice = MutableStateFlow<String?>(null)
    val playbackNotice: StateFlow<String?> = _playbackNotice

    init {
        viewModelScope.launch { playback.errors.collect { _playbackNotice.value = it } }
    }

    fun dismissPlaybackNotice() {
        _playbackNotice.value = null
    }

    fun requestEinkRefresh(view: android.view.View) = eink.requestFullRefresh(view)

    val currentChapter: StateFlow<String?> =
        combine(session.chapters, session.currentChapterIndex) { chapters, idx ->
            chapters.getOrNull(idx)?.title
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    val themeMode: StateFlow<HearthThemeMode> =
        prefs.themeMode.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), HearthThemeMode.SYSTEM)
    val oled: StateFlow<Boolean> =
        prefs.oledEnabled.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)
    val uiTextScale: StateFlow<Float> =
        prefs.uiTextScale.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 1f)
    val reduceMotion: StateFlow<Boolean> =
        prefs.reduceMotion.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)
    val accentHex: StateFlow<String> =
        prefs.accentHex.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), "#F5921A")
    val preferredStartTab: StateFlow<HearthStartTab?> =
        prefs.preferredStartTab.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)

    fun togglePlayPause() = playback.togglePlayPause()
    fun openAudio(book: Book) = playback.open(book)
    fun openAudioAt(book: Book, positionMs: Long) = playback.open(book, positionMs)
}
