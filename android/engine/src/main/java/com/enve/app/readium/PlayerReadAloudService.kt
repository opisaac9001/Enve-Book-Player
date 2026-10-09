package com.enve.app.readium

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import com.enve.app.data.links.BookLinkRepository
import com.enve.app.data.offline.withDownloadCalls
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.playback.AudioPlaybackManager
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.reader.EpubArchive
import com.enve.core.reader.MediaOverlayTimeline
import com.enve.engine.playback.ReadAloudLyricLine
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.zip.ZipFile
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.jsoup.Jsoup

internal data class PlayerReadAloudDocument(
    val file: File,
    val timeline: MediaOverlayTimeline,
    val text: Map<String, String>,
    val embeddedAudio: Boolean = false,
) {
    fun lines(tracks: List<AudioTrack> = emptyList(), durationMs: Long = 0L): List<ReadAloudLyricLine> {
        val offsets = if (embeddedAudio) playerReadAloudOffsets(timeline, emptyList(), 0L)
            else playerReadAloudOffsets(timeline, tracks, durationMs)
        offsets ?: return emptyList()
        return timeline.clips.mapIndexedNotNull { index, clip ->
            val id = "${clip.textHref}#${clip.fragmentId}"
            val content = text[id]?.takeIf { it.isNotBlank() } ?: return@mapIndexedNotNull null
            val offset = offsets[clip.audioSrc] ?: return@mapIndexedNotNull null
            ReadAloudLyricLine("$id@$index", content, index, offset + (clip.clipBegin * 1000).roundToLong(),
                offset + (clip.clipEnd * 1000).roundToLong())
        }.sortedBy { it.startMs }
    }
}

internal fun playerReadAloudOffsets(
    timeline: MediaOverlayTimeline,
    tracks: List<AudioTrack>,
    durationMs: Long,
): Map<String, Long>? {
    val sources = timeline.clips.map { it.audioSrc }.distinct()
    val ordered = tracks.sortedBy { it.index }
    var cursor = 0L
    val windows = ordered.map { track ->
        val offset = cursor
        cursor += track.durationMs.coerceAtLeast(0L)
        track to offset
    }
    val storytellerTracks = ordered.isNotEmpty() && ordered.withIndex().all { (index, track) ->
        audioResourceKey(track.fileName).substringBeforeLast('.') == "${index.toString().padStart(5, '0')}-00001"
    }
    val matched = sources.associateWith { source ->
        val key = audioResourceKey(source)
        val storytellerOffset = if (storytellerTracks) windows.firstOrNull { (track, _) ->
            storytellerReadAloudAudioStem(track.fileName) == key.substringBeforeLast('.')
        }?.second else null
        storytellerOffset ?: windows.firstOrNull { (track, _) ->
            listOfNotNull(track.fileName, track.contentUrl).any { audioResourceKey(it) == key }
        }?.second
    }
    if (ordered.all { it.durationMs > 0L } && matched.values.all { it != null }) {
        return matched.mapValues { it.value!! }
    }
    if (durationMs > 0L && !MediaOverlayTimeline.narrationMatchesAudio(
            timeline.totalAudioDuration, durationMs / 1000.0)) return null
    return sources.associateWith { source ->
        val index = timeline.clips.indexOfFirst { it.audioSrc == source }
        ((timeline.clipTimings[index].audioStart - timeline.clips[index].clipBegin) * 1000).roundToLong()
    }
}

internal fun playerReadAloudActiveLine(lines: List<ReadAloudLyricLine>, positionMs: Long): ReadAloudLyricLine? {
    if (lines.isEmpty()) return null
    var low = 0
    var high = lines.size
    while (low < high) {
        val middle = (low + high) / 2
        if (lines[middle].startMs <= positionMs) low = middle + 1 else high = middle
    }
    return lines[(low - 1).coerceAtLeast(0)]
}

