package com.enve.app.storyalign.align

import com.enve.app.storyalign.epub.EpubManifestItem
import com.enve.app.storyalign.epub.Tokenizer

enum class SentenceMatchType {
    EXACT,
    TRIMMED_LEADING,
    IGNORING_ENDS_PUNCTUATION,
    IGNORING_ALL_PUNCTUATION,
    NEAREST,
    INTERPOLATED,
    RECOVERABLE,
}

class SentenceRange(
    val id: Int,
    var start: Double,
    var end: Double,
    val audioFile: AudioFile,
    val timeStamps: List<WordTimeStamp>,
) {
    val duration: Double get() = end - start
    val absoluteStart: Double get() = audioFile.startTime + start
    val absoluteEnd: Double get() = audioFile.startTime + end
    val sentenceText: String
        get() = timeStamps.joinToString(" ") { it.token }.replace(Regex("\\s+"), " ").trim()
}

data class SkippedSentence(
    val chapterSentence: String,
    val chapterSentenceId: Int,
)

class AlignedSentence(
    val xhtmlSentence: String,
    val sentenceId: Int,
    val sentenceRange: SentenceRange,
    val matchText: String? = null,
    val matchOffset: Int? = null,
    val matchType: SentenceMatchType? = null,
) {
    val xhtmlSentenceWords: List<String> get() = Tokenizer().tokenizeWords(xhtmlSentence)
    val normalizedSentence: String get() = WordNormalizer().normalizeWordsInSentence(xhtmlSentence)
    val secondsPerWord: Double
        get() = if (xhtmlSentenceWords.isEmpty()) 0.0 else sentenceRange.duration / xhtmlSentenceWords.size
}

class AlignedChapter(
    val manifestItem: EpubManifestItem,
    val transcriptionStartOffset: Int? = null,
    val transcriptionEndOffset: Int? = null,
    val alignedSentences: List<AlignedSentence> = emptyList(),
    val skippedSentences: List<SkippedSentence> = emptyList(),
) {
    val isEmpty: Boolean
        get() = alignedSentences.isEmpty() && skippedSentences.isEmpty() && transcriptionEndOffset == null

    val allSentenceRanges: List<SentenceRange> get() = alignedSentences.map { it.sentenceRange }

    val missingSentences: List<String>
        get() {
            val skippedIds = skippedSentences.map { it.chapterSentenceId }.toSet()
            val alignedIds = alignedSentences.map { it.sentenceId }.toSet()
            return manifestItem.xhtmlSentences.mapIndexedNotNull { index, sentence ->
                if (index in alignedIds || index in skippedIds) null else sentence
            }
        }
}
