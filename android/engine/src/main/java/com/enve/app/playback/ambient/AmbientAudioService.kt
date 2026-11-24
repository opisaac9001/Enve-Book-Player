package com.enve.app.playback.ambient

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.enve.app.playback.AudioPlaybackManager
import com.enve.app.playback.AutoMediaBrowserHelper
import com.enve.core.di.ApplicationScope
import com.enve.engine.playback.AmbientAudioPreset
import com.enve.engine.playback.AmbientAudioState
import com.enve.engine.playback.PlayerSessionFacade
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

private const val MAX_IMPORT_BYTES = 200L * 1024 * 1024
private const val FADE_WINDOW_SECONDS = 30L

internal object AmbientAudioPresets {
    val all = listOf(
        AmbientAudioPreset("rainfall", "Rainfall", "Steady rain bed for focus listening."),
        AmbientAudioPreset("fireplace", "Fireplace", "Soft fire bed with small crackles."),
        AmbientAudioPreset("rainforest", "Rainforest", "Light canopy, insects, and distant birds."),
        AmbientAudioPreset("ocean-waves", "Ocean Waves", "Slow surf and low wave movement."),
    )

    fun preset(id: String): AmbientAudioPreset? = all.firstOrNull { it.id == id }

    fun assetUri(id: String): String = "asset:///ambient/ambient-$id.mp3"
}

internal fun ambientFadeScale(sleepRemainingSec: Long?): Float =
    if (sleepRemainingSec != null && sleepRemainingSec in 0 until FADE_WINDOW_SECONDS) {
        sleepRemainingSec.toFloat() / FADE_WINDOW_SECONDS
    } else {
        1f
    }

