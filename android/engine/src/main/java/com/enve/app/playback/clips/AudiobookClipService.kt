package com.enve.app.playback.clips

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.app.storyalign.audio.AudioWindowDecoder
import com.enve.app.storyalign.transcribe.WhisperContext
import com.enve.app.storyalign.transcribe.WhisperModelManager
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.local.decodeAudioTracks
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.di.ApplicationScope
import com.enve.engine.playback.AudiobookClip
import com.enve.engine.playback.AudiobookClipException
import com.enve.engine.playback.ClipTranscriptionModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

private const val SHARE_DIRECTORY = "audiobook-clip-share"
private const val KEPT_SHARES = 5
private const val TRANSCRIPTION_WINDOW_MS = 30_000L

@Singleton
class AudiobookClipService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val store: AudiobookClipStore,
    private val offline: OfflineDownloadManager,
    private val bookExtras: BookExtrasDao,
    private val windowDecoder: AudioWindowDecoder,
    private val models: WhisperModelManager,
    @ApplicationScope parentScope: CoroutineScope,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val model = WhisperModelManager.TINY_EN
    private val _transcriptionModel = MutableStateFlow<ClipTranscriptionModel>(ClipTranscriptionModel.Checking)
    val transcriptionModel: StateFlow<ClipTranscriptionModel> = _transcriptionModel.asStateFlow()

    init {
        scope.launch {
            _transcriptionModel.value =
                if (models.isInstalled(model)) ClipTranscriptionModel.Ready else ClipTranscriptionModel.Missing(model.approxBytes)
        }
    }

    suspend fun hasLocalAudio(book: Book): Boolean = !localTracks(book).isNullOrEmpty()

    suspend fun installTranscriptionModel() {
        if (_transcriptionModel.value is ClipTranscriptionModel.Ready) return
        _transcriptionModel.value = ClipTranscriptionModel.Installing(0f)
        try {
            models.download(model) { progress -> _transcriptionModel.value = ClipTranscriptionModel.Installing(progress) }
            _transcriptionModel.value = ClipTranscriptionModel.Ready
        } catch (error: CancellationException) {
            _transcriptionModel.value = ClipTranscriptionModel.Missing(model.approxBytes)
            throw error
        } catch (_: Exception) {
            _transcriptionModel.value = ClipTranscriptionModel.Missing(model.approxBytes)
            throw AudiobookClipException("The speech model couldn't be downloaded. Check your connection and try again.")
        }
    }

    suspend fun export(book: Book, clip: AudiobookClip, title: String): File {
        val segments = segments(book, clip)
        val file = withContext(Dispatchers.IO) { shareFile(book.title, title) }
        try {
            ClipAudioExporter(context).export(segments, file)
        } catch (error: Throwable) {
            withContext(NonCancellable + Dispatchers.IO) { checkNotNull(file.parentFile).deleteRecursively() }
            if (error is CancellationException || error !is Exception) throw error
            throw AudiobookClipException("The clip couldn't be exported.")
        }
        return file
    }

    suspend fun transcribe(book: Book, clip: AudiobookClip): String {
        if (_transcriptionModel.value !is ClipTranscriptionModel.Ready) {
            throw AudiobookClipException("Download the speech model to transcribe clips.")
        }
        val segments = segments(book, clip)
        val transcript = try {
            recognize(segments)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
            throw AudiobookClipException("The clip couldn't be transcribed.")
        }
        if (transcript.isBlank()) throw AudiobookClipException("No speech was recognized in this clip.")
        store.saveTranscript(clip, transcript)
        return transcript
    }

    private suspend fun recognize(segments: List<ClipSegment>): String = withContext(Dispatchers.Default) {
        val execution = currentCoroutineContext()
        val whisper = WhisperContext.fromFile(models.modelFile(model).absolutePath)
        val threads = Runtime.getRuntime().availableProcessors().coerceIn(1, 4)
        try {
            buildString {
                for (segment in segments) {
                    var windowStart = segment.startMs
                    while (windowStart < segment.endMs) {
                        val length = minOf(TRANSCRIPTION_WINDOW_MS, segment.endMs - windowStart)
                        val pcm = windowDecoder.decode(segment.uri, null, windowStart / 1000.0, length / 1000.0)
                        execution.ensureActive()
                        if (pcm.isNotEmpty()) {
                            check(whisper.transcribe(pcm, "en", threads) == 0)
                            repeat(whisper.segmentCount()) { append(whisper.segmentText(it)).append(' ') }
                        }
                        windowStart += length
                    }
                }
            }.replace(Regex("\\s+"), " ").trim()
        } finally {
            whisper.release()
        }
    }

    private suspend fun segments(book: Book, clip: AudiobookClip): List<ClipSegment> {
        if (clip.endMs <= clip.startMs) throw AudiobookClipException("The clip range is invalid.")
        if (clip.durationMs > AudiobookClip.MAX_DURATION_MS) throw AudiobookClipException("Clips are limited to one hour.")
        val tracks = localTracks(book)?.takeIf { it.isNotEmpty() }
            ?: throw AudiobookClipException("Download this book before creating or exporting clips.")
        val resolved = withContext(Dispatchers.IO) { tracks.map { it.copy(durationMs = resolvedDuration(it)) } }
        return clipSegments(resolved, clip.startMs, clip.endMs)
            .ifEmpty { throw AudiobookClipException("No playable local audio files were found for this book.") }
    }

    private suspend fun localTracks(book: Book): List<ClipSourceTrack>? = withContext(Dispatchers.IO) {
        offline.localTracks(book.offlineDownloadKey)?.takeIf { it.isNotEmpty() }?.let { tracks ->
            return@withContext tracks.map { ClipSourceTrack(it.uri, it.durationMs) }
        }
        if (book.source != BookSource.LOCAL) return@withContext null
        val tracks = book.audioTracks.ifEmpty { bookExtras.get(book.uniqueKey)?.decodeAudioTracks().orEmpty() }
        tracks.mapNotNull { track -> track.contentUrl?.takeIf(::isLocalUri)?.let { ClipSourceTrack(it, track.durationMs) } }
            .takeIf { it.isNotEmpty() && it.size == tracks.size }
            ?: book.id.takeIf(::isLocalUri)?.let { listOf(ClipSourceTrack(it, book.duration * 1000L)) }
    }

    private fun resolvedDuration(track: ClipSourceTrack): Long {
        if (track.durationMs > 0) return track.durationMs
        val retriever = MediaMetadataRetriever()
        return try {
            val uri = Uri.parse(track.uri)
            if (uri.scheme == "content") retriever.setDataSource(context, uri) else retriever.setDataSource(requireNotNull(uri.path))
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()?.takeIf { it > 0 }
        } catch (_: RuntimeException) {
            null
        } finally {
            retriever.release()
        } ?: throw AudiobookClipException("No playable local audio files were found for this book.")
    }

    private fun shareFile(bookTitle: String, clipTitle: String): File {
        val root = File(locations.cacheDirectory, SHARE_DIRECTORY).apply { mkdirs() }
        root.listFiles()?.sortedByDescending { it.lastModified() }?.drop(KEPT_SHARES - 1)?.forEach { it.deleteRecursively() }
        val directory = File(root, UUID.randomUUID().toString()).apply { check(mkdirs()) }
        return File(directory, clipShareFilename(bookTitle, clipTitle))
    }

    private fun isLocalUri(value: String): Boolean = Uri.parse(value).scheme in setOf("content", "file")
}

internal fun clipShareFilename(bookTitle: String, clipTitle: String): String {
    fun fileNameComponent(value: String): String =
        value.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), " ").replace(Regex("\\s+"), " ").trim(' ', '.')
    val extension = ".m4a"
    var stem = listOf(bookTitle, clipTitle).map(::fileNameComponent).filter(String::isNotEmpty)
        .joinToString(" - ").take(100).trimEnd(Char::isHighSurrogate)
    while (stem.toByteArray().size > 255 - extension.length) {
        stem = stem.substring(0, stem.offsetByCodePoints(stem.length, -1))
    }
    return stem.trimEnd(' ', '.').ifEmpty { "Enve clip" } + extension
}
