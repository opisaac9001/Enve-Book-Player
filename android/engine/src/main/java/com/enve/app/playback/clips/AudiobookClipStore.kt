package com.enve.app.playback.clips

import android.content.Context
import com.enve.app.playback.ProfileJsonFile
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.playback.AudiobookClip
import com.enve.engine.playback.AudiobookClipException
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.builtins.ListSerializer
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

private const val CLIPS_DIRECTORY = "audiobook-clips"
private const val CLIPS_FILE = "clips.json"

@Singleton
class AudiobookClipStore @Inject constructor(
    @ApplicationContext context: Context,
    locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    private val file = ProfileJsonFile(
        File(File(locations.filesDirectory, CLIPS_DIRECTORY), CLIPS_FILE),
        ListSerializer(AudiobookClip.serializer()),
    ) { emptyList() }
    private val mutex = Mutex()
    private var loaded = false
    private val _clips = MutableStateFlow<List<AudiobookClip>>(emptyList())
    val clips: StateFlow<List<AudiobookClip>> = _clips.asStateFlow()

    suspend fun load() = mutex.withLock { ensureLoaded() }

    suspend fun clip(bookmarkId: String): AudiobookClip? = mutex.withLock {
        ensureLoaded()
        _clips.value.firstOrNull { it.bookmarkId == bookmarkId }
    }

    suspend fun upsert(clip: AudiobookClip) = mutate { clips ->
        clips.filterNot { it.bookmarkId == clip.bookmarkId } + clip
    }

    suspend fun saveTranscript(original: AudiobookClip, transcript: String) = mutate { clips ->
        if (original !in clips) throw AudiobookClipException("The clip changed while it was being transcribed.")
        clips.map { if (it == original) it.copy(transcript = transcript) else it }
    }

    suspend fun delete(bookmarkIds: Set<String>) = mutate { clips ->
        clips.filterNot { it.bookmarkId in bookmarkIds }
    }

    private suspend fun mutate(transform: (List<AudiobookClip>) -> List<AudiobookClip>) = mutex.withLock {
        ensureLoaded()
        val updated = transform(_clips.value).sortedBy { it.startMs }
        if (updated == _clips.value) return@withLock
        file.write(updated)
        _clips.value = updated
    }

    private suspend fun ensureLoaded() {
        if (loaded) return
        _clips.value = file.read().sortedBy { it.startMs }
        loaded = true
    }
}
