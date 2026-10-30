package com.enve.app.storyalign

import android.media.MediaMetadataRetriever
import android.os.Debug
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.storyalign.align.AlignmentQualityEvaluator
import com.enve.app.storyalign.ctc.QuartzNetBookAligner
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.export.ReadAloudEpubBuilder
import com.enve.app.storyalign.export.StoryAlignOutputQuality
import com.enve.engine.storyalign.StoryAlignGranularity
import java.io.File
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class CtcAlignmentInstrumentedTest {
    @Test
    fun alignProvidedBookWithoutTranscription() = runBlocking {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("ctcEpub") != null && args.getString("ctcAudio") != null && args.getString("ctcModelDirectory") != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val source = File(checkNotNull(args.getString("ctcEpub")))
        val audio = File(checkNotNull(args.getString("ctcAudio")))
        val model = File(checkNotNull(args.getString("ctcModelDirectory")))
        val output = File(args.getString("ctcOutputDirectory") ?: File(context.cacheDir, "ctc-verification").absolutePath)
        output.mkdirs()
        assertTrue(source.isFile && audio.isFile && File(model, "model.onnx").isFile)
        val retriever = MediaMetadataRetriever()
        val duration = try {
            retriever.setDataSource(audio.absolutePath)
            checkNotNull(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)).toDouble() / 1_000
        } finally {
            retriever.release()
        }
        val epub = EpubZip.from(source)
        val document = EpubParser.parse(epub, StoryAlignGranularity.SENTENCE)
        val started = SystemClock.elapsedRealtime()
        val overlapSeconds = args.getString("ctcOverlapSeconds")?.toInt() ?: 12
        val threads = args.getString("ctcThreads")?.toInt() ?: 2
        val chapters = QuartzNetBookAligner(context, overlapSeconds, threads).align(
            document.spineOrderedManifest,
            listOf(QuartzNetBookAligner.Track(0, audio, duration)),
            model,
            File(output, "checkpoints"),
        ) { }
        val analysisMillis = SystemClock.elapsedRealtime() - started
        val assessment = AlignmentQualityEvaluator.assess(chapters, mapOf(0 to duration))
        val acceptedUnits = assessment.units.toSet()
        val generated = File(output, "aligned.epub")
        val qualityAccepted = assessment.quality.isUsable && assessment.quality.coverage >= 0.70 && assessment.units.size >= 3
        if (qualityAccepted) {
            val verified = chapters.map { chapter ->
                com.enve.app.storyalign.align.AlignedChapter(
                    chapter.manifestItem,
                    alignedSentences = chapter.alignedSentences.filter { it in acceptedUnits },
                    skippedSentences = chapter.skippedSentences,
                )
            }
            ReadAloudEpubBuilder.buildToFile(
                generated, epub, document, verified,
                listOf(ReadAloudEpubBuilder.AudioClipRef(audio.name, audio)),
                "2026-10-20T00:00:00Z",
                StoryAlignOutputQuality(
                    assessment.units.size,
                    document.spineOrderedManifest.sumOf { it.xhtmlSentences.size },
                    (assessment.units.sumOf { it.sentenceRange.duration } / duration).coerceIn(0.0, 1.0),
                    assessment.quality,
                ),
                fullSourceTagging = true,
            )
            assertTrue(StoryAlignOutputQuality.read(generated)?.metadata?.acceptedSentenceCount == assessment.units.size)
        }
        val report = JSONObject()
            .put("engine", "quartznet-ctc")
            .put("overlapSeconds", overlapSeconds)
            .put("intraOpThreads", threads)
            .put("audioSeconds", duration)
            .put("analysisMillis", analysisMillis)
            .put("totalMillis", SystemClock.elapsedRealtime() - started)
            .put("alignedSentences", assessment.units.size)
            .put("totalSentences", document.spineOrderedManifest.sumOf { it.xhtmlSentences.size })
            .put("coverage", assessment.quality.coverage)
            .put("monotonicity", assessment.quality.monotonicity)
            .put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
            .put("qualityAccepted", qualityAccepted)
            .put("outputBytes", generated.length())
            .put("ranges", JSONArray(chapters.flatMap { chapter ->
                chapter.alignedSentences.filter { it in acceptedUnits }.map { sentence ->
                    JSONObject()
                        .put("chapterId", chapter.manifestItem.id)
                        .put("sentenceId", sentence.sentenceId)
                        .put("start", sentence.sentenceRange.start)
                        .put("end", sentence.sentenceRange.end)
                }
            }))
        File(output, "report.json").writeText(report.toString(2))
        assertTrue("No acoustically supported sentences found; see report.json", assessment.units.isNotEmpty())
    }
}
