package com.enve.wear.listening

import android.content.Intent
import androidx.core.content.edit
import android.media.AudioDeviceInfo
import android.media.AudioManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import androidx.media3.session.SessionResult
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

data class WatchPlayerState(
    val book: WatchBook? = null,
    val positionMs: Long = 0,
    val playing: Boolean = false,
    val speed: Float = 1f,
    val sleepAt: Long? = null,
    val error: String? = null,
)

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
class WatchPlaybackService : MediaSessionService() {
    private lateinit var player: ExoPlayer
    private lateinit var session: MediaSession
    private lateinit var store: WatchLibraryStore
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var book: WatchBook? = null
    private var allowSpeaker = false
    private var sleepJob: Job? = null
    private var ticker: Job? = null
    private var sleepAt: Long? = null
    private var lastSaved = -1L

    override fun onCreate() {
        super.onCreate()
        store = WatchLibraryStore.get(this)
        player = ExoPlayer.Builder(this).build().apply {
            setAudioAttributes(AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(), true)
            setHandleAudioBecomingNoisy(true)
            setWakeMode(C.WAKE_MODE_LOCAL)
            setPlaybackSpeed(getSharedPreferences("watch-player", 0).getFloat("speed", 1f))
            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    ticker?.cancel()
                    if (isPlaying) ticker = scope.launch {
                        while (isActive) { publish(); persist(); delay(2000) }
                    } else {
                        persist(force = true)
                        book?.let { WatchProgressSyncWorker.enqueue(this@WatchPlaybackService, it.key) }
                    }
                }
                override fun onEvents(player: Player, events: Player.Events) {
                    if (player.playWhenReady && !canPlay()) player.pause()
                    publish()
                    if (!player.isPlaying) persist(force = true)
                }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    stateFlow.value = stateFlow.value.copy(error = "This audio could not be played. Try downloading the book again.")
                }
            })
        }
        session = MediaSession.Builder(this, player).setCallback(object : MediaSession.Callback {
            override fun onConnect(session: MediaSession, controller: MediaSession.ControllerInfo): MediaSession.ConnectionResult {
                return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                    .setAvailablePlayerCommands(MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                        .remove(Player.COMMAND_CHANGE_MEDIA_ITEMS).remove(Player.COMMAND_SET_MEDIA_ITEM).build()).build()
            }
            @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
            override fun onPlayerCommandRequest(session: MediaSession, controller: MediaSession.ControllerInfo, playerCommand: Int): Int {
                return if (playerCommand == Player.COMMAND_PLAY_PAUSE && !player.isPlaying && !canPlay()) SessionResult.RESULT_ERROR_INVALID_STATE else SessionResult.RESULT_SUCCESS
            }
        }).build()
        addSession(session)
        active = this
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession = session

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_OPEN) {
            val selected = store.state.value.books.firstOrNull { it.key == intent.getStringExtra("key") && it.downloaded }
            if (selected != null) open(selected, intent.getBooleanExtra("speaker", false)) else {
                stateFlow.value = WatchPlayerState(error = "Download this book again; its saved audio is unavailable.")
                stopSelf()
            }
        }
        return super.onStartCommand(intent, flags, startId)
    }

    private fun open(selected: WatchBook, speaker: Boolean) {
        persist(force = true)
        allowSpeaker = speaker
        if (!canPlay()) {
            stateFlow.value = stateFlow.value.copy(error = "Connect headphones to the watch before playing.")
            stopSelf()
            return
        }
        val directory = store.directory(selected.key)
        val files = selected.tracks.map { File(directory, it.path) }
        if (files.isEmpty() || files.any { !it.isFile || it.length() == 0L }) {
            stateFlow.value = stateFlow.value.copy(error = "Download this book again; audio is missing.")
            stopSelf()
            return
        }
        book = selected
        stateFlow.value = WatchPlayerState(book = selected)
        lastSaved = -1
        val position = selected.locate(store.state.value.positions[selected.key]?.positionMs ?: 0)
        val items = files.mapIndexed { index, file ->
            MediaItem.Builder().setMediaId("${selected.key}/$index").setUri(android.net.Uri.fromFile(file))
                .setMediaMetadata(MediaMetadata.Builder().setTitle(selected.title).setArtist(selected.author).build()).build()
        }
        player.setMediaItems(items, position.index, position.offsetMs)
        player.prepare()
        player.play()
        publish()
    }

    fun toggle() {
        if (player.playWhenReady) player.pause() else if (canPlay()) player.play()
        else stateFlow.value = stateFlow.value.copy(error = "Connect headphones to the watch before playing.")
    }

    fun seek(positionMs: Long) {
        val selected = book ?: return
        val target = selected.locate(positionMs)
        player.seekTo(target.index, target.offsetMs)
        publish()
        persist(force = true)
    }

    fun speed(value: Float) {
        player.setPlaybackSpeed(value)
        getSharedPreferences("watch-player", 0).edit { putFloat("speed", value) }
        publish()
    }

    fun sleep(minutes: Int) {
        sleepJob?.cancel()
        sleepAt = if (minutes > 0) System.currentTimeMillis() + minutes * 60_000L else null
        if (minutes > 0) sleepJob = scope.launch {
            delay(minutes * 60_000L)
            player.pause()
            sleepAt = null
            publish()
        }
        publish()
    }

    fun bookmark() {
        val selected = book ?: return
        val position = position()
        scope.launch(Dispatchers.IO) { store.bookmark(selected.key, position) }
    }

    private fun canPlay(): Boolean = allowSpeaker || hasHeadphones(this)
    private fun position(): Long = book?.let { selected ->
        ((selected.tracks.getOrNull(player.currentMediaItemIndex)?.startMs ?: 0) + player.currentPosition).coerceIn(0, selected.durationMs)
    } ?: 0L

    private fun publish() {
        stateFlow.value = WatchPlayerState(book, position(), player.isPlaying, player.playbackParameters.speed, sleepAt, stateFlow.value.error)
    }

    private fun persist(force: Boolean = false) {
        val selected = book ?: return
        val position = position()
        if (position == lastSaved) return
        if (!force && lastSaved >= 0L && kotlin.math.abs(position - lastSaved) < 10_000L) return
        lastSaved = position
        val updatedAt = System.currentTimeMillis()
        scope.launch(Dispatchers.IO) { store.savePosition(selected.key, position, updatedAt) }
    }

    override fun onDestroy() {
        book?.let { store.savePosition(it.key, position()) }
        book?.let { WatchProgressSyncWorker.enqueue(this, it.key) }
        scope.cancel()
        session.release()
        player.release()
        active = null
        stateFlow.value = WatchPlayerState(error = stateFlow.value.error)
        super.onDestroy()
    }

    companion object {
        const val ACTION_OPEN = "com.enve.wear.PLAY_DOWNLOAD"
        var active: WatchPlaybackService? = null
            private set
        private val stateFlow = MutableStateFlow(WatchPlayerState())
        val state = stateFlow.asStateFlow()
        fun hasHeadphones(context: android.content.Context): Boolean = context.getSystemService(AudioManager::class.java)
            .getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in setOf(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_HEARING_AID) || (android.os.Build.VERSION.SDK_INT >= 31 && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET) }
    }
}
