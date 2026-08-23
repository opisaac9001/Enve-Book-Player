package com.enve.app.readium

import android.content.ComponentName
import android.content.Context
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.enve.app.playback.PlaybackService
import com.google.common.util.concurrent.MoreExecutors
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

data class ReadAloudPlaybackState(
    val sessionId: String? = null,
    val mediaId: String? = null,
    val positionMs: Long = 0L,
    val isPlaying: Boolean = false,
    val playWhenReady: Boolean = false,
    val playbackState: Int = Player.STATE_IDLE,
    val hasMediaItem: Boolean = false,
    val errorRevision: Long = 0L,
    val errorCode: Int? = null,
    val errorCodeName: String? = null,
)

data class ReadAloudPlaybackSession(
    val id: String,
    val title: String,
    val author: String?,
)

internal data class ReadAloudPlaybackCommand(
    val sessionId: String,
    val generation: Long,
)

internal data class ReadAloudPlaybackRevocation(
    val sessionIds: Set<String>,
    val activeSessionId: String?,
)

@Singleton
@androidx.annotation.OptIn(UnstableApi::class)
class ReadAloudPlaybackCoordinator @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    companion object {
        const val MEDIA_ID_PREFIX = "readaloud:"
        private const val POSITION_POLL_INTERVAL_MS = 40L
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(ReadAloudPlaybackState())
    val state: StateFlow<ReadAloudPlaybackState> = _state.asStateFlow()

    private var controllerDeferred: CompletableDeferred<MediaController>? = null
    private var controller: MediaController? = null
    private var positionJob: Job? = null
    private var activeSessionId: String? = null
    private var desiredSessionId: String? = null
    private var commandGeneration: Long = 0L
    private val sessionLossHandlers = mutableMapOf<String, () -> Unit>()
    private val generationLock = Any()
    private val commandMutex = Mutex()

    private val listener = object : Player.Listener {
        override fun onEvents(player: Player, events: Player.Events) {
            publish(player)
            if (player.isPlaying) startPositionPolling(player) else stopPositionPolling()
        }

        override fun onPlayerError(error: PlaybackException) {
            val sessionId = activeSessionId ?: return
            if (!belongsToSession(controller?.currentMediaItem?.mediaId, sessionId)) return
            _state.value = _state.value.copy(
                errorRevision = _state.value.errorRevision + 1L,
                errorCode = error.errorCode,
                errorCodeName = error.errorCodeName,
            )
        }
    }

    fun connect() {
        scope.launch { runCatching { awaitController() } }
    }

    internal fun beginCommand(sessionId: String): ReadAloudPlaybackCommand =
        ReadAloudPlaybackCommand(sessionId, beginCommandGeneration(sessionId))

    internal fun currentCommand(sessionId: String): ReadAloudPlaybackCommand? =
        synchronized(generationLock) {
            commandGeneration
                .takeIf { desiredSessionId == sessionId }
                ?.let { ReadAloudPlaybackCommand(sessionId, it) }
        }

    internal fun isCommandCurrent(command: ReadAloudPlaybackCommand): Boolean =
        isCommandCurrent(command.sessionId, command.generation)

    internal fun registerSessionLossHandler(sessionId: String, handler: () -> Unit) {
        synchronized(generationLock) { sessionLossHandlers[sessionId] = handler }
    }

    internal fun unregisterSessionLossHandler(sessionId: String) {
        synchronized(generationLock) { sessionLossHandlers.remove(sessionId) }
    }

    internal suspend fun prepareAndPlay(
        command: ReadAloudPlaybackCommand,
        trackKey: String,
        audioFile: File,
        title: String,
        author: String?,
        startPositionMs: Long,
        playbackSpeed: Float,
        playWhenReady: Boolean,
    ): Boolean = withContext(Dispatchers.Main.immediate) {
        if (!isCommandCurrent(command.sessionId, command.generation)) return@withContext false
        val player = awaitController()
        commandMutex.withLock {
            if (!isCommandCurrent(command.sessionId, command.generation)) return@withLock false
            activeSessionId = command.sessionId
            val mediaId = "$MEDIA_ID_PREFIX${command.sessionId}:${trackKey.hashCode()}"
            val metadata = MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(author)
                .build()
            val item = MediaItem.Builder()
                .setMediaId(mediaId)
                .setUri(Uri.fromFile(audioFile))
                .setMediaMetadata(metadata)
                .build()

            player.playbackParameters = PlaybackParameters(playbackSpeed.coerceIn(0.5f, 3.0f))
            player.setMediaItem(item, startPositionMs.coerceAtLeast(0L))
            player.prepare()
            if (playWhenReady) player.play() else player.pause()
            publish(player)
            if (playWhenReady) startPositionPolling(player)
            true
        }
    }

