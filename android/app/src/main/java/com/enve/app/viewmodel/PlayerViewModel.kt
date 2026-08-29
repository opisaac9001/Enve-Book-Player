package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.VolumeLevelingStore
import com.enve.core.data.local.toBook
import com.enve.core.data.model.*
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.KeepNextOfflineService
import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.app.data.remote.dto.AudiobookInfoDto
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.playback.AudioEffectsManager
import com.enve.app.playback.AudioPlaybackManager
import com.enve.app.playback.AutoMediaBrowserHelper
import com.enve.app.playback.EqPreset
import com.enve.app.playback.EqualizerState
import com.enve.app.playback.PlayerChapterService
import com.enve.app.playback.PlayerBookmarkService
import com.enve.app.playback.PlayerProgressService
import com.enve.app.playback.PlayerSessionService
import com.enve.app.playback.PlayerSleepTimerService
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.resolveAudiobookPositionSeconds
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import javax.inject.Inject

private const val LOCAL_PROGRESS_PERSIST_INTERVAL_MS = 5_000L

data class PlayerState(
    val currentBook: Book? = null,
    val isPlaying: Boolean = false,
    val currentTime: Long = 0L,
    val duration: Long = 0L,
    val chapters: List<Chapter> = emptyList(),
    val currentChapterIndex: Int = 0,
    val playbackSpeed: Float = 1.0f,
    val sleepTimerMinutes: Int? = null,
    val sleepTimerRemaining: Long = 0L,
    val sleepTimerFadeEnabled: Boolean = true,
    val isBuffering: Boolean = false,
    val streamUrl: String? = null,
    val audiobookInfo: AudiobookInfoDto? = null,
    val bookmarks: List<AudiobookBookmark> = emptyList(),
    val showChapterSheet: Boolean = false,
    val showBookmarkSheet: Boolean = false,
    val showSleepTimerSheet: Boolean = false,
    val skipForwardSeconds: Int = 30,
    val skipBackwardSeconds: Int = 30,
    val voiceBoostEnabled: Boolean = false,
    val keepScreenOn: Boolean = true,
    val continuousPlayback: Boolean = true,
    val autoPlayNextInSeries: Boolean = false,
    val volumeBoostEnabled: Boolean = false,
    val playbackCompleted: Boolean = false,
    val pendingProgressConflict: ProgressConflictPrompt? = null,
) {
    val progress: Float
        get() = if (duration > 0) currentTime.toFloat() / duration else 0f

    val currentChapter: Chapter?
        get() = chapters.getOrNull(currentChapterIndex)

    val chapterProgress: String
        get() {
            if (chapters.isEmpty()) return ""
            val chapter = currentChapter ?: return ""
            val remaining = (chapter.endTime - currentTime).coerceAtLeast(0)
            val minutes = remaining / 60
            return "Chapter ${currentChapterIndex + 1} of ${chapters.size} • ${minutes}m left"
        }
}

