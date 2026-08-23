package com.enve.app.playback

import android.content.ComponentName
import android.content.Context
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.google.common.util.concurrent.ListenableFuture
import com.google.common.util.concurrent.MoreExecutors
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

internal fun cumulativeTrackOffsets(durationsMs: List<Long>): List<Long> =
    buildList(durationsMs.size) {
        var running = 0L
        durationsMs.forEach { duration ->
            add(running)
            running += duration.coerceAtLeast(0L)
        }
    }

internal fun resolveAbsolutePlaybackPosition(
    localPositionMs: Long,
    currentIndex: Int,
    trackOffsetsMs: List<Long>,
): Long {
    val localPosition = localPositionMs.coerceAtLeast(0L)
    if (trackOffsetsMs.isEmpty()) return localPosition
    val index = currentIndex.coerceIn(trackOffsetsMs.indices)
    return (trackOffsetsMs[index] + localPosition).coerceAtLeast(0L)
}

internal fun hasReliableMultiTrackTimeline(
    itemCount: Int,
    trackDurationsMs: List<Long>,
): Boolean =
    itemCount > 1 &&
        trackDurationsMs.size == itemCount &&
        trackDurationsMs.all { it > 0L }

internal data class QueueSeekTarget(
    val mediaItemIndex: Int,
    val positionMs: Long,
)

internal fun resolveRelativeQueueSeek(
    durationsMs: List<Long>,
    currentIndex: Int,
    currentPositionMs: Long,
    deltaMs: Long,
): QueueSeekTarget {
    if (durationsMs.isEmpty()) {
        return QueueSeekTarget(0, (currentPositionMs + deltaMs).coerceAtLeast(0L))
    }

    var index = currentIndex.coerceIn(durationsMs.indices)
    var position = currentPositionMs.coerceAtLeast(0L) + deltaMs

    while (position < 0L && index > 0) {
        val previousDuration = durationsMs[index - 1]
        if (previousDuration <= 0L) {
            return QueueSeekTarget(index, 0L)
        }
        index -= 1
        position += previousDuration
    }

    while (index < durationsMs.lastIndex) {
        val duration = durationsMs[index]
        if (duration <= 0L || position <= duration) break
        position -= duration
        index += 1
    }

    val duration = durationsMs[index]
    return QueueSeekTarget(
        mediaItemIndex = index,
        positionMs = position.coerceAtLeast(0L).let { value ->
            if (duration > 0L) value.coerceAtMost(duration) else value
        },
    )
}

data class PlaybackState(
    val isPlaying: Boolean = false,
    val isBuffering: Boolean = false,
    val currentPositionMs: Long = 0L,
    val durationMs: Long = 0L,
    val currentMediaItemIndex: Int = -1,
    val mediaItemCount: Int = 0,
    val playbackSpeed: Float = 1.0f,
    val isReady: Boolean = false,
    val playbackCompleted: Boolean = false,
    val mediaId: String? = null,
    val errorMessage: String? = null,
)

