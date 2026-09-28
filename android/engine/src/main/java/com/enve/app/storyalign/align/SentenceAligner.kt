package com.enve.app.storyalign.align

import com.enve.app.storyalign.epub.EpubManifestItem

class SentenceAligner(
    private val normalizer: WordNormalizer = WordNormalizer(),
    private val fuzzy: FuzzySearcher = FuzzySearcher(),
    private val anchors: AnchorAligner = AnchorAligner(),
) {
    data class ChapterAlignment(
        val alignedSentences: List<AlignedSentence>,
        val skippedSentences: List<SkippedSentence>,
        val endOffset: Int,
    )

    fun alignChapter(
        xhtmlSentences: List<String>,
        transcription: Transcription,
        startCharOffset: Int,
    ): ChapterAlignment {
        val refTokens = ArrayList<String>()
        val refSentenceIds = ArrayList<Int>()
        xhtmlSentences.forEachIndexed { sentenceId, sentence ->
            sentenceTokens(sentence).forEach { token ->
                val comparable = comparableToken(token)
                if (comparable.isNotEmpty()) {
                    refTokens.add(comparable)
                    refSentenceIds.add(sentenceId)
                }
            }
        }

        val timeline = transcription.wordTimeline
        if (refTokens.isEmpty() || timeline.isEmpty()) {
            return ChapterAlignment(emptyList(), skippedSentences(xhtmlSentences, emptySet()), startCharOffset)
        }

        val firstWord = transcription
            .wordIndexAtOffset(startCharOffset.coerceIn(0, transcription.text.length))
            ?: 0
        val lastWord = minOf(timeline.size, firstWord + refTokens.size * HYP_WINDOW_FACTOR + HYP_WINDOW_SLACK)
        if (firstWord >= lastWord) {
            return ChapterAlignment(emptyList(), skippedSentences(xhtmlSentences, emptySet()), startCharOffset)
        }
        val hypTokens = timeline.subList(firstWord, lastWord).map { comparableToken(it.token) }

        val matches = anchors.align(refTokens, hypTokens)
        val matched = ArrayList<AlignedSentence>()
        var cursor = 0
        while (cursor < refTokens.size) {
            val sentenceId = refSentenceIds[cursor]
            var sentenceEnd = cursor
            while (sentenceEnd < refTokens.size && refSentenceIds[sentenceEnd] == sentenceId) sentenceEnd++

            val hits = (cursor until sentenceEnd).map { matches[it] }.filter { it != AnchorAligner.UNMATCHED }
            if (hits.isNotEmpty()) {
                val startWord = firstWord + hits.min()
                val endWord = firstWord + hits.max()
                val audioFile = timeline[startWord].audioFile
                val stamps = timeline.subList(startWord, endWord + 1)
                    .takeWhile { it.audioFile == audioFile }
                    .toList()
                if (stamps.isNotEmpty()) {
                    var start = stamps.first().start
                    val end = maxOf(stamps.last().end, start)

                    val previous = matched.lastOrNull()
                    if (previous != null &&
                        previous.sentenceId == sentenceId - 1 &&
                        previous.sentenceRange.audioFile == audioFile
                    ) {
                        val gap = start - previous.sentenceRange.end
                        if (gap > 0) {
                            start -= gap / 2
                            previous.sentenceRange.end = start
                        }
                    }

                    val range = SentenceRange(sentenceId, start, maxOf(end, start), audioFile, stamps)
                    val complete = hits.size == sentenceEnd - cursor
                    matched.add(
                        AlignedSentence(
                            xhtmlSentences[sentenceId],
                            sentenceId,
                            range,
                            stamps.joinToString(" ") { it.token },
                            timeline[startWord].startOffset,
                            if (complete) SentenceMatchType.EXACT else SentenceMatchType.NEAREST,
                        ),
                    )
                }
            }
            cursor = sentenceEnd
        }

        val withInterpolated = interpolate(matched, xhtmlSentences)
        val filledIds = withInterpolated.map { it.sentenceId }.toSet()
        val lastMatchedWord = matches.filter { it != AnchorAligner.UNMATCHED }.maxOrNull()
        val endOffset = lastMatchedWord
            ?.let { timeline.getOrNull(firstWord + it)?.endOffset }
            ?: startCharOffset
        return ChapterAlignment(withInterpolated, skippedSentences(xhtmlSentences, filledIds), endOffset)
    }

    private fun sentenceTokens(sentence: String): List<String> =
        normalizeQuery(sentence).split(' ').filter { it.isNotBlank() }

    private fun comparableToken(token: String): String =
        buildString { token.forEach { if (it.isLetterOrDigit()) append(it.lowercaseChar()) } }

    private fun skippedSentences(xhtmlSentences: List<String>, filledIds: Set<Int>): List<SkippedSentence> =
        xhtmlSentences.mapIndexedNotNull { id, sentence ->
            if (id in filledIds || normalizeQuery(sentence).isBlank()) null else SkippedSentence(sentence, id)
        }

    private fun normalizeQuery(sentence: String): String =
        normalizer.normalizeWordsInSentence(sentence).trim().replace(Regex("\\s+"), " ").lowercase()

    private fun interpolate(matched: List<AlignedSentence>, xhtmlSentences: List<String>): List<AlignedSentence> {
        if (matched.isEmpty()) return matched
        val out = ArrayList<AlignedSentence>()
        var last: AlignedSentence? = null
        for (cur in matched) {
            val prev = last
            if (prev != null) {
                val missingCount = cur.sentenceId - prev.sentenceId - 1
                val sameFile = cur.sentenceRange.audioFile == prev.sentenceRange.audioFile
                val diff = cur.sentenceRange.start - prev.sentenceRange.end
                if (missingCount > 0 && sameFile && diff > 0) {
                    val missing = (prev.sentenceId + 1 until cur.sentenceId).map { it to xhtmlSentences[it] }
                    val totalV = missing.sumOf { normalizer.normalizeWordsInSentence(it.second).voiceLength() }.coerceAtLeast(1e-6)
                    var t = prev.sentenceRange.end
                    for ((id, sentence) in missing) {
                        val v = normalizer.normalizeWordsInSentence(sentence).voiceLength()
                        val dur = diff * (v / totalV)
                        val s = t
                        val e = t + dur
                        t = e
                        val range = SentenceRange(id, s, e, cur.sentenceRange.audioFile, emptyList())
                        out.add(AlignedSentence(sentence, id, range, matchType = SentenceMatchType.INTERPOLATED))
                    }
                }
            }
            out.add(cur)
            last = cur
        }
        return out
    }

    fun alignBook(chapters: List<EpubManifestItem>, transcription: Transcription): List<AlignedChapter> {
        val ngram = NGramIndex(transcription.text, ngramSize = 6)
        var searchFrom = 0
        val result = ArrayList<AlignedChapter>()
        for (chapter in chapters) {
            val sentences = chapter.xhtmlSentences
            if (sentences.isEmpty()) {
                result.add(AlignedChapter(chapter))
                continue
            }
            val startOffset = findChapterStart(sentences, transcription, ngram, searchFrom) ?: searchFrom
            val ca = alignChapter(sentences, transcription, startOffset)
            result.add(
                AlignedChapter(
                    manifestItem = chapter,
                    transcriptionStartOffset = startOffset,
                    transcriptionEndOffset = ca.endOffset,
                    alignedSentences = ca.alignedSentences,
                    skippedSentences = ca.skippedSentences,
                ),
            )
            if (ca.endOffset > searchFrom) searchFrom = ca.endOffset
        }
        return result
    }

    private fun findChapterStart(
        sentences: List<String>,
        transcription: Transcription,
        ngram: NGramIndex,
        afterOffset: Int,
    ): Int? {

        val probe = sentences.take(6).joinToString(" ") { normalizeQuery(it) }.trim()
        if (probe.length < MIN_FUZZY_LEN) return null
        val candidates = ngram.candidates(probe).filter { it >= afterOffset }
        if (candidates.isNotEmpty()) return candidates.first()

        val window = transcription.text.substring(afterOffset.coerceIn(0, transcription.text.length))
        val maxDist = maxOf((probe.length * 0.1).toInt(), 1)
        return fuzzy.findNearestMatch(probe, window, maxDist)?.let { afterOffset + it.second }
    }

    companion object {
        private const val HYP_WINDOW_FACTOR = 3
        private const val HYP_WINDOW_SLACK = 400
        private const val MIN_FUZZY_LEN = 8
    }
}
