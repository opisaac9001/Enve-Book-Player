package com.enve.app.storyalign.align

import com.enve.app.storyalign.epub.EpubManifestItem

class SentenceAligner(
    private val normalizer: WordNormalizer = WordNormalizer(),
    private val fuzzy: FuzzySearcher = FuzzySearcher(),
) {
    data class ChapterAlignment(
        val alignedSentences: List<AlignedSentence>,
        val skippedSentences: List<SkippedSentence>,
        val endOffset: Int,
    )

    private data class Located(val index: Int, val length: Int, val type: SentenceMatchType, val text: String)

    fun alignChapter(
        xhtmlSentences: List<String>,
        transcription: Transcription,
        startCharOffset: Int,
    ): ChapterAlignment {
        val text = transcription.text
        var offset = startCharOffset.coerceIn(0, text.length)
        val matched = ArrayList<AlignedSentence>()

        for ((sentenceId, sentence) in xhtmlSentences.withIndex()) {
            val query = normalizeQuery(sentence)
            if (query.isBlank()) continue
            val located = locate(query, text, offset) ?: continue

            val matchStart = located.index
            val matchEnd = located.index + located.length
            val startWordIdx = transcription.wordIndexAtOffset(matchStart) ?: continue
            val endWordIdx = (transcription.wordIndexAtOffset((matchEnd - 1).coerceAtLeast(matchStart)) ?: startWordIdx)
                .coerceAtLeast(startWordIdx)
            val stamps = transcription.wordTimeline.subList(startWordIdx, endWordIdx + 1).toList()
            if (stamps.isEmpty()) continue

            val audioFile = stamps.first().audioFile
            var start = stamps.first().start
            val end = maxOf(stamps.last().end, start)

            val prevAligned = matched.lastOrNull()
            if (prevAligned != null &&
                prevAligned.sentenceId == sentenceId - 1 &&
                prevAligned.sentenceRange.audioFile == audioFile
            ) {
                val gap = start - prevAligned.sentenceRange.end
                if (gap > 0) {
                    start -= gap / 2
                    prevAligned.sentenceRange.end = start
                }
            }

            val range = SentenceRange(sentenceId, start, maxOf(end, start), audioFile, stamps)
            matched.add(AlignedSentence(sentence, sentenceId, range, located.text, located.index, located.type))
            offset = matchEnd
        }

        val withInterpolated = interpolate(matched, xhtmlSentences)

        val filledIds = withInterpolated.map { it.sentenceId }.toSet()
        val skipped = xhtmlSentences.mapIndexedNotNull { id, s ->
            if (id in filledIds || normalizeQuery(s).isBlank()) null else SkippedSentence(s, id)
        }
        return ChapterAlignment(withInterpolated, skipped, offset)
    }

    private fun normalizeQuery(sentence: String): String =
        normalizer.normalizeWordsInSentence(sentence).trim().replace(Regex("\\s+"), " ").lowercase()

    private fun locate(query: String, text: String, offset: Int): Located? {
        if (offset >= text.length) return null
        val windowSize = maxOf(query.length * WINDOW_FACTOR, MIN_WINDOW)
        val windowEnd = minOf(offset + windowSize, text.length)
        val window = text.substring(offset, windowEnd)

        val lead = window.indexOfFirst { !it.isWhitespace() }.let { if (it < 0) 0 else it }
        val anchored = window.substring(lead)
        if (anchored.startsWith(query)) {
            val type = if (lead == 0) SentenceMatchType.EXACT else SentenceMatchType.TRIMMED_LEADING
            return Located(offset + lead, query.length, type, query)
        }

        stripPunct(anchored).let { stripped ->
            val strippedQuery = stripPunct(query)
            if (strippedQuery.isNotEmpty() && stripped.startsWith(strippedQuery)) {
                val consumed = consumeToStrippedLength(anchored, strippedQuery.length)
                if (consumed > 0) {
                    return Located(offset + lead, consumed, SentenceMatchType.IGNORING_ALL_PUNCTUATION, anchored.substring(0, consumed))
                }
            }
        }

        if (query.length >= MIN_FUZZY_LEN) {
            val maxDist = maxOf((query.length * 0.1).toInt(), 1)
            fuzzy.findNearestMatch(query, window, maxDist)?.let { (matchStr, idx) ->
                if (matchStr.isNotEmpty()) return Located(offset + idx, matchStr.length, SentenceMatchType.NEAREST, matchStr)
            }
        }
        return null
    }

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

    private fun stripPunct(s: String): String =
        buildString { for (c in s) if (c.isLetterOrDigit() || c == ' ') append(c) }

    private fun consumeToStrippedLength(source: String, strippedLen: Int): Int {
        var consumedStripped = 0
        var i = 0
        while (i < source.length && consumedStripped < strippedLen) {
            val c = source[i]
            if (c.isLetterOrDigit() || c == ' ') consumedStripped++
            i++
        }
        return i
    }

    companion object {
        private const val WINDOW_FACTOR = 6
        private const val MIN_WINDOW = 200
        private const val MIN_FUZZY_LEN = 8
    }
}
