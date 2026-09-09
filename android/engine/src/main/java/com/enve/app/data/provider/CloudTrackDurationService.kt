package com.enve.app.data.provider

import android.media.MediaMetadataRetriever
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.decodeAudioTracks
import com.enve.core.data.local.encodeAudioTracksJson
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class CloudTrackDurationService @Inject constructor(
    private val bookExtras: BookExtrasDao,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val activeProbes = ConcurrentHashMap.newKeySet<String>()

    suspend fun resolveDurations(book: Book, tracks: List<AudioTrack>): List<AudioTrack> {
        if (tracks.size <= 1 || tracks.all { it.durationMs > 0L }) return tracks

        val cacheKey = book.uniqueKey
        val existing = withContext(Dispatchers.IO) { bookExtras.get(cacheKey) }
        val cachedByName = existing?.decodeAudioTracks()
            ?.filter { it.durationMs > 0L }
            ?.associateBy { it.fileName }
            .orEmpty()
        val merged = tracks.map { track ->
            when {
                track.durationMs > 0L -> track
                else -> cachedByName[track.fileName]?.let { track.copy(durationMs = it.durationMs) } ?: track
            }
        }

        if (merged.any { it.durationMs <= 0L } && activeProbes.add(cacheKey)) {
            scope.launch {
                try {
                    persistIfChanged(cacheKey, probeMissing(merged))
                } finally {
                    activeProbes.remove(cacheKey)
                }
            }
        }
        return merged
    }

    private suspend fun probeMissing(tracks: List<AudioTrack>): List<AudioTrack> {
        val semaphore = Semaphore(PROBE_CONCURRENCY)
        return coroutineScope {
            tracks.map { track ->
                async {
                    if (track.durationMs > 0L) return@async track
                    val url = track.contentUrl ?: return@async track
                    val durationMs = semaphore.withPermit {
                        withTimeoutOrNull(PROBE_TIMEOUT_MS) {
                            withContext(Dispatchers.IO) { probeDurationMs(url) }
                        } ?: 0L
                    }
                    if (durationMs > 0L) track.copy(durationMs = durationMs) else track
                }
            }.awaitAll()
        }
    }

    private suspend fun persistIfChanged(cacheKey: String, tracks: List<AudioTrack>) {
        if (tracks.none { it.durationMs > 0L }) return

        val payload = encodeAudioTracksJson(tracks.map { it.copy(contentUrl = null) })
        withContext(Dispatchers.IO) {
            val existing = bookExtras.get(cacheKey)
            if (payload == existing?.audioTracksJson) return@withContext
            bookExtras.upsert(
                BookExtras(
                    cacheKey = cacheKey,
                    chaptersJson = existing?.chaptersJson ?: "[]",
                    audioTracksJson = payload,
                    updatedAt = System.currentTimeMillis(),
                ),
            )
        }
    }

    private fun probeDurationMs(url: String): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(url, emptyMap())
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (e: Exception) {
            0L
        } finally {
            runCatching { retriever.release() }
        }
    }

    private companion object {
        const val PROBE_CONCURRENCY = 4
        const val PROBE_TIMEOUT_MS = 15_000L
    }
}