@Singleton
@androidx.annotation.OptIn(UnstableApi::class)
class AudioPlaybackManager @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private var controllerFuture: ListenableFuture<MediaController>? = null
    private var controller: MediaController? = null

    private val _state = MutableStateFlow(PlaybackState())
    val state: StateFlow<PlaybackState> = _state.asStateFlow()

    private var positionJob: Job? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var activeTrackDurationsMs: List<Long> = emptyList()
    private var activeTrackOffsetsMs: List<Long> = emptyList()
    private var activeQueueKey: String? = null
    private var pendingPlayback: PendingPlayback? = null

    private val _currentBookId = MutableStateFlow<String?>(null)
    val currentBookIdFlow: StateFlow<String?> = _currentBookId.asStateFlow()
    var currentBookId: String?
        get() = _currentBookId.value
        private set(value) { _currentBookId.value = value }

    private fun resetTransientStateForNewBook(bookId: String) {
        if (_currentBookId.value != bookId) {
            _state.value = _state.value.copy(currentPositionMs = 0L, durationMs = 0L, playbackCompleted = false)
        }
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            runControllerCommand(block)
        } else {
            scope.launch { runControllerCommand(block) }
        }
    }

    private fun runControllerCommand(block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            Log.w("AudioPlaybackManager", "MediaController command failed", e)
            _state.value = _state.value.copy(errorMessage = e.message ?: e::class.java.simpleName)
        }
    }

    fun connect() {
        if (controller != null) return
        if (controllerFuture != null) return
        val sessionToken = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(context, sessionToken).buildAsync().also { future ->
            future.addListener({
                scope.launch(Dispatchers.Main) {
                    try {
                        controller = future.get()
                        setupPlayerListener()
                        pendingPlayback?.let { pending ->
                            pendingPlayback = null
                            playPending(pending)
                        }
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        controllerFuture = null
                        Log.w("AudioPlaybackManager", "MediaController connection failed", e)
                    }
                }
            }, MoreExecutors.directExecutor())
        }
    }

    fun play(
        streamUrl: String,
        bookId: String,
        title: String,
        author: String?,
        coverUrl: String?,
        startPositionMs: Long = 0L,
        mediaId: String = "",
        authToken: String? = null,
    ) {
        resetTransientStateForNewBook(bookId)
        currentBookId = bookId
        val pending = PendingPlayback.Single(
            streamUrl = streamUrl,
            bookId = bookId,
            title = title,
            author = author,
            startPositionMs = startPositionMs,
            mediaId = mediaId,
            authToken = authToken,
        )
        if (controller == null) {
            pendingPlayback = pending
            connect()
            return
        }
        runOnMain { playPending(pending) }
    }

    private fun playSingleOnController(
        player: MediaController,
        streamUrl: String,
        title: String,
        author: String?,
        startPositionMs: Long,
        mediaId: String,
        authToken: String?,
    ) {
        activeTrackDurationsMs = emptyList()
        activeTrackOffsetsMs = emptyList()
        activeQueueKey = queueKeyFor(mediaId, itemCount = 1)
        _state.value = _state.value.copy(errorMessage = null)

        val metadata = MediaMetadata.Builder()
            .setTitle(title)
            .setArtist(author)
            .build()

        val resolvedUrl = withAuthToken(streamUrl, authToken)
        val mediaItem = MediaItem.Builder()
            .setMediaId(mediaId)
            .setUri(resolvedUrl)
            .setMimeType(guessMimeType(resolvedUrl))
            .setMediaMetadata(metadata)
            .build()

        if (startPositionMs > 0) {
            player.setMediaItem(mediaItem, startPositionMs)
        } else {
            player.setMediaItem(mediaItem)
        }
        player.prepare()
        player.play()
    }

    fun playMultiTrack(
        tracks: List<TrackInfo>,
        bookId: String,
        title: String,
        author: String?,
        startPositionMs: Long = 0L,
        mediaId: String = "",
        authToken: String? = null,
    ) {
        resetTransientStateForNewBook(bookId)
        currentBookId = bookId
        val pending = PendingPlayback.Multi(
            tracks = tracks,
            bookId = bookId,
            title = title,
            author = author,
            startPositionMs = startPositionMs,
            mediaId = mediaId,
            authToken = authToken,
        )
        if (controller == null) {
            pendingPlayback = pending
            connect()
            return
        }
        runOnMain { playPending(pending) }
    }

    private fun playMultiTrackOnController(
        player: MediaController,
        tracks: List<TrackInfo>,
        title: String,
        author: String?,
        startPositionMs: Long,
        mediaId: String,
        authToken: String?,
    ) {
        activeTrackDurationsMs = tracks.map { it.durationMs.coerceAtLeast(0L) }
        activeTrackOffsetsMs = cumulativeTrackOffsets(activeTrackDurationsMs)
        activeQueueKey = queueKeyFor(mediaId, tracks.size)
        _state.value = _state.value.copy(errorMessage = null)

        val mediaItems = tracks.mapIndexed { index, track ->
            val itemMediaId = if (mediaId.isNotBlank() && tracks.size > 1) "$mediaId#track=$index" else mediaId
            val resolvedUrl = withAuthToken(track.url, authToken)
            MediaItem.Builder()
                .setMediaId(itemMediaId)
                .setUri(resolvedUrl)
                .setMimeType(guessMimeType(resolvedUrl))
                .setMediaMetadata(
                    MediaMetadata.Builder()
                        .setTitle(track.title ?: title)
                        .setArtist(author)
                        .apply {
                            if (track.durationMs > 0L) setDurationMs(track.durationMs)
                        }
                        .build()
                )
                .build()
        }

        var startWindowIndex = 0
        var startWindowPositionMs = 0L
        if (startPositionMs > 0 && tracks.isNotEmpty()) {
            var accumulated = 0L
            for ((index, track) in tracks.withIndex()) {
                if (accumulated + track.durationMs > startPositionMs) {
                    startWindowIndex = index
                    startWindowPositionMs = (startPositionMs - accumulated).coerceAtLeast(0L)
                    break
                }
                accumulated += track.durationMs
                if (index == tracks.size - 1) {
                    startWindowIndex = index
                    startWindowPositionMs = track.durationMs.coerceAtLeast(0L)
                }
            }
        }

        if (mediaItems.isNotEmpty()) {
            player.setMediaItems(mediaItems, startWindowIndex, startWindowPositionMs)
        } else {
            player.setMediaItems(mediaItems)
        }
        player.prepare()

        player.play()
    }

    fun togglePlayPause() {
        runOnMain {
            val player = controller ?: return@runOnMain
            if (player.isPlaying) player.pause() else player.play()
        }
    }

    fun seekTo(positionMs: Long) {
        runOnMain {
            val player = controller ?: return@runOnMain
            refreshTrackOffsetsFromQueue(player)
            seekToAbsolute(player, positionMs.coerceAtLeast(0L))
        }
    }

    fun seekToMediaItem(index: Int, positionMs: Long = 0L) {
        runOnMain {
            val player = controller ?: return@runOnMain
            if (index !in 0 until player.mediaItemCount) return@runOnMain
            player.seekTo(index, positionMs.coerceAtLeast(0L))
        }
    }

    fun skipForward(ms: Long = 30_000) {
        runOnMain {
            val player = controller ?: return@runOnMain
            refreshTrackOffsetsFromQueue(player)
            if (!hasReliableMultiTrackTimeline(player.mediaItemCount, activeTrackDurationsMs)) {
                seekRelativeInQueue(player, ms.coerceAtLeast(0L))
                return@runOnMain
            }
            val duration = resolveAbsoluteDurationMs(player)
            val target = resolveAbsolutePositionMs(player) + ms
            seekToAbsolute(player, if (duration > 0L) target.coerceAtMost(duration) else target)
        }
    }

    fun skipBackward(ms: Long = 30_000) {
        runOnMain {
            val player = controller ?: return@runOnMain
            refreshTrackOffsetsFromQueue(player)
            if (!hasReliableMultiTrackTimeline(player.mediaItemCount, activeTrackDurationsMs)) {
                seekRelativeInQueue(player, -ms.coerceAtLeast(0L))
                return@runOnMain
            }
            seekToAbsolute(player, resolveAbsolutePositionMs(player) - ms)
        }
    }

    fun setPlaybackSpeed(speed: Float) {
        val clampedSpeed = speed.coerceIn(0.5f, 3.0f)
        _state.value = _state.value.copy(playbackSpeed = clampedSpeed)
        runOnMain {
            controller?.playbackParameters = PlaybackParameters(clampedSpeed)
        }
    }

    fun setVolume(volume: Float) {
        runOnMain {
            controller?.volume = volume.coerceIn(0f, 1f)
        }
    }

    fun clearCompletionFlag() {
        _state.value = _state.value.copy(playbackCompleted = false)
    }

    fun stop() {
        currentBookId = null
        pendingPlayback = null
        activeTrackDurationsMs = emptyList()
        activeTrackOffsetsMs = emptyList()
        activeQueueKey = null
        _state.value = PlaybackState()
        positionJob?.cancel()
        runOnMain {
            controller?.stop()
            controller?.clearMediaItems()
        }
    }

    fun release() {
        currentBookId = null
        pendingPlayback = null
        activeTrackDurationsMs = emptyList()
        activeTrackOffsetsMs = emptyList()
        activeQueueKey = null
        _state.value = PlaybackState()
        positionJob?.cancel()
        runOnMain {
            controller?.stop()
            controller?.clearMediaItems()
            controllerFuture?.let { MediaController.releaseFuture(it) }
            controller = null
            controllerFuture = null
            scope.cancel()
        }
    }

    private fun setupPlayerListener() {
        val player = controller ?: return

        player.addListener(object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                syncPlaybackSnapshot(player)
                if (isPlaying) startPositionTracking() else positionJob?.cancel()
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                syncPlaybackSnapshot(player)
                if (playbackState == Player.STATE_ENDED) {
                    _state.value = _state.value.copy(playbackCompleted = true)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                Log.e("AudioPlaybackManager", "Playback failed: ${error.errorCodeName}", error)
                _state.value = _state.value.copy(
                    isPlaying = false,
                    isBuffering = false,
                    errorMessage = error.errorCodeName,
                )
            }

            override fun onPlaybackParametersChanged(params: PlaybackParameters) {
                syncPlaybackSnapshot(player)
            }

            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                syncPlaybackSnapshot(player)
            }
        })
        syncPlaybackSnapshot(player)
        if (player.isPlaying) startPositionTracking()
    }

    private fun startPositionTracking() {
        positionJob?.cancel()
        positionJob = scope.launch {
            while (isActive) {
                controller?.let { player ->
                    refreshTrackOffsetsFromQueue(player)
                    val absolutePositionMs = resolveAbsolutePositionMs(player)
                    val absoluteDurationMs = resolveAbsoluteDurationMs(player)
                    _state.value = _state.value.copy(
                        currentPositionMs = absolutePositionMs,
                        durationMs = absoluteDurationMs,
                        currentMediaItemIndex = player.currentMediaItemIndex,
                        mediaItemCount = player.mediaItemCount,
                        mediaId = player.currentMediaItem?.mediaId?.takeIf { it.isNotBlank() },
                    )
                }
                delay(250)
            }
        }
    }

    private fun syncPlaybackSnapshot(player: MediaController) {
        val playbackState = player.playbackState
        refreshTrackOffsetsFromQueue(player)
        _state.value = _state.value.copy(
            isPlaying = player.isPlaying,
            isBuffering = playbackState == Player.STATE_BUFFERING,
            currentPositionMs = resolveAbsolutePositionMs(player),
            durationMs = resolveAbsoluteDurationMs(player),
            currentMediaItemIndex = player.currentMediaItemIndex,
            mediaItemCount = player.mediaItemCount,
            playbackSpeed = player.playbackParameters.speed,
            isReady = playbackState == Player.STATE_READY,
            mediaId = player.currentMediaItem?.mediaId?.takeIf { it.isNotBlank() },
        )
    }

    private fun resolveAbsolutePositionMs(player: MediaController): Long {
        val localPosition = player.currentPosition.coerceAtLeast(0)
        if (!hasReliableMultiTrackTimeline(player.mediaItemCount, activeTrackDurationsMs)) return localPosition
        return resolveAbsolutePlaybackPosition(
            localPositionMs = localPosition,
            currentIndex = player.currentMediaItemIndex,
            trackOffsetsMs = activeTrackOffsetsMs,
        )
    }

    private fun resolveAbsoluteDurationMs(player: MediaController): Long {
        val trackTotal = activeTrackDurationsMs.sum().coerceAtLeast(0)
        if (trackTotal > 0L) return trackTotal
        return player.duration.coerceAtLeast(0)
    }

    private fun seekToAbsolute(player: MediaController, positionMs: Long) {
        val target = positionMs.coerceAtLeast(0L)
        if (!hasReliableMultiTrackTimeline(player.mediaItemCount, activeTrackDurationsMs)) {
            val index = player.currentMediaItemIndex.coerceIn(0, (player.mediaItemCount - 1).coerceAtLeast(0))
            player.seekTo(index, target)
            return
        }

        val index = activeTrackOffsetsMs
            .indexOfLast { target >= it }
            .coerceIn(0, activeTrackOffsetsMs.lastIndex)
        val localDuration = activeTrackDurationsMs.getOrNull(index)?.takeIf { it > 0L }
        val localPosition = (target - activeTrackOffsetsMs[index])
            .coerceAtLeast(0L)
            .let { position -> localDuration?.let(position::coerceAtMost) ?: position }
        player.seekTo(index, localPosition)
    }

    private fun refreshTrackOffsetsFromQueue(player: MediaController) {
        val queueKey = queueKeyFor(player.currentMediaItem?.mediaId.orEmpty(), player.mediaItemCount)
        if (queueKey != activeQueueKey) {
            activeQueueKey = queueKey
            activeTrackDurationsMs = if (player.mediaItemCount > 1) {
                (0 until player.mediaItemCount).map { index ->
                    player.getMediaItemAt(index).mediaMetadata.durationMs?.coerceAtLeast(0L) ?: 0L
                }
            } else {
                emptyList()
            }
        }

        if (player.mediaItemCount <= 1 || activeTrackDurationsMs.size != player.mediaItemCount) {
            activeTrackDurationsMs = emptyList()
            activeTrackOffsetsMs = emptyList()
            return
        }

        val window = Timeline.Window()
        activeTrackDurationsMs = activeTrackDurationsMs.mapIndexed { index, knownDuration ->
            val timelineDuration = runCatching {
                player.currentTimeline.getWindow(index, window).durationMs
            }.getOrDefault(0L)
            when {
                timelineDuration > 0L -> timelineDuration
                index == player.currentMediaItemIndex && player.duration > 0L -> player.duration
                else -> knownDuration
            }
        }
        activeTrackOffsetsMs = cumulativeTrackOffsets(activeTrackDurationsMs)
    }

    private fun seekRelativeInQueue(player: MediaController, deltaMs: Long) {
        val target = resolveRelativeQueueSeek(
            durationsMs = activeTrackDurationsMs,
            currentIndex = player.currentMediaItemIndex,
            currentPositionMs = player.currentPosition,
            deltaMs = deltaMs,
        )
        player.seekTo(target.mediaItemIndex, target.positionMs)
    }

    private fun queueKeyFor(mediaId: String, itemCount: Int): String {
        val baseId = AutoMediaBrowserHelper.cacheKeyFrom(mediaId) ?: mediaId
        return "$baseId:$itemCount"
    }

    private fun playPending(pending: PendingPlayback) {
        currentBookId = pending.bookId
        val player = controller ?: return
        when (pending) {
            is PendingPlayback.Single -> playSingleOnController(
                player = player,
                streamUrl = pending.streamUrl,
                title = pending.title,
                author = pending.author,
                startPositionMs = pending.startPositionMs,
                mediaId = pending.mediaId,
                authToken = pending.authToken,
            )
            is PendingPlayback.Multi -> playMultiTrackOnController(
                player = player,
                tracks = pending.tracks,
                title = pending.title,
                author = pending.author,
                startPositionMs = pending.startPositionMs,
                mediaId = pending.mediaId,
                authToken = pending.authToken,
            )
        }
    }

    data class TrackInfo(
        val url: String,
        val title: String?,
        val durationMs: Long,
    )

    private sealed interface PendingPlayback {
        val bookId: String

        data class Single(
            val streamUrl: String,
            override val bookId: String,
            val title: String,
            val author: String?,
            val startPositionMs: Long,
            val mediaId: String,
            val authToken: String?,
        ) : PendingPlayback

        data class Multi(
            val tracks: List<TrackInfo>,
            override val bookId: String,
            val title: String,
            val author: String?,
            val startPositionMs: Long,
            val mediaId: String,
            val authToken: String?,
        ) : PendingPlayback
    }

    companion object {

        internal fun withAuthToken(url: String, token: String?): String {
            val trimmed = token?.trim().orEmpty()
            if (trimmed.isEmpty()) return url

            if (url.contains("?token=") || url.contains("&token=") ||
                url.contains("?X-Plex-Token=") || url.contains("&X-Plex-Token=")
            ) {
                return url
            }
            val sep = if (url.contains('?')) '&' else '?'
            return "$url${sep}token=$trimmed"
        }

        internal fun guessMimeType(url: String): String {
            val path = url.substringBefore('?').substringBefore('#').lowercase()
            return when {
                path.endsWith(".mp3") -> MimeTypes.AUDIO_MPEG
                path.endsWith(".m4a") || path.endsWith(".m4b") ||
                    path.endsWith(".mp4") || path.endsWith(".aac") -> MimeTypes.AUDIO_MP4
                path.endsWith(".flac") -> MimeTypes.AUDIO_FLAC
                path.endsWith(".ogg") || path.endsWith(".opus") -> MimeTypes.AUDIO_OGG
                path.endsWith(".wav") -> MimeTypes.AUDIO_WAV
                path.endsWith(".m3u8") -> MimeTypes.APPLICATION_M3U8
                else -> MimeTypes.AUDIO_MPEG
            }
        }
    }
}