@Singleton
class AmbientAudioService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val store: AmbientAudioStore,
    private val audioManager: AudioPlaybackManager,
    private val session: PlayerSessionFacade,
    @ApplicationScope parentScope: CoroutineScope,
) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.Main.immediate)
    private val _state = MutableStateFlow(AmbientAudioState(presets = AmbientAudioPresets.all))
    val state: StateFlow<AmbientAudioState> = _state.asStateFlow()
    private var player: ExoPlayer? = null
    private var volumeSave: Job? = null
    private var activeBookKey: String? = null
    private val selectionMutex = Mutex()

    init {
        scope.launch {
            try {
                awaitCancellation()
            } finally {
                releasePlayer()
            }
        }
        scope.launch {
            try {
                _state.update { it.copy(volume = store.volume()) }
            } catch (error: IOException) {
                Log.w(TAG, "Ambient sound settings are unreadable", error)
            }
            launch {
                audioManager.state.map { it.mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom) }
                    .distinctUntilChanged()
                    .collect { key ->
                        activeBookKey = key
                        selectionMutex.withLock {
                            val selection = try {
                                key?.let { store.selection(it) }
                            } catch (error: IOException) {
                                Log.w(TAG, "Ambient sound selection is unreadable", error)
                                _state.update { it.copy(errorMessage = STORAGE_ERROR) }
                                null
                            }
                            if (activeBookKey == key) applySelection(key, selection)
                        }
                    }
            }
            combine(
                audioManager.state.map { it.isPlaying }.distinctUntilChanged(),
                session.sleepRemainingSec.map(::ambientFadeScale).distinctUntilChanged(),
                _state.map { it.volume }.distinctUntilChanged(),
            ) { _, _, _ -> }.collect { syncPlayback() }
        }
    }

    fun attachPreset(presetId: String) {
        scope.launch {
            val preset = AmbientAudioPresets.preset(presetId) ?: return@launch
            val key = currentBookKey() ?: return@launch
            updateSelection(key, AmbientAudioSelection(bookKey = key, displayName = preset.title, presetId = preset.id))
        }
    }

    suspend fun attachTrack(uri: String) = withContext(Dispatchers.Main.immediate) {
        val key = currentBookKey() ?: return@withContext
        val imported = try {
            withContext(Dispatchers.IO) { importTrack(Uri.parse(uri)) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: AmbientImportException) {
            _state.update { it.copy(errorMessage = error.message) }
            return@withContext
        } catch (_: Exception) {
            _state.update { it.copy(errorMessage = "That file could not be imported.") }
            return@withContext
        }
        val selection = AmbientAudioSelection(bookKey = key, displayName = imported.displayName, importedFile = imported.fileName)
        var saved = false
        try {
            saved = updateSelection(key, selection)
        } finally {
            if (!saved) withContext(NonCancellable + Dispatchers.IO) { store.importedTrack(imported.fileName).delete() }
        }
    }

    fun remove() {
        scope.launch {
            val key = activeBookKey ?: return@launch
            updateSelection(key, null)
        }
    }

    private suspend fun updateSelection(bookKey: String, selection: AmbientAudioSelection?): Boolean =
        selectionMutex.withLock {
            try {
                withContext(NonCancellable) { if (selection == null) store.clear(bookKey) else store.save(selection) }
            } catch (error: IOException) {
                Log.w(TAG, "Couldn't save ambient sound", error)
                _state.update { it.copy(errorMessage = STORAGE_ERROR) }
                return@withLock false
            }
            if (activeBookKey == bookKey) applySelection(bookKey, selection)
            true
        }

    fun setVolume(volume: Float) {
        scope.launch {
            val clamped = volume.coerceIn(0f, 1f)
            _state.update { it.copy(volume = clamped) }
            volumeSave?.cancel()
            volumeSave = launch {
                delay(300L)
                try {
                    store.saveVolume(clamped)
                } catch (error: IOException) {
                    Log.w(TAG, "Couldn't save ambient volume", error)
                }
            }
        }
    }

    fun clearError() = _state.update { it.copy(errorMessage = null) }

    private fun currentBookKey(): String? = activeBookKey ?: run {
        _state.update { it.copy(errorMessage = "Open a book before attaching ambient audio.") }
        null
    }

    private fun applySelection(bookKey: String?, selection: AmbientAudioSelection?) {
        releasePlayer()
        _state.update {
            it.copy(
                bookKey = bookKey,
                selectedPresetId = selection?.presetId,
                selectionName = selection?.displayName,
                isPlaying = false,
            )
        }
        val source = selection?.let(::sourceUri) ?: run {
            if (selection != null) _state.update { it.copy(errorMessage = "The selected ambient sound is no longer available.") }
            return
        }
        player = ExoPlayer.Builder(context)
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MUSIC).build(),
                false,
            )
            .build()
            .apply {
                val created = this
                repeatMode = Player.REPEAT_MODE_ONE
                addListener(object : Player.Listener {
                    override fun onIsPlayingChanged(isPlaying: Boolean) {
                        _state.update { it.copy(isPlaying = isPlaying) }
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        scope.launch(Dispatchers.Main) {
                            if (player !== created) return@launch
                            releasePlayer()
                            _state.update { it.copy(errorMessage = "Couldn't load ambient audio.") }
                        }
                    }
                })
                setMediaItem(MediaItem.fromUri(source))
                prepare()
            }
        syncPlayback()
    }

    private fun syncPlayback() {
        val player = player ?: return
        player.volume = _state.value.volume * ambientFadeScale(session.sleepRemainingSec.value)
        player.playWhenReady = audioManager.state.value.isPlaying
    }

    private fun releasePlayer() {
        player?.release()
        player = null
        _state.update { it.copy(isPlaying = false) }
    }

    private fun sourceUri(selection: AmbientAudioSelection): String? {
        selection.presetId?.let { id -> return AmbientAudioPresets.preset(id)?.let { AmbientAudioPresets.assetUri(it.id) } }
        val file = selection.importedFile?.let(store::importedTrack)?.takeIf { it.isFile } ?: return null
        return Uri.fromFile(file).toString()
    }

    private suspend fun importTrack(uri: Uri): ImportedTrack {
        val execution = currentCoroutineContext()
        val resolver = context.contentResolver
        val (displayName, size) = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
            ?.use { cursor ->
                if (!cursor.moveToFirst()) null
                else cursor.getString(0) to (if (cursor.isNull(1)) null else cursor.getLong(1))
            } ?: (null to null)
        if (size != null && size > MAX_IMPORT_BYTES) throw AmbientImportException(TOO_LARGE)
        val name = displayName?.takeIf { it.isNotBlank() } ?: "Ambient sound"
        val extension = name.substringAfterLast('.', "").lowercase().takeIf { it.matches(Regex("[a-z0-9]{1,5}")) }
        val fileName = UUID.randomUUID().toString() + (extension?.let { ".$it" } ?: "")
        if (!store.tracksDirectory.isDirectory && !store.tracksDirectory.mkdirs()) throw IOException("Couldn't create the ambient folder")
        val target = store.importedTrack(fileName)
        try {
            val input = resolver.openInputStream(uri) ?: throw IOException("No input stream")
            input.use { source ->
                target.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var copied = 0L
                    while (true) {
                        execution.ensureActive()
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > MAX_IMPORT_BYTES) throw AmbientImportException(TOO_LARGE)
                        output.write(buffer, 0, count)
                    }
                }
            }
            execution.ensureActive()
            if (!hasAudioTrack(target)) throw AmbientImportException("That file doesn't contain playable audio.")
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
        return ImportedTrack(fileName = fileName, displayName = name.substringBeforeLast('.').ifBlank { name })
    }

    private class ImportedTrack(val fileName: String, val displayName: String)

    private class AmbientImportException(message: String) : Exception(message)

    private companion object {
        const val TAG = "AmbientAudio"
        const val STORAGE_ERROR = "Ambient sounds couldn't be read or saved on this device."
        const val TOO_LARGE = "Ambient sounds must be smaller than 200 MB."
    }

    private fun hasAudioTrack(file: File): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(file.path)
            (0 until extractor.trackCount).any {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }
        } catch (_: IOException) {
            false
        } finally {
            extractor.release()
        }
    }
}
