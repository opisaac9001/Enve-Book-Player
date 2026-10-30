package com.enve.app.storyalign

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.storyalign.align.AlignedChapter
import com.enve.app.storyalign.align.AlignmentDecision
import com.enve.app.storyalign.align.AlignmentRejection
import com.enve.app.storyalign.align.AlignmentQualityEvaluator
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
import com.enve.app.storyalign.export.StoryAlignOutputQuality
import com.enve.app.storyalign.ctc.QuartzNetBookAligner
import com.enve.app.storyalign.ctc.QuartzNetModelStore
import com.enve.engine.storyalign.StoryAlignEngine
import com.enve.engine.storyalign.StoryAlignGranularity
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
import com.enve.app.data.offline.withDownloadCalls
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
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
    private val outputs: StoryAlignOutputStore,
    private val quartzNetModels: QuartzNetModelStore,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    fun interface ProgressSink {
        suspend fun onStage(stage: StoryAlignStage, stageProgress: Float, overallProgress: Float)
    }

    data class Result(val outputPath: String, val outputBookId: String, val report: StoryAlignReport)

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
        sink.onStage(StoryAlignStage.EPUB_PARSE, 0f, 0.02f)
        val epubZip = EpubZip.from(epubFile)
        val doc = EpubParser.parse(epubZip, settings.granularity)
        sink.onStage(StoryAlignStage.EPUB_PARSE, 1f, 0.02f)

        if (settings.engine == StoryAlignEngine.QUARTZNET_CTC) {
            val language = (settings.language ?: doc.metaInfo.language)?.trim()?.lowercase(Locale.ROOT)
                ?.substringBefore('-')?.substringBefore('_')?.takeIf { it.isNotEmpty() }
            require(language == null || language in setOf("en", "eng", "english", "und")) {
                "QuartzNet currently supports English books. Choose Whisper for the existing transcription method."
            }
            require(settings.granularity == StoryAlignGranularity.SENTENCE) {
                "QuartzNet alignment currently supports sentence highlighting."
            }
        }
        val tracks = ensureAudioDownloaded(audiobook) { p ->
            sink.onStage(StoryAlignStage.DOWNLOAD, 0.1f + 0.8f * p, 0.02f + 0.28f * p)
        }
        val modelFile = when (settings.engine) {
            StoryAlignEngine.WHISPER -> ensureModel(settings) { p ->
                sink.onStage(StoryAlignStage.DOWNLOAD, 0.9f + 0.1f * p, 0.30f + 0.05f * p)
            }
            StoryAlignEngine.QUARTZNET_CTC -> {
                quartzNetModels.prepare { p ->
                    sink.onStage(StoryAlignStage.DOWNLOAD, 0.9f + 0.1f * p, 0.30f + 0.05f * p)
                }
            }
        }

        val chapters = when (settings.engine) {
            StoryAlignEngine.WHISPER -> {
                val transcription = transcribe(tracks, modelFile, settings) { p ->
                    sink.onStage(StoryAlignStage.TRANSCRIBE, p, 0.37f + 0.53f * p)
                }
                sink.onStage(StoryAlignStage.ALIGN, 0.2f, 0.90f)
                SentenceAligner().alignBook(doc.spineOrderedManifest, transcription)
            }
            StoryAlignEngine.QUARTZNET_CTC -> {
                QuartzNetBookAligner(context).align(
                    doc.spineOrderedManifest,
                    tracks.map { QuartzNetBookAligner.Track(it.index, it.file, it.durationSec) },
                    modelFile,
                    File(sessionDir, "ctc-checkpoints"),
                ) { p -> sink.onStage(StoryAlignStage.ANALYZE, p, 0.37f + 0.53f * p) }
            }
        }
        val total = chapters.sumOf { it.manifestItem.xhtmlSentences.size }
        val assessment = AlignmentQualityEvaluator.assess(
            chapters,
            tracks.associate { it.index to it.durationSec },
        )
        val retained = outputs.acceptedFile(job.id)
        val incumbent = if (retained.isFile) StoryAlignOutputQuality.read(retained) else null
        val incumbentQuality = incumbent?.metadata
        val stored = StoryAlignReport(
            alignedSentences = incumbent?.clipCount ?: 0,
            totalSentences = incumbentQuality?.eligibleSentenceCount ?: maxOf(total, incumbent?.clipCount ?: 0),
            acceptedQuality = incumbentQuality?.assessment,
        )
        val audioCoverage = (assessment.units.sumOf { it.sentenceRange.duration } /
            tracks.sumOf { it.durationSec }.coerceAtLeast(0.001)).coerceIn(0.0, 1.0)
        val candidateQuality = StoryAlignOutputQuality(assessment.units.size, total, audioCoverage, assessment.quality)
        val cannotReplace = retained.isFile && (incumbent == null ||
            assessment.units.size < incumbent.clipCount ||
            incumbentQuality != null && settings.engine == StoryAlignEngine.QUARTZNET_CTC &&
                (candidateQuality.textCoverage + 0.02 < incumbentQuality.textCoverage ||
                    candidateQuality.audioCoverage + 0.02 < incumbentQuality.audioCoverage))
        val decision = if (cannotReplace) {
            AlignmentDecision(
                accepted = false,
                explanation = "The existing read-aloud book was kept because its alignment is stronger or could not be verified.",
                quality = assessment.quality,
                rejection = AlignmentRejection.INFERIOR_CANDIDATE,
            )
        } else if (settings.engine == StoryAlignEngine.QUARTZNET_CTC &&
            (assessment.quality.coverage < 0.70 || assessment.units.size < 3)
        ) {
            AlignmentDecision(
                accepted = false,
                explanation = "QuartzNet could not confidently align enough of this edition. The previous output was kept if available.",
                quality = assessment.quality,
                rejection = AlignmentRejection.INVALID_CANDIDATE,
            )
        } else {
            AlignmentQualityEvaluator.decide(assessment, incumbentQuality?.assessment)
        }
        sink.onStage(StoryAlignStage.ALIGN, 1f, 0.94f)

        if (!decision.accepted) {
            check(retained.exists()) { decision.explanation }
            return Result(
                retained.absolutePath,
                job.outputBookId ?: registerReadAloud(ebook, retained),
                stored.retaining(decision),
            )
        }

        sink.onStage(StoryAlignStage.EXPORT, 0.2f, 0.95f)
        val clips = tracks.map { ReadAloudEpubBuilder.AudioClipRef(it.file.name, it.file) }
        val candidate = outputs.prepareCandidate(job.id)
        val acceptedUnits = assessment.units.toSet()
        val verifiedChapters = chapters.map { chapter ->
            AlignedChapter(
                manifestItem = chapter.manifestItem,
                transcriptionStartOffset = chapter.transcriptionStartOffset,
                transcriptionEndOffset = chapter.transcriptionEndOffset,
                alignedSentences = chapter.alignedSentences.filter { it in acceptedUnits },
                skippedSentences = chapter.skippedSentences,
            )
        }
        try {
            ReadAloudEpubBuilder.buildToFile(
                candidate, epubZip, doc, verifiedChapters, clips, isoNow(), candidateQuality,
                fullSourceTagging = settings.engine == StoryAlignEngine.QUARTZNET_CTC,
            )
        } catch (error: Exception) {
            outputs.discardCandidate(job.id)
            throw error
        }
        val outFile = outputs.promoteCandidate(job.id)
        sink.onStage(StoryAlignStage.EXPORT, 1f, 0.98f)

        sink.onStage(StoryAlignStage.REGISTER, 0.5f, 0.99f)
        val outputBookId = registerReadAloud(ebook, outFile)
        sink.onStage(StoryAlignStage.REGISTER, 1f, 1f)

        return Result(outFile.absolutePath, outputBookId, stored.installing(decision, total))
    }

    private suspend fun downloadEbook(book: Book, sessionDir: File): File {
        val url = aggregator.getEbookDownloadUrl(book.id, book.source, book.connectionId)
            ?: throw IllegalStateException("No ebook download URL for ${book.title}")
        val dest = File(sessionDir, "source.epub")
        val fetch: suspend () -> Unit = {
            okHttpClient.withDownloadCalls { calls ->
            calls.execute(Request.Builder().url(url).get().build()).use { resp ->
                if (!resp.isSuccessful) throw IllegalStateException("Ebook download HTTP ${resp.code}")
                val body = resp.body ?: throw IllegalStateException("Empty ebook response")
                body.byteStream().use { input ->
                    dest.outputStream().use { output ->
                        val buffer = ByteArray(32_768)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count <= 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                }
            }
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
        File(File(locations.filesDirectory, "offline-audio"), relativePath)

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
                val executionContext = currentCoroutineContext()
                var doneDur = 0.0
                for (track in tracks) {
                    executionContext.ensureActive()
                    val audioFile = AudioFile(track.index, 0.0, track.durationSec, "storyalign/Audio/${track.file.name}")
                    val base = doneDur
                    val buf = FloatArray(WINDOW_SAMPLES)
                    var fill = 0
                    var windowStart = 0.0
                    AudioDecoder().decode(track.file.absolutePath) { chunk, _ ->
                        executionContext.ensureActive()
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