@HiltViewModel
class PlayerViewModel @Inject constructor(
    private val repository: GrimmoryRepository,
    private val aggregatorRepository: AggregatorRepository,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val keepNextOffline: KeepNextOfflineService,
    private val bookCacheDao: BookCacheDao,
    private val audioManager: AudioPlaybackManager,
    private val prefs: PreferencesManager,
    private val volumeLevelingStore: VolumeLevelingStore,
    private val audioEffects: AudioEffectsManager,
    private val chapterService: PlayerChapterService,
    private val embeddedChapterExtractor: com.enve.app.playback.EmbeddedChapterExtractor,
    private val bookmarkService: PlayerBookmarkService,
    private val progressService: PlayerProgressService,
    private val sessionService: PlayerSessionService,
    private val sleepTimerService: PlayerSleepTimerService,
    private val syncCoordinator: SyncCoordinator,
    private val annotationRepo: com.enve.app.data.repository.AnnotationRepository,
    private val chapterStore: com.enve.app.playback.PlaybackChapterStore,
    private val absRepository: com.enve.audiobookshelf.AudiobookshelfRepository,
) : ViewModel() {

    fun addAudiobookBookmark(note: String = "") {
        val s = _state.value
        val book = s.currentBook ?: return
        viewModelScope.launch {
            annotationRepo.create(
                bookId = book.id,
                kind = com.enve.core.data.model.AnnotationKind.BOOKMARK,
                media = com.enve.core.data.model.AnnotationMedia.AUDIOBOOK,
                style = com.enve.core.data.model.AnnotationStyle.NONE,
                audioPositionMs = s.currentTime,
                chapterId = s.currentChapter?.title,
                selectedText = s.currentChapter?.title.orEmpty(),
                note = note,
            )
        }
    }

    private val _state = MutableStateFlow(PlayerState())
    val state: StateFlow<PlayerState> = _state.asStateFlow()

    val eqState: StateFlow<EqualizerState> = audioEffects.state

    private var sleepTimerJob: Job? = null
    private var pausedSessionCloseJob: Job? = null
    private var hydratedPlaybackMediaId: String? = null
    private var pendingConflictResolver: CompletableDeferred<ProgressConflictChoice>? = null
    private var lastLocalProgressPersistAtMs: Long = 0L

    init {
        audioManager.connect()

        viewModelScope.launch {
            combine(
                _state.map { it.currentBook }.distinctUntilChangedBy { it?.uniqueKey },
                keepNextOffline.settings,
                offlineDownloadManager.downloadedBookIds,
            ) { currentBook, _, _ -> currentBook }
                .filterNotNull()
                .collectLatest(keepNextOffline::reconcile)
        }

        viewModelScope.launch {
            audioManager.state.collect { playback ->
                maybeHydrateCurrentBookFromPlayback(playback.mediaId)
                val previous = _state.value
                _state.update {
                    val timeSec = playback.currentPositionMs / 1000
                    val durSec = if (playback.durationMs > 0) playback.durationMs / 1000 else it.duration
                    it.copy(
                        isPlaying = playback.isPlaying,
                        isBuffering = playback.isBuffering,
                        currentTime = timeSec,
                        duration = durSec,
                        playbackSpeed = playback.playbackSpeed,
                    )
                }
                val updated = _state.value
                if (previous.isPlaying != updated.isPlaying || updated.isPlaying) {
                    if (!previous.isPlaying && updated.isPlaying) {
                        updated.currentBook?.let { book ->
                            sessionService.start(book, updated.currentTime, updated.duration)
                        }
                        pausedSessionCloseJob?.cancel()
                    }
                    sessionService.markPlaybackChanged(
                        isPlaying = updated.isPlaying,
                        positionSec = updated.currentTime,
                        durationSec = updated.duration,
                    )
                    if (updated.isPlaying) {
                        persistLocalProgress(updated)
                    }
                    if (previous.isPlaying && !updated.isPlaying && !playback.playbackCompleted) {
                        persistLocalProgress(updated, force = true)
                        syncProgressImmediate(updated)
                        schedulePausedSessionClose()
                    }
                }
                updateChapterIndex()

                if (playback.playbackCompleted) {
                    audioManager.clearCompletionFlag()
                    onPlaybackCompleted()
                }
            }
        }

        viewModelScope.launch {
            prefs.playbackSpeed.collect { speed ->
                if (audioManager.state.value.playbackSpeed != speed) {
                    audioManager.setPlaybackSpeed(speed)
                }
            }
        }

        viewModelScope.launch {
            combine(
                prefs.skipForwardSeconds,
                prefs.skipBackwardSeconds,
                prefs.voiceBoostEnabled,
                prefs.keepScreenOn,
                prefs.continuousPlayback,
            ) { skipFwd, skipBwd, voiceBoost, screenOn, continuous ->
                _state.update {
                    it.copy(
                        skipForwardSeconds = skipFwd,
                        skipBackwardSeconds = skipBwd,
                        voiceBoostEnabled = voiceBoost,
                        keepScreenOn = screenOn,
                        continuousPlayback = continuous,
                    )
                }
            }.collect()
        }

        viewModelScope.launch {
            prefs.volumeBoostEnabled.collect { enabled ->
                _state.update { it.copy(volumeBoostEnabled = enabled) }
            }
        }

        viewModelScope.launch {
            prefs.autoPlayNextInSeries.collect { enabled ->
                _state.update { it.copy(autoPlayNextInSeries = enabled) }
            }
        }

        viewModelScope.launch {
            prefs.sleepTimerFade.collect { fadeEnabled ->
                _state.update { it.copy(sleepTimerFadeEnabled = fadeEnabled) }
            }
        }

        viewModelScope.launch {
            combine(
                prefs.eqEnabled,
                prefs.eqPreset,
                prefs.eqBandLevels,
                prefs.volumeBoostEnabled,
                prefs.volumeBoostGainMb,
            ) { eqOn, preset, bandsStr, volBoostOn, volGain ->
                EqSnapshot(eqOn, preset, bandsStr, volBoostOn, volGain)
            }.combine(
                combine(
                    prefs.bassBoostEnabled,
                    prefs.bassBoostStrength,
                    volumeLevelingStore.strength,
                ) { bassOn, bassStr, leveling -> Triple(bassOn, bassStr, leveling) }
            ) { snap, (bassOn, bassStr, leveling) ->
                snap.copy(
                    bassBoostEnabled = bassOn,
                    bassBoostStrength = bassStr,
                    volumeLevelingStrength = leveling,
                )
            }.collect { snap ->
                val levels = snap.bandLevels
                    .split(",")
                    .mapNotNull { it.trim().toIntOrNull() }
                audioEffects.restoreState(
                    eqEnabled = snap.eqEnabled,
                    preset = EqPreset.fromString(snap.preset),
                    bandLevels = levels,
                    volumeBoostEnabled = snap.volumeBoostEnabled,
                    volumeBoostGainMb = snap.volumeBoostGainMb,
                    volumeLevelingStrength = snap.volumeLevelingStrength,
                    bassBoostEnabled = snap.bassBoostEnabled,
                    bassBoostStrength = snap.bassBoostStrength,
                )
            }
        }

        viewModelScope.launch {
            while (isActive) {
                delay(15_000)
                if (_state.value.isPlaying) syncProgress()
            }
        }
    }

    private fun onPlaybackCompleted() {
        syncProgress()
        viewModelScope.launch {
            closePlaybackSession(_state.value)
        }
        _state.update { it.copy(playbackCompleted = true) }
    }

    fun clearPlaybackCompleted() {
        _state.update { it.copy(playbackCompleted = false) }
    }

    fun loadBook(book: Book) {

        val scopeElement = book.connectionId?.let { com.enve.core.data.remote.ConnectionScope.asContextElement(it) }
        viewModelScope.launch(scopeElement ?: kotlin.coroutines.EmptyCoroutineContext) {
            val cachedBook = withContext(Dispatchers.IO) {
                bookCacheDao.getByCacheKey(book.uniqueKey)?.toBook()
            }
            val requestedBook = cachedBook ?: book
            val previous = _state.value
            if (previous.currentBook != null && previous.currentBook.uniqueKey != requestedBook.uniqueKey) {
                closePlaybackSession(previous)
            }
            val mediaId = mediaIdFor(requestedBook)
            hydratedPlaybackMediaId = mediaId

            offlineDownloadManager.ensureCoverCached(requestedBook)
            val offlineCover = offlineDownloadManager.localCoverUri(requestedBook.id)
                ?: offlineDownloadManager.getManifest(requestedBook.id)?.coverUrl
            val book = if (offlineCover != null) requestedBook.copy(coverUrl = offlineCover) else requestedBook

            _state.update {
                it.copy(
                    currentBook = book,
                    currentTime = book.currentTime,
                    duration = book.duration,
                    chapters = book.chapters,
                    bookmarks = emptyList(),
                    isBuffering = true,
                )
            }
            loadBookmarks(book)

            val resolvedStartTime = resolveStartTime(book)
            _state.update { it.copy(currentTime = resolvedStartTime) }

            val localTracks = offlineDownloadManager.localTracks(book.id)
            if (!localTracks.isNullOrEmpty()) {
                withContext(Dispatchers.IO) {
                    val updatedRows = bookCacheDao.updateDownloadedStatus(
                        bookId = book.id,
                        connectionId = book.connectionId,
                        downloaded = true,
                        nowMs = System.currentTimeMillis(),
                    )
                    if (updatedRows == 0) {
                        bookCacheDao.updateDownloadedStatusById(
                            bookId = book.id,
                            downloaded = true,
                            nowMs = System.currentTimeMillis(),
                        )
                    }
                }
                val localDurationSec = when {
                    book.duration > 0L -> book.duration
                    localTracks.sumOf { it.durationMs } > 0L -> localTracks.sumOf { it.durationMs } / 1000L
                    else -> 0L
                }
                val playbackBook = book.copy(duration = localDurationSec)
                if (localTracks.size > 1) {
                    audioManager.playMultiTrack(
                        tracks = localTracks.map {
                            AudioPlaybackManager.TrackInfo(
                                url = it.uri,
                                title = it.title,
                                durationMs = it.durationMs,
                            )
                        },
                        bookId = book.id,
                        title = book.title,
                        author = book.author,
                        coverUrl = book.coverUrl,
                        startPositionMs = resolvedStartTime * 1000,
                        mediaId = mediaId,
                    )
                    _state.update {
                        it.copy(
                            currentBook = playbackBook,
                            streamUrl = localTracks.first().uri,
                            duration = localDurationSec,
                            isBuffering = false,
                        )
                    }
                } else {
                    val localUrl = localTracks.first().uri
                    audioManager.play(
                        streamUrl = localUrl,
                        bookId = book.id,
                        title = book.title,
                        author = book.author,
                        coverUrl = book.coverUrl,
                        startPositionMs = resolvedStartTime * 1000,
                        mediaId = mediaId,
                    )
                    _state.update {
                        it.copy(
                            currentBook = playbackBook,
                            streamUrl = localUrl,
                            duration = localDurationSec,
                            isBuffering = false,
                        )
                    }
                }
                sessionService.start(playbackBook, resolvedStartTime, localDurationSec)
                return@launch
            }

            if (book.source != BookSource.GRIMMORY) {
                playProviderBook(book, resolvedStartTime)
                return@launch
            }

            try {
                val infoResult = repository.getAudiobookInfo(book.id)
                infoResult.onSuccess { info ->
                    val chapters = info.chapters?.mapIndexed { index, ch ->
                        Chapter(
                            index = ch.index.takeIf { it >= 0 } ?: index,
                            title = ch.title ?: "Chapter ${index + 1}",
                            startTime = ch.startTimeMs / 1000,
                            endTime = ch.endTimeMs / 1000,
                        )
                    } ?: emptyList()

                    val durationSec = (info.durationMs ?: 0) / 1000

                    _state.update {
                        it.copy(
                            chapters = chapters,
                            duration = durationSec,
                            audiobookInfo = info,
                        )
                    }

                    chapterStore.set(
                        cacheKey = book.uniqueKey,
                        bookId = book.id,
                        chapters = chapters,
                        title = book.title,
                        author = book.author,
                        coverUrl = book.coverUrl,
                    )

                    val tracks = info.tracks
                    if (tracks != null && tracks.size > 1) {
                        val trackInfos = tracks.mapIndexed { i, track ->
                            AudioPlaybackManager.TrackInfo(
                                url = repository.getTrackStreamUrl(book.id, track.index.takeIf { it >= 0 } ?: i),
                                title = track.title ?: track.fileName,
                                durationMs = track.durationMs ?: 0L,
                            )
                        }
                        audioManager.playMultiTrack(
                            tracks = trackInfos,
                            bookId = book.id,
                            title = book.title,
                            author = book.author,
                            coverUrl = book.coverUrl,
                            startPositionMs = resolvedStartTime * 1000,
                            mediaId = mediaId,
                        )
                    } else {
                        val streamUrl = repository.getStreamUrl(book.id)
                        _state.update { it.copy(streamUrl = streamUrl) }
                        audioManager.play(
                            streamUrl = streamUrl,
                            bookId = book.id,
                            title = book.title,
                            author = book.author,
                            coverUrl = book.coverUrl,
                            startPositionMs = resolvedStartTime * 1000,
                            mediaId = mediaId,
                        )
                    }
                    sessionService.start(book, resolvedStartTime, durationSec)
                }

                infoResult.onFailure {
                    val streamUrl = repository.getStreamUrl(book.id)
                    _state.update { it.copy(streamUrl = streamUrl, isBuffering = false) }
                    audioManager.play(
                        streamUrl = streamUrl,
                        bookId = book.id,
                        title = book.title,
                        author = book.author,
                        coverUrl = book.coverUrl,
                        startPositionMs = resolvedStartTime * 1000,
                        mediaId = mediaId,
                    )
                    sessionService.start(book, resolvedStartTime, book.duration)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(isBuffering = false) }
            }
        }
    }

    private suspend fun playProviderBook(book: Book, startPositionSec: Long) {
        val session = aggregatorRepository.startPlaybackSession(book).getOrNull()
        val mediaId = mediaIdFor(book)
        val tracks = (session?.audioTracks
            ?.takeIf { it.isNotEmpty() }
            ?: aggregatorRepository.getAudioTracks(book).getOrElse { book.audioTracks })
            .filter { !it.contentUrl.isNullOrBlank() }
            .sortedBy { it.index }

        if (tracks.isEmpty()) {
            _state.update { it.copy(isBuffering = false) }
            return
        }

        val durationSec = when {
            book.duration > 0 -> book.duration
            tracks.sumOf { it.durationMs } > 0L -> tracks.sumOf { it.durationMs } / 1000L
            else -> 0L
        }
        val effectiveStartPositionSec = if (startPositionSec > 0L) {
            startPositionSec
        } else {
            session?.serverCurrentTimeSec ?: 0L
        }
        val sessionChapters = session?.chapters?.takeIf { it.isNotEmpty() }.orEmpty()
        val initialChapters = sessionChapters.ifEmpty {
            book.chapters.ifEmpty { synthesizeChaptersFromTracks(tracks, durationSec) }
        }
        val playbackBook = book.copy(
            duration = durationSec,
            currentTime = effectiveStartPositionSec,
            readProgress = if (durationSec > 0L && effectiveStartPositionSec > 0L) {
                (effectiveStartPositionSec.toFloat() / durationSec.toFloat()).coerceIn(0f, 1f)
            } else {
                book.readProgress
            },
            chapters = initialChapters,
            audioTracks = tracks,
        )

        _state.update {
            it.copy(
                currentBook = playbackBook,
                chapters = initialChapters,
                duration = durationSec,
                streamUrl = tracks.first().contentUrl,
                isBuffering = false,
            )
        }

        if (initialChapters.isNotEmpty()) {
            chapterStore.set(
                cacheKey = book.uniqueKey,
                bookId = book.id,
                chapters = initialChapters,
                title = book.title,
                author = book.author,
                coverUrl = book.coverUrl,
            )
        }

        if (initialChapters.isEmpty() && tracks.isNotEmpty()) {
            viewModelScope.launch {
                val embedded = try {
                    embeddedChapterExtractor.fetchAvailableChapters(tracks, durationSec)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    emptyList()
                }
                if (embedded.isNotEmpty()) {
                    _state.update {
                        it.copy(
                            currentBook = it.currentBook?.copy(chapters = embedded),
                            chapters = embedded,
                        )
                    }
                    val currentBook = _state.value.currentBook
                    if (currentBook != null) {
                        chapterStore.set(
                            cacheKey = currentBook.uniqueKey,
                            bookId = currentBook.id,
                            chapters = embedded,
                            title = currentBook.title,
                            author = currentBook.author,
                            coverUrl = currentBook.coverUrl,
                        )
                    }
                }
            }
        }

        val castAuthToken = if (book.source == BookSource.AUDIOBOOKSHELF) absRepository.currentAccessToken() else null

        if (tracks.size > 1) {
            audioManager.playMultiTrack(
                tracks = tracks.map { track ->
                    AudioPlaybackManager.TrackInfo(
                        url = track.contentUrl.orEmpty(),
                        title = track.title ?: track.fileName,
                        durationMs = track.durationMs,
                    )
                },
                bookId = book.id,
                title = book.title,
                author = book.author,
                coverUrl = book.coverUrl,
                startPositionMs = effectiveStartPositionSec * 1000,
                mediaId = mediaId,
                authToken = castAuthToken,
            )
        } else {
            audioManager.play(
                streamUrl = tracks.first().contentUrl.orEmpty(),
                bookId = book.id,
                title = book.title,
                author = book.author,
                coverUrl = book.coverUrl,
                startPositionMs = effectiveStartPositionSec * 1000,
                mediaId = mediaId,
                authToken = castAuthToken,
            )
        }
        sessionService.start(
            book = playbackBook,
            positionSec = effectiveStartPositionSec,
            durationSec = durationSec,
            providerSessionId = session?.sessionId,
        )
    }

    fun togglePlayPause() {
        audioManager.togglePlayPause()
    }

    fun seekTo(seconds: Long) {
        audioManager.seekTo(seconds * 1000)
        _state.update { it.copy(currentTime = seconds.coerceIn(0, it.duration)) }
        updateChapterIndex()
        syncProgressImmediate(_state.value)
    }

    fun skipForward(seconds: Int? = null) {
        val actualSeconds = seconds ?: _state.value.skipForwardSeconds
        if (actualSeconds <= 0) return
        audioManager.skipForward(actualSeconds * 1000L)
    }

    fun skipBackward(seconds: Int? = null) {
        val actualSeconds = seconds ?: _state.value.skipBackwardSeconds
        if (actualSeconds <= 0) return
        audioManager.skipBackward(actualSeconds * 1000L)
    }

    fun nextChapter() {
        val chapters = _state.value.chapters
        val currentIndex = _state.value.currentChapterIndex
        val nextStart = chapterService.nextChapterStart(chapters, currentIndex) ?: return
        seekTo(nextStart)
    }

    fun previousChapter() {
        val chapters = _state.value.chapters
        val currentIndex = _state.value.currentChapterIndex
        val currentTime = _state.value.currentTime
        val previousStart = chapterService.previousChapterStart(chapters, currentIndex, currentTime) ?: return
        seekTo(previousStart)
    }

    fun setPlaybackSpeed(speed: Float) {
        audioManager.setPlaybackSpeed(speed)
        viewModelScope.launch { prefs.setPlaybackSpeed(speed) }
    }

    fun setSkipForwardSeconds(seconds: Int) {
        viewModelScope.launch { prefs.setSkipForwardSeconds(seconds) }
    }

    fun setSkipBackwardSeconds(seconds: Int) {
        viewModelScope.launch { prefs.setSkipBackwardSeconds(seconds) }
    }

    fun setVoiceBoostEnabled(enabled: Boolean) {
        viewModelScope.launch { prefs.setVoiceBoostEnabled(enabled) }
        if (enabled) {
            audioEffects.setEqualizerEnabled(true)
            audioEffects.setPreset(EqPreset.VOICE_BOOST)
        }
    }

    fun setKeepScreenOn(enabled: Boolean) {
        viewModelScope.launch { prefs.setKeepScreenOn(enabled) }
    }

    fun setContinuousPlayback(enabled: Boolean) {
        viewModelScope.launch { prefs.setContinuousPlayback(enabled) }
    }

    fun setAutoPlayNextInSeries(enabled: Boolean) {
        viewModelScope.launch { prefs.setAutoPlayNextInSeries(enabled) }
    }

    fun setVolumeBoostEnabled(enabled: Boolean) {
        viewModelScope.launch { prefs.setVolumeBoostEnabled(enabled) }
        audioEffects.setVolumeBoost(enabled)
    }

    fun setEqEnabled(enabled: Boolean) {
        audioEffects.setEqualizerEnabled(enabled)
        viewModelScope.launch { prefs.setEqEnabled(enabled) }
    }

    fun setEqPreset(preset: EqPreset) {
        audioEffects.setPreset(preset)
        viewModelScope.launch {
            prefs.setEqPreset(preset.name)
            prefs.setEqBandLevels(audioEffects.state.value.bandLevels.joinToString(","))
        }
    }

    fun setEqBandLevel(band: Int, level: Int) {
        audioEffects.setBandLevel(band, level)
        viewModelScope.launch {
            prefs.setEqBandLevels(audioEffects.state.value.bandLevels.joinToString(","))
        }
    }

    fun setVolumeBoostGain(gainMb: Int) {
        audioEffects.setVolumeBoostGain(gainMb)
        viewModelScope.launch { prefs.setVolumeBoostGainMb(gainMb) }
    }

    fun setVolumeLevelingStrength(strength: VolumeLevelingStrength) {
        audioEffects.setVolumeLevelingStrength(strength)
        viewModelScope.launch { volumeLevelingStore.setStrength(strength) }
    }

    fun setBassBoostEnabled(enabled: Boolean) {
        audioEffects.setBassBoost(enabled)
        viewModelScope.launch { prefs.setBassBoostEnabled(enabled) }
    }

    fun setBassBoostStrength(strength: Int) {
        audioEffects.setBassBoostStrength(strength)
        viewModelScope.launch { prefs.setBassBoostStrength(strength) }
    }

    fun resetAudioEffects() {
        audioEffects.resetAll()
        viewModelScope.launch {
            prefs.setEqEnabled(false)
            prefs.setEqPreset("FLAT")
            prefs.setEqBandLevels("")
            prefs.setVolumeBoostEnabled(false)
            prefs.setVolumeBoostGainMb(0)
            volumeLevelingStore.setStrength(VolumeLevelingStrength.OFF)
            prefs.setBassBoostEnabled(false)
            prefs.setBassBoostStrength(0)
        }
    }

    fun setSleepTimerFadeEnabled(enabled: Boolean) {
        viewModelScope.launch { prefs.setSleepTimerFade(enabled) }
    }

    fun setSleepTimer(minutes: Int?) {
        sleepTimerJob?.cancel()
        audioManager.setVolume(1f)

        if (minutes == null || minutes <= 0) {
            _state.update { it.copy(sleepTimerMinutes = null, sleepTimerRemaining = 0L) }
            return
        }

        _state.update { it.copy(sleepTimerMinutes = minutes, sleepTimerRemaining = minutes * 60L) }

        sleepTimerJob = sleepTimerService.start(
            scope = viewModelScope,
            minutes = minutes,
            isFadeEnabled = { _state.value.sleepTimerFadeEnabled },
            onTick = { remaining ->
                _state.update { it.copy(sleepTimerRemaining = remaining) }
            },
            onFade = { volume -> audioManager.setVolume(volume) },
            onFinished = {
                audioManager.setVolume(0f)
                delay(300)
                audioManager.togglePlayPause()
                audioManager.setVolume(1f)
                _state.update { it.copy(sleepTimerMinutes = null, sleepTimerRemaining = 0L) }
            },
        )
    }

    fun seekToChapter(chapter: Chapter) {
        seekTo(chapter.startTime)
        _state.update { it.copy(showChapterSheet = false) }
    }

    fun toggleChapterSheet() {
        _state.update { it.copy(showChapterSheet = !it.showChapterSheet) }
    }

    fun toggleBookmarkSheet() {
        _state.update { it.copy(showBookmarkSheet = !it.showBookmarkSheet) }
    }

    fun addBookmark(title: String? = null, note: String? = null) {
        viewModelScope.launch {
            val snapshot = _state.value
            val book = snapshot.currentBook ?: return@launch
            val bookmark = bookmarkService.addBookmark(
                book = book,
                position = snapshot.currentTime,
                title = title,
                note = note,
                chapterTitle = snapshot.currentChapter?.title,
            )
            _state.update { it.copy(bookmarks = upsertBookmark(it.bookmarks, bookmark)) }
        }
    }

    fun updateBookmark(bookmark: AudiobookBookmark, title: String, note: String?) {
        viewModelScope.launch {
            val book = _state.value.currentBook ?: return@launch
            val updated = bookmarkService.updateBookmark(book, bookmark, title, note)
            _state.update { it.copy(bookmarks = upsertBookmark(it.bookmarks, updated)) }
        }
    }

    fun deleteBookmark(bookmark: AudiobookBookmark) {
        viewModelScope.launch {
            val book = _state.value.currentBook ?: return@launch
            bookmarkService.deleteBookmark(book, bookmark)
            _state.update { it.copy(bookmarks = it.bookmarks.filterNot { item -> item.id == bookmark.id }) }
        }
    }

    fun seekToBookmark(bookmark: AudiobookBookmark) {
        seekTo(bookmark.position)
        _state.update { it.copy(showBookmarkSheet = false) }
    }

    fun toggleSleepTimerSheet() {
        _state.update { it.copy(showSleepTimerSheet = !it.showSleepTimerSheet) }
    }

    fun syncProgress() {
        val state = _state.value
        val book = state.currentBook ?: return
        persistLocalProgress(state, force = true)
        progressService.sync(
            book = book,
            currentTimeSec = state.currentTime,
            progressFraction = state.progress,
        )
    }

    private fun syncProgressImmediate(snapshot: PlayerState) {
        val book = snapshot.currentBook ?: return
        persistLocalProgress(snapshot, force = true)
        progressService.syncImmediate(
            book = book,
            currentTimeSec = snapshot.currentTime,
            progressFraction = snapshot.progress,
        )
    }

    private fun maybeHydrateCurrentBookFromPlayback(mediaId: String?) {
        val cacheKey = mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom) ?: return
        val currentBook = _state.value.currentBook
        if (currentBook?.uniqueKey == cacheKey || hydratedPlaybackMediaId == mediaId) return

        hydratedPlaybackMediaId = mediaId
        viewModelScope.launch {
            val cached = withContext(Dispatchers.IO) { bookCacheDao.getByCacheKey(cacheKey) }
                ?: run {
                    if (hydratedPlaybackMediaId == mediaId) hydratedPlaybackMediaId = null
                    return@launch
                }
            if (audioManager.state.value.mediaId != mediaId) return@launch

            val book = cached.toBook()
            val playback = audioManager.state.value
            val positionSec = playback.currentPositionMs / 1000L
            val durationSec = if (playback.durationMs > 0L) playback.durationMs / 1000L else book.duration

            _state.update {
                it.copy(
                    currentBook = book,
                    currentTime = if (positionSec > 0L) positionSec else book.currentTime,
                    duration = durationSec,
                    chapters = book.chapters,
                    bookmarks = emptyList(),
                    isBuffering = playback.isBuffering,
                    streamUrl = null,
                )
            }
            loadBookmarks(book)
            updateChapterIndex()
            if (_state.value.isPlaying) {
                sessionService.start(book, _state.value.currentTime, _state.value.duration)
                pausedSessionCloseJob?.cancel()
            }
        }
    }

    private fun persistLocalProgress(snapshot: PlayerState, force: Boolean = false) {
        val book = snapshot.currentBook ?: return
        if (snapshot.currentTime <= 0L || snapshot.duration <= 0L) return
        val nowMs = System.currentTimeMillis()
        if (!force && nowMs - lastLocalProgressPersistAtMs < LOCAL_PROGRESS_PERSIST_INTERVAL_MS) return
        lastLocalProgressPersistAtMs = nowMs
        viewModelScope.launch(Dispatchers.IO) {
            val updatedRows = bookCacheDao.updateUnifiedProgress(
                bookId = book.id,
                connectionId = book.connectionId,
                progress = snapshot.progress.coerceIn(0f, 1f),
                currentTimeSec = snapshot.currentTime,
                locatorJson = null,
                nowMs = System.currentTimeMillis(),
            )
            if (updatedRows == 0) {
                bookCacheDao.updateUnifiedProgressById(
                    bookId = book.id,
                    progress = snapshot.progress.coerceIn(0f, 1f),
                    currentTimeSec = snapshot.currentTime,
                    locatorJson = null,
                    nowMs = System.currentTimeMillis(),
                )
            }
        }
    }

    private fun mediaIdFor(book: Book): String =
        AutoMediaBrowserHelper.mediaIdForCacheKey(book.uniqueKey)

    private fun updateChapterIndex() {
        val currentTime = _state.value.currentTime
        val index = chapterService.resolveCurrentChapterIndex(_state.value.chapters, currentTime)
        _state.update { it.copy(currentChapterIndex = index) }
    }

    private suspend fun loadBookmarks(book: Book) {
        val bookmarks = bookmarkService.loadBookmarks(book)
        _state.update {
            if (it.currentBook?.uniqueKey == book.uniqueKey) it.copy(bookmarks = bookmarks) else it
        }
    }

    private suspend fun closePlaybackSession(snapshot: PlayerState) {
        val book = snapshot.currentBook ?: return
        progressService.syncImmediate(
            book = book,
            currentTimeSec = snapshot.currentTime,
            progressFraction = snapshot.progress,
        )
        sessionService.close(snapshot.currentTime, snapshot.duration)
    }

    private fun schedulePausedSessionClose() {
        pausedSessionCloseJob?.cancel()
        pausedSessionCloseJob = viewModelScope.launch {
            delay(30_000)
            val snapshot = _state.value
            if (!snapshot.isPlaying) {
                closePlaybackSession(snapshot)
            }
        }
    }

    private fun upsertBookmark(
        bookmarks: List<AudiobookBookmark>,
        bookmark: AudiobookBookmark,
    ): List<AudiobookBookmark> {
        val updated = bookmarks.toMutableList()
        val index = updated.indexOfFirst { it.id == bookmark.id }
        if (index >= 0) updated[index] = bookmark else updated += bookmark
        return updated.sortedBy { it.timestamp }
    }

    private suspend fun resolveStartTime(book: Book): Long {
        val localStartTime = localStartSeconds(book)
        val result = try {
            syncCoordinator.pullOnOpenResolved(
                book = book,
                localPercentage = book.progress,
                localUpdatedAt = book.lastReadTime.takeIf { it > 0L },
            )
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }

        return when (result) {
            null -> localStartTime
            is SyncCoordinator.OpenSyncResult.Apply -> {
                val snap = result.snapshot
                if (!result.useRemote || snap == null) {
                    localStartTime
                } else {
                    val remoteStartTime = startSecondsFrom(snap.positionMs, snap.percentage, book.duration)
                        ?: localStartTime
                    mirrorPulledProgress(book, snap, remoteStartTime)
                    remoteStartTime
                }
            }
            is SyncCoordinator.OpenSyncResult.Conflict -> {
                val prompt = ProgressConflictPrompt(
                    localPercentage = result.local.percentage,
                    localUpdatedAt = result.local.updatedAt,
                    remotePercentage = result.remote.percentage,
                    remoteUpdatedAt = result.remote.updatedAt,
                    remoteSource = book.source.displayName,
                )
                when (awaitProgressConflictChoice(prompt)) {
                    ProgressConflictChoice.LOCAL -> localStartTime
                    ProgressConflictChoice.REMOTE -> {
                        val remoteStartTime = startSecondsFrom(result.remote.positionMs, result.remote.percentage, book.duration)
                            ?: localStartTime
                        mirrorPulledProgress(book, result.remote, remoteStartTime)
                        remoteStartTime
                    }
                }
            }
        }
    }

    private suspend fun mirrorPulledProgress(
        book: Book,
        remote: SyncSnapshot,
        startTimeSec: Long,
    ) {
        mirrorPulledProgress(
            book = book,
            percentage = remote.percentage,
            locatorJson = remote.locatorJson,
            startTimeSec = startTimeSec,
        )
    }

    private suspend fun mirrorPulledProgress(
        book: Book,
        remote: SyncCoordinator.ProgressOption,
        startTimeSec: Long,
    ) {
        mirrorPulledProgress(
            book = book,
            percentage = remote.percentage,
            locatorJson = remote.locatorJson,
            startTimeSec = startTimeSec,
        )
    }

    private suspend fun mirrorPulledProgress(
        book: Book,
        percentage: Float,
        locatorJson: String?,
        startTimeSec: Long,
    ) {
        withContext(Dispatchers.IO) {
            val updatedRows = bookCacheDao.updateUnifiedProgress(
                bookId = book.id,
                connectionId = book.connectionId,
                progress = percentage.coerceIn(0f, 1f),
                currentTimeSec = startTimeSec,
                locatorJson = locatorJson,
                nowMs = System.currentTimeMillis(),
            )
            if (updatedRows == 0) {
                bookCacheDao.updateUnifiedProgressById(
                    bookId = book.id,
                    progress = percentage.coerceIn(0f, 1f),
                    currentTimeSec = startTimeSec,
                    locatorJson = locatorJson,
                    nowMs = System.currentTimeMillis(),
                )
            }
        }
    }

    private suspend fun awaitProgressConflictChoice(prompt: ProgressConflictPrompt): ProgressConflictChoice {
        val deferred = CompletableDeferred<ProgressConflictChoice>()
        pendingConflictResolver = deferred
        _state.update { it.copy(pendingProgressConflict = prompt) }
        return try {
            deferred.await()
        } finally {
            pendingConflictResolver = null
            _state.update { it.copy(pendingProgressConflict = null) }
        }
    }

    fun resolveProgressConflict(choice: ProgressConflictChoice) {
        pendingConflictResolver?.complete(choice)
    }

    private fun localStartSeconds(book: Book): Long {
        if (book.currentTime > 0L) return book.currentTime
        if (book.duration <= 0L) return 0L
        return (book.duration * book.progress).toLong().coerceIn(0L, book.duration)
    }

    private fun startSecondsFrom(positionMs: Long?, percentage: Float, durationSec: Long): Long? {
        positionMs?.let {
            return resolveAudiobookPositionSeconds(
                positionMs = it,
                percentage = percentage,
                durationSeconds = durationSec,
                duration = durationSec.toDouble(),
            )
        }
        if (durationSec <= 0L) return null
        return (durationSec * percentage.coerceIn(0f, 1f)).toLong().coerceIn(0L, durationSec)
    }

    override fun onCleared() {
        super.onCleared()
        syncProgress()
        viewModelScope.launch { closePlaybackSession(_state.value) }
        sleepTimerJob?.cancel()
        pausedSessionCloseJob?.cancel()
    }

    private data class EqSnapshot(
        val eqEnabled: Boolean,
        val preset: String,
        val bandLevels: String,
        val volumeBoostEnabled: Boolean,
        val volumeBoostGainMb: Int,
        val volumeLevelingStrength: VolumeLevelingStrength = VolumeLevelingStrength.OFF,
        val bassBoostEnabled: Boolean = false,
        val bassBoostStrength: Int = 0,
    )
}
