package com.enve.engine.playback

import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable
data class AudiobookClip(
    val bookmarkId: String,
    val bookKey: String,
    val startMs: Long,
    val endMs: Long,
    val createdAtMs: Long,
    val transcript: String? = null,
) {
    val durationMs: Long get() = (endMs - startMs).coerceAtLeast(0L)

    companion object {
        const val MAX_DURATION_MS = 3_600_000L
    }
}

class AudiobookClipException(message: String) : Exception(message)

data class ClipShare(val uri: String, val mimeType: String, val title: String)

sealed interface ClipTranscriptionModel {
    data object Checking : ClipTranscriptionModel
    data class Missing(val sizeBytes: Long) : ClipTranscriptionModel
    data class Installing(val progress: Float) : ClipTranscriptionModel
    data object Ready : ClipTranscriptionModel
}

@Serializable
data class SleepAutomationSettings(
    val autoSleepEnabled: Boolean = false,
    val autoSleepStartMinutes: Int = 22 * 60,
    val autoSleepEndMinutes: Int = 6 * 60,
    val autoSleepTimerMinutes: Int = 30,
    val shakeToSnoozeEnabled: Boolean = false,
    val snoozeMinutes: Int = 10,
)

data class AmbientAudioPreset(val id: String, val title: String, val subtitle: String)

data class AmbientAudioState(
    val bookKey: String? = null,
    val presets: List<AmbientAudioPreset> = emptyList(),
    val selectedPresetId: String? = null,
    val selectionName: String? = null,
    val volume: Float = 0.35f,
    val isPlaying: Boolean = false,
    val errorMessage: String? = null,
)

interface PlayerExtrasFacade {
    val clips: StateFlow<List<AudiobookClip>>
    val clipBookKey: StateFlow<String?>
    val transcriptionModel: StateFlow<ClipTranscriptionModel>

    suspend fun saveClip(bookKey: String, bookmarkId: String?, anchorMs: Long, startMs: Long, endMs: Long, note: String?)
    suspend fun deleteClip(bookKey: String, bookmarkId: String)
    suspend fun exportClip(bookKey: String, bookmarkId: String): ClipShare
    suspend fun transcribeClip(bookKey: String, bookmarkId: String): String
    suspend fun installTranscriptionModel()

    val sleepAutomation: StateFlow<SleepAutomationSettings>
    val shakeAvailable: Boolean
    suspend fun updateSleepAutomation(settings: SleepAutomationSettings)

    val ambient: StateFlow<AmbientAudioState>
    fun attachAmbientPreset(presetId: String)
    suspend fun attachAmbientTrack(uri: String)
    fun removeAmbient()
    fun setAmbientVolume(volume: Float)
    fun clearAmbientError()
}
