package com.enve.app.storyalign.pipeline

import com.enve.app.storyalign.align.AlignedChapter
import com.enve.app.storyalign.align.SentenceAligner
import com.enve.app.storyalign.align.Transcription
import com.enve.app.storyalign.align.WordNormalizer
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.export.ReadAloudEpubBuilder
import com.enve.engine.storyalign.StoryAlignGranularity

fun interface Transcriber {
    suspend fun transcribe(): Transcription
}

class StoryAlignPipeline(
    private val normalizer: WordNormalizer = WordNormalizer(),
) {
    data class Report(
        val totalSentences: Int,
        val alignedSentences: Int,
        val skippedSentences: Int,
    ) {
        val score: Double get() = if (totalSentences == 0) 0.0 else alignedSentences.toDouble() / totalSentences
    }

    data class Result(
        val readAloudEpub: ByteArray,
        val chapters: List<AlignedChapter>,
        val report: Report,
    )

    suspend fun run(
        epub: EpubZip,
        granularity: StoryAlignGranularity,
        transcriber: Transcriber,
        audioClips: List<ReadAloudEpubBuilder.AudioClipFile>,
        modifiedIso: String,
    ): Result {
        val doc = EpubParser.parse(epub, granularity)
        val transcription: Transcription = transcriber.transcribe()
        val chapters = SentenceAligner(normalizer).alignBook(doc.spineOrderedManifest, transcription)
        val bytes = ReadAloudEpubBuilder.build(epub, doc, chapters, audioClips, modifiedIso)
        return Result(bytes, chapters, report(chapters))
    }

    private fun report(chapters: List<AlignedChapter>): Report {
        var aligned = 0
        var skipped = 0
        var total = 0
        for (c in chapters) {
            total += c.manifestItem.xhtmlSentences.size
            aligned += c.alignedSentences.size
            skipped += c.skippedSentences.size
        }
        return Report(total, aligned, skipped)
    }
}