    internal suspend fun seekAndSetPlaying(
        command: ReadAloudPlaybackCommand,
        positionMs: Long,
        playWhenReady: Boolean,
    ): Boolean = withContext(Dispatchers.Main.immediate) {
        val player = controller ?: return@withContext false
        commandMutex.withLock {
            if (!isCommandCurrent(command) || !isCurrentSession(player, command.sessionId)) {
                return@withLock false
            }
            player.seekTo(positionMs.coerceAtLeast(0L))
            if (playWhenReady) player.play() else player.pause()
            publish(player)
            if (playWhenReady) startPositionPolling(player) else stopPositionPolling()
            true
        }
    }

    fun play(sessionId: String) {
        val generation = currentCommandGeneration(sessionId) ?: return
        scope.launch {
            commandMutex.withLock {
                val player = controller ?: return@withLock
                if (!isCommandCurrent(sessionId, generation) || !isCurrentSession(player, sessionId)) return@withLock
                player.play()
                startPositionPolling(player)
            }
        }
    }

    fun pause(sessionId: String) {
        val generation = currentCommandGeneration(sessionId) ?: return
        scope.launch {
            commandMutex.withLock {
                val player = controller ?: return@withLock
                if (!isCommandCurrent(sessionId, generation) || !isCurrentSession(player, sessionId)) return@withLock
                player.pause()
                publish(player)
                stopPositionPolling()
            }
        }
    }

    fun seekTo(sessionId: String, positionMs: Long) {
        val generation = currentCommandGeneration(sessionId) ?: return
        scope.launch {
            commandMutex.withLock {
                val player = controller ?: return@withLock
                if (!isCommandCurrent(sessionId, generation) || !isCurrentSession(player, sessionId)) return@withLock
                player.seekTo(positionMs.coerceAtLeast(0L))
                publish(player)
            }
        }
    }

    fun setPlaybackSpeed(sessionId: String, speed: Float) {
        val generation = currentCommandGeneration(sessionId) ?: return
        scope.launch {
            commandMutex.withLock {
                val player = controller ?: return@withLock
                if (!isCommandCurrent(sessionId, generation) || !isCurrentSession(player, sessionId)) return@withLock
                player.playbackParameters = PlaybackParameters(speed.coerceIn(0.5f, 3.0f))
            }
        }
    }

    fun stop(sessionId: String, afterStopped: (() -> Unit)? = null) {
        if (!invalidateSession(sessionId)) {
            afterStopped?.let { callback -> scope.launch(Dispatchers.IO) { callback() } }
            return
        }
        scope.launch {
            try {
                commandMutex.withLock { stopSessionPlayer(sessionId) }
            } finally {
                afterStopped?.let { callback -> withContext(Dispatchers.IO) { callback() } }
            }
        }
    }

    suspend fun stopActiveAndAwait() = withContext(Dispatchers.Main.immediate) {
        val revocation = revokeForNormalPlayback()
        completeNormalPlaybackRevocation(revocation, stopActivePlayer = true)
    }

    internal fun revokeForNormalPlayback(): ReadAloudPlaybackRevocation {
        val revocation = synchronized(generationLock) {
            val active = activeSessionId
            val sessions = setOfNotNull(desiredSessionId, active)
            if (sessions.isNotEmpty()) {
                desiredSessionId = null
                commandGeneration += 1L
            }
            ReadAloudPlaybackRevocation(sessions, active)
        }
        return revocation
    }

    internal suspend fun completeNormalPlaybackRevocation(
        revocation: ReadAloudPlaybackRevocation,
        stopActivePlayer: Boolean,
    ) = withContext(Dispatchers.Main.immediate) {
        revocation.sessionIds.forEach(::notifySessionLost)
        val active = revocation.activeSessionId ?: return@withContext
        commandMutex.withLock {
            if (stopActivePlayer) {
                stopSessionPlayer(active)
            } else if (activeSessionId == active) {
                stopPositionPolling()
                activeSessionId = null
                _state.value = ReadAloudPlaybackState()
            }
        }
    }

