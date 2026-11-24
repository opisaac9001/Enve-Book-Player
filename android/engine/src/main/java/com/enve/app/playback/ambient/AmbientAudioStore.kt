package com.enve.app.playback.ambient

import android.content.Context
import com.enve.app.playback.ProfileJsonFile
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

private const val AMBIENT_DIRECTORY = "ambient-audio"
private const val AMBIENT_FILE = "ambient.json"
private const val TRACKS_DIRECTORY = "tracks"
private const val DEFAULT_VOLUME = 0.35f

@Serializable
data class AmbientAudioSelection(
    val bookKey: String,
    val displayName: String,
    val presetId: String? = null,
    val importedFile: String? = null,
)

@Serializable
private data class AmbientAudioPayload(
    val volume: Float = DEFAULT_VOLUME,
    val selections: List<AmbientAudioSelection> = emptyList(),
)

@Singleton
class AmbientAudioStore @Inject constructor(
    @ApplicationContext context: Context,
    locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    private val directory = File(locations.filesDirectory, AMBIENT_DIRECTORY)
    val tracksDirectory = File(directory, TRACKS_DIRECTORY)
    private val file = ProfileJsonFile(File(directory, AMBIENT_FILE), AmbientAudioPayload.serializer()) { AmbientAudioPayload() }
    private val mutex = Mutex()
    private var payload: AmbientAudioPayload? = null

    suspend fun volume(): Float = mutex.withLock { current().volume.coerceIn(0f, 1f) }

    suspend fun saveVolume(volume: Float) = mutate { it.copy(volume = volume.coerceIn(0f, 1f)) }

    suspend fun selection(bookKey: String): AmbientAudioSelection? = mutex.withLock {
        current().selections.firstOrNull { it.bookKey == bookKey }
    }

    suspend fun save(selection: AmbientAudioSelection) = mutate { payload ->
        payload.copy(selections = payload.selections.filterNot { it.bookKey == selection.bookKey } + selection)
    }

    suspend fun clear(bookKey: String) = mutate { payload ->
        payload.copy(selections = payload.selections.filterNot { it.bookKey == bookKey })
    }

    fun importedTrack(name: String): File = File(tracksDirectory, name)

    private suspend fun mutate(transform: (AmbientAudioPayload) -> AmbientAudioPayload) = mutex.withLock {
        val previous = current()
        val updated = transform(previous)
        file.write(updated)
        payload = updated
        val referenced = updated.selections.mapNotNullTo(mutableSetOf()) { it.importedFile }
        val orphaned = previous.selections.mapNotNull { it.importedFile }.filterNot { it in referenced }
        if (orphaned.isNotEmpty()) withContext(Dispatchers.IO) { orphaned.forEach { importedTrack(it).delete() } }
    }

    private suspend fun current(): AmbientAudioPayload = payload ?: file.read().also { payload = it }
}