@Singleton
class PlayerReadAloudService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val locations: ProfileStorageLocations,
    private val offline: ComicOfflineStorage,
    private val links: BookLinkRepository,
    private val repository: AggregatorRepository,
    private val client: OkHttpClient,
) {
    internal data class EmbeddedAudio(
        val tracks: List<AudioPlaybackManager.TrackInfo>,
        val document: PlayerReadAloudDocument,
    )

    private val mutex = Mutex()
    private var embedded: Pair<String, EmbeddedAudio>? = null

    internal suspend fun document(book: Book): PlayerReadAloudDocument? = withContext(Dispatchers.IO) {
        mutex.withLock {
            embedded?.takeIf { it.first == book.uniqueKey }?.let { return@withLock it.second.document }
            val ebook = links.linkedEbook(book) ?: book
            val file = existingAsset(ebook)
                ?: if (ebook.readAlongAvailable || ebook.uniqueKey != book.uniqueKey) fetchAsset(ebook) else return@withLock null
            readDocument(file)
        }
    }

    internal suspend fun embeddedAudio(book: Book): EmbeddedAudio? = withContext(Dispatchers.IO) {
        if (book.mediaType != AppMediaType.EBOOK) return@withContext null
        mutex.withLock {
            embedded?.takeIf { it.first == book.uniqueKey }?.let { return@withLock it.second }
            val file = existingAsset(book)
                ?: if (book.readAlongAvailable) fetchAsset(book)
                else return@withLock null
            val document = readDocument(file) ?: return@withLock null
            val directory = File(locations.cacheDirectory, "player-read-aloud/${assetKey(book)}").apply { mkdirs() }
            val sources = document.timeline.clips.map { it.audioSrc }.distinct()
            val durations = mutableMapOf<String, Double>()
            val tracks = ZipFile(file).use { archive ->
                sources.mapIndexed { index, source ->
                    currentCoroutineContext().ensureActive()
                    val entry = archive.getEntry(source) ?: throw IOException("Narration audio is missing from this EPUB.")
                    val extension = source.substringAfterLast('.', "audio").filter(Char::isLetterOrDigit)
                    val destination = File(directory, "$index.$extension")
                    if (!destination.exists() || destination.length() != entry.size) {
                        val temporary = File(directory, "${destination.name}.part")
                        try {
                            archive.getInputStream(entry).use { input ->
                                temporary.outputStream().use { output ->
                                    val buffer = ByteArray(32_768)
                                    while (true) {
                                        currentCoroutineContext().ensureActive()
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        output.write(buffer, 0, count)
                                    }
                                }
                            }
                            check(temporary.renameTo(destination))
                        } finally { temporary.delete() }
                    }
                    val maximumEnd = document.timeline.clips.filter { it.audioSrc == source }.maxOf { it.clipEnd }
                    val declared = document.timeline.clipTimings.let { timings ->
                        val sourceIndex = document.timeline.clips.indexOfFirst { it.audioSrc == source }
                        val start = timings[sourceIndex].audioStart - document.timeline.clips[sourceIndex].clipBegin
                        val next = sources.getOrNull(index + 1)?.let { nextSource ->
                            val nextIndex = document.timeline.clips.indexOfFirst { it.audioSrc == nextSource }
                            timings[nextIndex].audioStart - document.timeline.clips[nextIndex].clipBegin
                        } ?: document.timeline.totalAudioDuration
                        next - start
                    }
                    val measured = MediaMetadataRetriever().let { retriever ->
                        try {
                            retriever.setDataSource(destination.path)
                            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                        } catch (_: RuntimeException) { null } finally { retriever.release() }
                    }
                    val durationMs = maxOf(measured ?: (declared * 1000).roundToLong(), (maximumEnd * 1000).roundToLong())
                    durations[source] = durationMs / 1000.0
                    AudioPlaybackManager.TrackInfo(Uri.fromFile(destination).toString(), "Chapter ${index + 1}", durationMs)
                }
            }
            val aligned = document.copy(embeddedAudio = true, timeline = MediaOverlayTimeline(document.timeline.clips, durations,
                document.timeline.clipTextProgressions))
            EmbeddedAudio(tracks, aligned).also { embedded = book.uniqueKey to it }
        }
    }

    private fun readDocument(file: File): PlayerReadAloudDocument? = EpubArchive.open(file).use { archive ->
        val timeline = MediaOverlayTimeline.load(archive) ?: return null
        val text = timeline.clips.groupBy { it.textHref }.flatMap { (href, clips) ->
            val document = Jsoup.parse(archive.html(href))
            clips.mapNotNull { clip ->
                document.getElementById(clip.fragmentId)?.text()?.trim()?.takeIf { it.isNotEmpty() }
                    ?.let { "${clip.textHref}#${clip.fragmentId}" to it }
            }
        }.toMap()
        PlayerReadAloudDocument(file, timeline, text)
    }

    private suspend fun fetchAsset(book: Book): File = withContext(
        book.connectionId?.let(ConnectionScope::asContextElement) ?: EmptyCoroutineContext,
    ) {
        val destination = cachedAsset(book)
        destination.parentFile?.mkdirs()
        if (destination.exists() && destination.length() > 0L) return@withContext destination
        val url = (if (book.readAlongAvailable) repository.getReadaloudDownloadUrl(book.id, book.source, book.connectionId) else null)
            ?: repository.getEbookDownloadUrl(book.id, book.source, book.connectionId)
            ?: throw IOException("No narrated EPUB is available from this source.")
        val temporary = File(destination.parentFile, "${destination.name}.part")
        try {
            if (url.startsWith("file:") || url.startsWith("content:")) {
                val input = context.contentResolver.openInputStream(Uri.parse(url))
                    ?: throw IOException("Couldn't open this EPUB.")
                input.use { source -> temporary.outputStream().use { output ->
                    val buffer = ByteArray(32_768)
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = source.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                    }
                } }
            } else {
                client.withDownloadCalls { calls ->
                    calls.execute(Request.Builder().url(url).build()).use { response ->
                        if (!response.isSuccessful) throw IOException("Couldn't download this EPUB (${response.code}).")
                        val body = response.body ?: throw IOException("The EPUB download was empty.")
                        body.byteStream().use { input -> temporary.outputStream().use { output ->
                            val buffer = ByteArray(32_768)
                            while (true) {
                                currentCoroutineContext().ensureActive()
                                val count = input.read(buffer)
                                if (count < 0) break
                                output.write(buffer, 0, count)
                            }
                        } }
                    }
                }
            }
            EpubArchive.open(temporary).close()
            currentCoroutineContext().ensureActive()
            check(temporary.renameTo(destination))
            destination
        } finally { temporary.delete() }
    }

    private fun existingAsset(book: Book): File? {
        if (offline.getManifest(book.id)?.uniqueKey == book.uniqueKey) {
            offline.getDownloadedFile(book.id)?.takeIf { it.extension.equals("epub", ignoreCase = true) }?.let { return it }
        }
        return cachedAsset(book).takeIf { it.isFile && it.length() > 0L }
    }

    private fun cachedAsset(book: Book): File {
        val name = book.id.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        return File(locations.cacheDirectory, "ebooks/$name.player-${assetKey(book)}.epub")
    }

    private fun assetKey(book: Book): String = MessageDigest.getInstance("SHA-256")
        .digest(book.uniqueKey.toByteArray()).joinToString("") { "%02x".format(it) }
}