    fun isPlaying(sessionId: String): Boolean =
        _state.value.sessionId == sessionId && _state.value.isPlaying

    fun hasMediaItem(sessionId: String): Boolean =
        _state.value.sessionId == sessionId && _state.value.hasMediaItem

    fun currentPositionMs(sessionId: String): Long? =
        _state.value.takeIf { it.sessionId == sessionId && it.hasMediaItem }?.positionMs

    private fun stopSessionPlayer(sessionId: String) {
        controller?.let { player ->
            if (isCurrentSession(player, sessionId)) {
                stopPositionPolling()
                player.stop()
                player.clearMediaItems()
            }
        }
        if (activeSessionId == sessionId) {
            stopPositionPolling()
            activeSessionId = null
            _state.value = ReadAloudPlaybackState()
        }
    }

    private fun beginCommandGeneration(sessionId: String): Long {
        var displacedPendingSession: String? = null
        val generation = synchronized(generationLock) {
            desiredSessionId
                ?.takeIf { it != sessionId && activeSessionId != it }
                ?.let { displacedPendingSession = it }
            desiredSessionId = sessionId
            commandGeneration += 1L
            commandGeneration
        }
        displacedPendingSession?.let(::notifySessionLost)
        return generation
    }

    private fun currentCommandGeneration(sessionId: String): Long? = synchronized(generationLock) {
        commandGeneration.takeIf { desiredSessionId == sessionId }
    }

    private fun isCommandCurrent(sessionId: String, generation: Long): Boolean = synchronized(generationLock) {
        desiredSessionId == sessionId && commandGeneration == generation
    }

    private fun invalidateSession(sessionId: String): Boolean {
        val invalidated = synchronized(generationLock) {
            if (desiredSessionId != sessionId && activeSessionId != sessionId) return@synchronized false
            if (desiredSessionId == sessionId) {
                desiredSessionId = null
                commandGeneration += 1L
            }
            true
        }
        if (invalidated) notifySessionLost(sessionId)
        return invalidated
    }

    private fun notifySessionLost(sessionId: String) {
        val handler = synchronized(generationLock) { sessionLossHandlers[sessionId] }
        runCatching { handler?.invoke() }
    }

    private suspend fun awaitController(): MediaController {
        controller?.let { return it }
        controllerDeferred?.let { return it.await() }

        val deferred = CompletableDeferred<MediaController>()
        controllerDeferred = deferred
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val future = MediaController.Builder(context, token).buildAsync()
        future.addListener({
            try {
                val connected = future.get()
                controller = connected
                connected.addListener(listener)
                deferred.complete(connected)
            } catch (error: Exception) {
                controllerDeferred = null
                deferred.completeExceptionally(error)
            }
        }, MoreExecutors.directExecutor())
        return deferred.await()
    }

    private fun startPositionPolling(player: Player) {
        if (!player.isPlaying || positionJob?.isActive == true) return
        positionJob?.cancel()
        positionJob = scope.launch {
            while (activeSessionId != null) {
                publish(player)
                delay(POSITION_POLL_INTERVAL_MS)
            }
        }
    }

    private fun stopPositionPolling() {
        positionJob?.cancel()
        positionJob = null
    }

    private fun publish(player: Player) {
        val sessionId = activeSessionId ?: return
        val mediaId = player.currentMediaItem?.mediaId
        if (player.mediaItemCount > 0 && !belongsToSession(mediaId, sessionId)) {
            val revocation = revokeForNormalPlayback()
            revocation.sessionIds.forEach(::notifySessionLost)
            activeSessionId = null
            stopPositionPolling()
            _state.value = ReadAloudPlaybackState()
            return
        }
        _state.value = _state.value.copy(
            sessionId = sessionId,
            mediaId = mediaId,
            positionMs = player.currentPosition.coerceAtLeast(0L),
            isPlaying = player.isPlaying,
            playWhenReady = player.playWhenReady,
            playbackState = player.playbackState,
            hasMediaItem = player.mediaItemCount > 0 && belongsToSession(mediaId, sessionId),
        )
    }

    private fun isCurrentSession(player: Player, sessionId: String): Boolean =
        activeSessionId == sessionId && belongsToSession(player.currentMediaItem?.mediaId, sessionId)

    private fun belongsToSession(mediaId: String?, sessionId: String): Boolean =
        mediaId?.startsWith("$MEDIA_ID_PREFIX$sessionId:") == true
}
