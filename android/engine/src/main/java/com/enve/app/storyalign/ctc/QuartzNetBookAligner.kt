package com.enve.app.storyalign.ctc

import android.content.Context
import android.os.Build
import android.os.PowerManager
import com.enve.app.storyalign.align.AlignedChapter
import com.enve.app.storyalign.align.AlignedSentence
import com.enve.app.storyalign.align.AudioFile
import com.enve.app.storyalign.align.SentenceMatchType
import com.enve.app.storyalign.align.SentenceRange
import com.enve.app.storyalign.align.SkippedSentence
import com.enve.app.storyalign.align.WordTimeStamp
import com.enve.app.storyalign.audio.AudioDecoder
import com.enve.app.storyalign.epub.EpubManifestItem
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

class QuartzNetBookAligner(
    private val context: Context,
    private val overlapSeconds: Int = 12,
    private val intraOpThreads: Int = 2,
) {
    init {
        require(overlapSeconds in 2..12 && intraOpThreads in 1..2)
    }
    data class Track(val index: Int, val file: File, val duration: Double)

    suspend fun align(
        chapters: List<EpubManifestItem>,
        tracks: List<Track>,
        modelDirectory: File,
        checkpointDirectory: File,
        onProgress: suspend (Float) -> Unit,
    ): List<AlignedChapter> = INFERENCE_MUTEX.withLock { coroutineScope {
        val completedMillis = AtomicLong()
        val total = tracks.sumOf { it.duration }.coerceAtLeast(1.0)
        val poller = launch {
            while (isActive) {
                onProgress((completedMillis.get() / 1_000.0 / total).toFloat().coerceIn(0f, 1f))
                delay(1_000)
            }
        }
        try {
            withContext(Dispatchers.Default) {
                val execution = currentCoroutineContext()
                val check = { execution.ensureActive() }
                val matcher = CtcBookMatcher(chapters)
                val identity = buildString {
                    append(ALGORITHM)
                    if (overlapSeconds != 12) append(":38:").append(overlapSeconds)
                    append(QuartzNetModelStore.MODEL_ID)
                    chapters.forEach { chapter ->
                        append(chapter.href).append('\u0000')
                        chapter.xhtmlSentences.forEach { append(it).append('\u0000') }
                    }
                }
                val fingerprint = MessageDigest.getInstance("SHA-256")
                    .digest(identity.toByteArray())
                    .joinToString("") { "%02x".format(it) }
                val accepted = HashMap<Int, CtcSentenceMatch>()
                var offset = 0.0
                QuartzNetSession(modelDirectory, intraOpThreads = intraOpThreads).use { model ->
                    for (track in tracks) {
                        check()
                        val trackDigest = track.file.ctcSha256(check)
                        val checkpoints = File(checkpointDirectory, "$fingerprint-$trackDigest").apply { mkdirs() }
                        var precedingSamples: FloatArray? = null
                        var precedingStart = 0L
                        var precedingEmissions: CtcEmissions? = null
                        suspend fun process(window: CtcPcmWindow) {
                            val samples = window.samples
                            val startSample = window.startSample
                            check()
                            val checkpoint = File(checkpoints, "$startSample-${samples.size}.json")
                            var currentEmissions: CtcEmissions? = null
                            val matches = readCheckpoint(checkpoint, track.index) ?: run {
                                waitForThermalHeadroom(check)
                                val emissions = model.analyze(samples)
                                currentEmissions = emissions
                                check()
                                val current = CtcEmissionWindow(emissions, startSample.toDouble() / SAMPLE_RATE, samples.size.toDouble() / SAMPLE_RATE)
                                val previous = precedingSamples
                                val stitched = if (previous == null) current else {
                                    val previousEmissions = precedingEmissions ?: run {
                                        waitForThermalHeadroom(check)
                                        model.analyze(previous)
                                    }
                                    check()
                                    CtcEmissionStitcher.stitch(
                                        CtcEmissionWindow(previousEmissions, precedingStart.toDouble() / SAMPLE_RATE, previous.size.toDouble() / SAMPLE_RATE),
                                        current,
                                    )
                                }
                                val value = matcher.match(stitched.emissions, stitched.start, track.index, track.duration, check)
                                writeCheckpoint(checkpoint, value)
                                value
                            }
                            precedingSamples = samples
                            precedingStart = startSample
                            precedingEmissions = currentEmissions
                            for (match in matches) {
                                val previous = accepted[match.sentence]
                                if (previous == null || match.score > previous.score) accepted[match.sentence] = match
                            }
                            completedMillis.set(((offset + startSample.toDouble() / SAMPLE_RATE + samples.size.toDouble() / SAMPLE_RATE) * 1_000).toLong())
                        }
                        CtcPcmWindowStream.consume(
                            WINDOW_SAMPLES,
                            WINDOW_SAMPLES - overlapSeconds * SAMPLE_RATE,
                            decode = { sink ->
                                val decoding = currentCoroutineContext()
                                AudioDecoder().decode(track.file.absolutePath, checkCancellation = { decoding.ensureActive() }) { samples, _ -> sink(samples) }
                            },
                            consume = ::process,
                        )
                        offset += track.duration
                        completedMillis.set((offset * 1_000).toLong())
                    }
                }
                val files = tracks.associate { track ->
                    track.index to AudioFile(track.index, 0.0, track.duration, "storyalign/Audio/${track.file.name}")
                }
                val consistent = CtcSentenceSelector.select(accepted.values, check).associateBy { it.sentence }
                val byChapter = matcher.sentences.withIndex().groupBy { it.value.chapter }
                chapters.mapIndexed { index, chapter ->
                    val aligned = ArrayList<AlignedSentence>()
                    val skipped = ArrayList<SkippedSentence>()
                    for ((globalId, sentence) in byChapter[index].orEmpty()) {
                        val match = consistent[globalId]
                        if (match == null) {
                            skipped.add(SkippedSentence(sentence.text, sentence.id))
                            continue
                        }
                        val audio = files.getValue(match.audioIndex)
                        val timing = WordTimeStamp(sentence.text, match.start, match.end, audio, 0, 0, sentence.text.length)
                        val range = SentenceRange(sentence.id, match.start, match.end, audio, listOf(timing))
                        aligned.add(AlignedSentence(sentence.text, sentence.id, range, matchType = SentenceMatchType.EXACT))
                    }
                    AlignedChapter(chapter, alignedSentences = aligned, skippedSentences = skipped)
                }
            }.also { onProgress(1f) }
        } finally {
            poller.cancel()
        }
    } }

    private fun waitForThermalHeadroom(check: () -> Unit) {
        if (Build.VERSION.SDK_INT < 29) return
        val power = context.getSystemService(PowerManager::class.java)
        while (power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE) {
            check()
            Thread.sleep(250)
        }
    }

    private fun readCheckpoint(file: File, audioIndex: Int): List<CtcSentenceMatch>? {
        if (!file.isFile) return null
        val checkpoint = try {
            Json.decodeFromString<Checkpoint>(file.readText())
        } catch (_: java.io.IOException) {
            return null
        } catch (_: kotlinx.serialization.SerializationException) {
            return null
        }
        if (checkpoint.algorithm != ALGORITHM || checkpoint.matches.any {
                it.audioIndex != audioIndex || !it.start.isFinite() || !it.end.isFinite() || !it.score.isFinite() || it.end <= it.start
            }) return null
        return checkpoint.matches
    }

    private fun writeCheckpoint(file: File, matches: List<CtcSentenceMatch>) {
        val partial = File(file.parentFile, file.name + ".part")
        partial.writeText(Json.encodeToString(Checkpoint(ALGORITHM, matches)))
        check(partial.renameTo(file)) { "Could not save alignment checkpoint" }
    }

    @Serializable
    private data class Checkpoint(val algorithm: String, val matches: List<CtcSentenceMatch>)

    companion object {
        private val INFERENCE_MUTEX = Mutex()
        private const val ALGORITHM = "ctc-sentences-v4"
        private const val SAMPLE_RATE = 16_000
        private const val WINDOW_SAMPLES = 38 * SAMPLE_RATE
    }
}
