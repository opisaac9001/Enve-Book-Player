package com.enve.app.storyalign

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.storyalign.align.AudioFile
import com.enve.app.storyalign.align.SentenceAligner
import com.enve.app.storyalign.align.Transcription
import com.enve.app.storyalign.align.TranscriptionBuilder
import com.enve.app.storyalign.align.TranscriptionSegment
import com.enve.app.storyalign.align.TranscriptionToken
import com.enve.app.storyalign.align.WordNormalizer
import com.enve.app.storyalign.audio.AudioDecoder
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.export.ReadAloudEpubBuilder
import com.enve.app.storyalign.transcribe.WhisperContext
import com.enve.app.storyalign.transcribe.WhisperModelManager
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.storyalign.StoryAlignSettings
import com.enve.engine.storyalign.StoryAlignStage
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class StoryAlignGenerator @Inject constructor(
    @ApplicationContext private val context: Context,
    private val aggregator: AggregatorRepository,
    private val okHttpClient: OkHttpClient,
    private val offlineDownloads: OfflineDownloadManager,
    private val bookCacheDao: BookCacheDao,
    private val modelManager: WhisperModelManager,
) {
    fun interface ProgressSink {
        suspend fun onStage(stage: StoryAlignStage, stageProgress: Float, overallProgress: Float)
    }

    data class Result(val outputPath: String, val outputBookId: String, val alignedSentences: Int, val totalSentences: Int)

    private class Track(val index: Int, val file: File, val durationSec: Double)

    suspend fun generate(job: StoryAlignJobEntity, settings: StoryAlignSettings, sink: ProgressSink): Result {
        val ebook = bookCacheDao.getByCacheKey(job.ebookKey)?.toBook()
            ?: throw IllegalStateException("Ebook not found in library")
        val audiobook = bookCacheDao.getByCacheKey(job.audiobookKey)?.toBook()
            ?: throw IllegalStateException("Audiobook not found in library")
        val sessionDir = File(job.sessionDir).apply { mkdirs() }

        sink.onStage(StoryAlignStage.DOWNLOAD, 0f, 0f)
        val epubFile = downloadEbook(ebook, sessionDir)
        sink.onStage(StoryAlignStage.DOWNLOAD, 0.1f, 0.02f)
        val tracks = ensureAudioDownloaded(audiobook) { p ->
            sink.onStage(StoryAlignStage.DOWNLOAD, 0.1f + 0.8f * p, 0.02f + 0.28f * p)
        }
        val modelFile = ensureModel(settings) { p ->
            sink.onStage(StoryAlignStage.DOWNLOAD, 0.9f + 0.1f * p, 0.30f + 0.05f * p)
        }

        sink.onStage(StoryAlignStage.EPUB_PARSE, 0.2f, 0.35f)
        val epubZip = EpubZip.from(epubFile)
        val doc = EpubParser.parse(epubZip, settings.granularity)
        sink.onStage(StoryAlignStage.EPUB_PARSE, 1f, 0.37f)

        val transcription = transcribe(tracks, modelFile, settings) { p ->
            sink.onStage(StoryAlignStage.TRANSCRIBE, p, 0.37f + 0.53f * p)
        }

        sink.onStage(StoryAlignStage.ALIGN, 0.2f, 0.90f)
        val chapters = SentenceAligner().alignBook(doc.spineOrderedManifest, transcription)
        val aligned = chapters.sumOf { it.alignedSentences.size }
        val total = chapters.sumOf { it.manifestItem.xhtmlSentences.size }
        sink.onStage(StoryAlignStage.ALIGN, 1f, 0.94f)

        sink.onStage(StoryAlignStage.EXPORT, 0.2f, 0.95f)
        val clips = tracks.map { ReadAloudEpubBuilder.AudioClipRef(it.file.name, it.file) }
        val outDir = File(context.filesDir, "storyalign/output").apply { mkdirs() }
        val outFile = File(outDir, "${job.id}_readaloud.epub")
        ReadAloudEpubBuilder.buildToFile(outFile, epubZip, doc, chapters, clips, isoNow())
        sink.onStage(StoryAlignStage.EXPORT, 1f, 0.98f)

        sink.onStage(StoryAlignStage.REGISTER, 0.5f, 0.99f)
        val outputBookId = registerReadAloud(ebook, outFile)
        sink.onStage(StoryAlignStage.REGISTER, 1f, 1f)

        return Result(outFile.absolutePath, outputBookId, aligned, total)
    }

    private suspend fun downloadEbook(book: Book, sessionDir: File): File {
        val url = aggregator.getEbookDownloadUrl(book.id, book.source, book.connectionId)
            ?: throw IllegalStateException("No ebook download URL for ${book.title}")
        val dest = File(sessionDir, "source.epub")
        val fetch: suspend () -> Unit = {
            okHttpClient.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                if (!resp.isSuccessful) throw IllegalStateException("Ebook download HTTP ${resp.code}")
                val body = resp.body ?: throw IllegalStateException("Empty ebook response")
                body.byteStream().use { input -> dest.outputStream().use { input.copyTo(it) } }
            }
        }
        val scope = book.connectionId?.let { ConnectionScope.asContextElement(it) }
        if (scope != null) withContext(scope) { fetch() } else fetch()
        return dest
    }

    private suspend fun ensureAudioDownloaded(book: Book, onProgress: suspend (Float) -> Unit): List<Track> {
        if (!offlineDownloads.isDownloaded(book.id)) {
            downloadAudio(book, onProgress)
        }
        var manifest = offlineDownloads.getManifest(book.id)
            ?: throw IllegalStateException("Audiobook download did not produce tracks")
        var tracks = manifestTracks(manifest)
        val badTrack = tracks.firstOrNull { !it.file.hasAudioTrack() }
        if (badTrack != null) {
            offlineDownloads.removeDownload(book.id)
            downloadAudio(book, onProgress)
            manifest = offlineDownloads.getManifest(book.id)
                ?: throw IllegalStateException("Audiobook download did not produce tracks")
            tracks = manifestTracks(manifest)
            val retriedBadTrack = tracks.firstOrNull { !it.file.hasAudioTrack() }
            if (retriedBadTrack != null) {
                throw IllegalStateException("Downloaded audio is not playable: ${retriedBadTrack.file.name}")
            }
        }
        return tracks
    }

    private suspend fun downloadAudio(book: Book, onProgress: suspend (Float) -> Unit) {
        offlineDownloads.startAudiobookDownload(book, allowCellular = true)
        val result = offlineDownloads.progressByBookId
            .map { it[book.id] }
            .first { p ->
                if (p != null) onProgress(p.progress)
                p?.status == OfflineDownloadStatus.COMPLETED || p?.status == OfflineDownloadStatus.FAILED
            }
        if (result?.status != OfflineDownloadStatus.COMPLETED) {
            throw IllegalStateException(result?.errorMessage ?: "Audiobook download failed")
        }
    }

    private fun manifestTracks(manifest: com.enve.app.data.offline.OfflineAudioManifest): List<Track> =
        manifest.tracks.sortedBy { it.index }.map { t ->
            Track(t.index, storageFile(t.relativePath), t.durationMs / 1000.0)
        }

    private fun storageFile(relativePath: String): File =
        File(File(context.filesDir, "offline-audio"), relativePath)

    private fun File.hasAudioTrack(): Boolean {
        if (!exists() || length() <= 0L) return false
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(absolutePath)
            (0 until extractor.trackCount).any {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            }
        } catch (_: Exception) {
            false
        } finally {
            extractor.release()
        }
    }

    private suspend fun ensureModel(settings: StoryAlignSettings, onProgress: suspend (Float) -> Unit): File {
        val model = WhisperModelManager.byId(settings.model) ?: WhisperModelManager.TINY_EN
        if (!modelManager.isInstalled(model)) modelManager.download(model) { }
        onProgress(1f)
        return modelManager.modelFile(model)
    }

    private suspend fun transcribe(
        tracks: List<Track>,
        modelFile: File,
        settings: StoryAlignSettings,
        onProgress: suspend (Float) -> Unit,
    ): Transcription = coroutineScope {
        val threads = settings.threadCount ?: DEFAULT_THREADS
        val normalizer = WordNormalizer()
        val ctx = WhisperContext.fromFile(modelFile.absolutePath)
        val segments = ArrayList<TranscriptionSegment>()
        val totalDur = tracks.sumOf { it.durationSec }.coerceAtLeast(1.0)

        val processedMs = AtomicLong(0L)
        val poller = launch {
            var last = -1f
            while (isActive) {
                val p = (processedMs.get() / 1000.0 / totalDur).toFloat().coerceIn(0f, 1f)
                if (p != last) { last = p; onProgress(p) }
                delay(2000)
            }
        }
        try {
            withContext(Dispatchers.Default) {
                var doneDur = 0.0
                for (track in tracks) {

                    val audioFile = AudioFile(track.index, 0.0, track.durationSec, "storyalign/Audio/${track.file.name}")
                    val base = doneDur
                    val buf = FloatArray(WINDOW_SAMPLES)
                    var fill = 0
                    var windowStart = 0.0
                    AudioDecoder().decode(track.file.absolutePath) { chunk, _ ->
                        var i = 0
                        while (i < chunk.size) {
                            val n = minOf(chunk.size - i, WINDOW_SAMPLES - fill)
                            System.arraycopy(chunk, i, buf, fill, n)
                            fill += n
                            i += n
                            if (fill == WINDOW_SAMPLES) {
                                collectWindow(ctx, buf, threads, windowStart, audioFile, segments)
                                windowStart += WINDOW_SECONDS
                                processedMs.set(((base + windowStart) * 1000).toLong())
                                fill = 0
                            }
                        }
                    }
                    if (fill > 0) collectWindow(ctx, buf.copyOf(fill), threads, windowStart, audioFile, segments)
                    doneDur += track.durationSec
                    processedMs.set((doneDur * 1000).toLong())
                }
            }
        } finally {
            poller.cancel()
            ctx.release()
        }
        onProgress(1f)
        TranscriptionBuilder.fromSegments(segments, normalizer)
    }

    private fun collectWindow(
        ctx: WhisperContext,
        pcm: FloatArray,
        threads: Int,
        windowStart: Double,
        audioFile: AudioFile,
        out: MutableList<TranscriptionSegment>,
    ) {
        val rc = ctx.transcribe(pcm, "en", threads)
        check(rc == 0) { "whisper_full failed (rc=$rc)" }
        for (s in 0 until ctx.segmentCount()) {
            val tokens = ArrayList<TranscriptionToken>()
            for (t in 0 until ctx.tokenCount(s)) {
                val text = ctx.tokenText(s, t)
                if (text.isEmpty() || (text.startsWith("[") && text.endsWith("]"))) continue
                tokens.add(TranscriptionToken(text, windowStart + ctx.tokenStartSec(s, t), windowStart + ctx.tokenEndSec(s, t)))
            }
            if (tokens.isEmpty()) continue
            out.add(
                TranscriptionSegment(
                    text = ctx.segmentText(s),
                    start = windowStart + ctx.segmentStartSec(s),
                    end = windowStart + ctx.segmentEndSec(s),
                    audioFile = audioFile,
                    tokens = tokens,
                ),
            )
        }
    }

    private suspend fun registerReadAloud(ebook: Book, outFile: File): String {
        val now = System.currentTimeMillis()

        val out = ebook.copy(
            id = Uri.fromFile(outFile).toString(),
            source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK,
            connectionId = null,
            libraryId = "storyalign-local",
            libraryName = "Read-aloud",
            duration = 0L,
            currentTime = 0L,
            isFinished = false,
            readStatus = ReadStatus.UNREAD,
            readProgress = 0f,
            epubProgress = 0f,
            epubLocator = null,
            lastReadTime = now,
            addedOn = now,
            readAlongAvailable = true,
            hasAudio = true,
            hasEbook = true,
            isDownloaded = true,
            primaryFileType = "epub",
        )
        bookCacheDao.upsert(listOf(out.toCachedBook(now)))
        return out.id
    }

    private fun isoNow(): String {
        val fmt = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
        fmt.timeZone = TimeZone.getTimeZone("UTC")
        return fmt.format(java.util.Date(System.currentTimeMillis()))
    }

    companion object {
        private const val DEFAULT_THREADS = 6
        private const val WINDOW_SECONDS = 300.0
        private const val WINDOW_SAMPLES = (WINDOW_SECONDS * AudioDecoder.TARGET_SAMPLE_RATE).toInt()
    }
}
