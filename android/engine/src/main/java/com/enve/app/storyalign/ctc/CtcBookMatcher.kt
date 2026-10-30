package com.enve.app.storyalign.ctc

import com.enve.app.storyalign.align.WordNormalizer
import com.enve.app.storyalign.epub.EpubManifestItem
import java.text.Normalizer
import java.util.Locale
import kotlinx.serialization.Serializable

@Serializable
data class CtcSentenceMatch(
    val sentence: Int,
    val start: Double,
    val end: Double,
    val score: Double,
    val audioIndex: Int,
)

internal data class CtcAnchor(val document: Int, val query: Int, val frame: Int)

class CtcBookMatcher(chapters: List<EpubManifestItem>) {
    data class Sentence(val chapter: Int, val id: Int, val text: String, val start: Int, val end: Int)
    private data class Decoding(val text: String, val frames: IntArray)

    val sentences: List<Sentence>
    val text: String
    private val index: Map<Long, Int>

    init {
        val normalizer = WordNormalizer()
        val combined = StringBuilder()
        val entries = ArrayList<Sentence>()
        chapters.forEachIndexed { chapter, item ->
            item.xhtmlSentences.forEachIndexed { id, sentence ->
                val start = combined.length
                combined.append(normalize(normalizer.normalizeWordsInSentence(sentence)))
                entries.add(Sentence(chapter, id, sentence, start, combined.length))
            }
        }
        sentences = entries
        text = combined.toString()
        val offsets = HashMap<Long, Int>()
        for (offset in 0..text.length - NGRAM) {
            val hash = hash(text, offset)
            if (hash and 3L != 0L) continue
            offsets[hash] = if (offsets.containsKey(hash)) -1 else offset
        }
        index = offsets
    }

    fun match(
        emissions: CtcEmissions,
        windowStart: Double,
        audioIndex: Int,
        duration: Double,
        checkCancellation: () -> Unit,
    ): List<CtcSentenceMatch> {
        val decoding = decode(emissions)
        val anchors = ArrayList<CtcAnchor>()
        for (query in 0..decoding.text.length - NGRAM) {
            val document = index[hash(decoding.text, query)] ?: continue
            if (document < 0 || !text.regionMatches(document, decoding.text, query, NGRAM)) continue
            anchors.add(CtcAnchor(document, query, decoding.frames[query]))
        }
        if (anchors.size < 3) return emptyList()
        val buckets = anchors.groupBy { Math.floorDiv(it.document - it.query, 48) }
        val best = buckets.keys.maxByOrNull { bucket ->
            buckets[bucket].orEmpty().size + buckets[bucket - 1].orEmpty().size + buckets[bucket + 1].orEmpty().size
        } ?: return emptyList()
        val candidates = (buckets[best - 1].orEmpty() + buckets[best].orEmpty() + buckets[best + 1].orEmpty())
            .sortedBy { it.query }
        val chain = longestAnchorChain(candidates)
        if (chain.size < 3 || chain.last().document - chain.first().document < 24) return emptyList()
        val offsets = chain.map { it.document - it.query }.sorted()
        val estimatedStart = offsets[offsets.size / 2]
        val estimatedEnd = estimatedStart + decoding.text.length
        val eligible = sentences.withIndex().filter { (_, sentence) ->
            sentence.end > sentence.start && sentence.start >= maxOf(0, estimatedStart - 16) && sentence.end <= estimatedEnd + 16
        }
        if (eligible.isEmpty()) return emptyList()
        val targetStart = eligible.first().value.start
        val targetEnd = eligible.last().value.end
        if (targetEnd - targetStart > 1_600) return emptyList()
        val frameStart = 0
        val frameEnd = emissions.frames
        if (frameEnd <= frameStart) return emptyList()
        val values = emissions.values.copyOfRange(frameStart * emissions.classes, frameEnd * emissions.classes)
        val section = CtcEmissions(values, frameEnd - frameStart, emissions.classes, emissions.blank, emissions.secondsPerFrame)
        val labels = text.substring(targetStart, targetEnd).map(::label).toIntArray()
        val timings = CtcForcedAligner.align(section, labels, checkCancellation) ?: return emptyList()
        val result = ArrayList<CtcSentenceMatch>()
        for ((globalId, sentence) in eligible) {
            checkCancellation()
            val from = sentence.start - targetStart
            val until = sentence.end - targetStart
            val tokens = timings.subList(from, until)
            val score = tokens.map { it.logProbability }.average()
            val reliable = tokens.count { it.logProbability >= -4.0 }.toDouble() / tokens.size
            if (score < -3.0 || reliable < 0.9) continue
            if (windowStart > 0 && tokens.first().startFrame < 3) continue
            val windowEnd = windowStart + emissions.frames * emissions.secondsPerFrame
            if (windowEnd < duration - 0.1 && tokens.last().endFrame >= section.frames - 3) continue
            if (tokens.zipWithNext().any { (a, b) -> b.startFrame - a.endFrame > 150 }) continue
            val start = maxOf(0.0, windowStart + (frameStart + tokens.first().startFrame) * emissions.secondsPerFrame - 0.28)
            val end = minOf(duration, windowStart + (frameStart + tokens.last().endFrame) * emissions.secondsPerFrame - 0.12)
            val words = sentence.text.split(Regex("\\s+")).count { it.any(Char::isLetterOrDigit) }
            if (end <= start || end - start > maxOf(8.0, words * 2.0) || end - start < words * 0.06) continue
            result.add(CtcSentenceMatch(globalId, start, end, score, audioIndex))
        }
        return result
    }

    private fun decode(emissions: CtcEmissions): Decoding {
        val text = StringBuilder()
        val frames = ArrayList<Int>()
        var previous = -1
        for (frame in 0 until emissions.frames) {
            val row = frame * emissions.classes
            var best = 0
            for (column in 1 until emissions.classes) {
                if (emissions.values[row + column] > emissions.values[row + best]) best = column
            }
            if (best != previous && best != emissions.blank && best in 1..27) {
                text.append(if (best == 27) '\'' else 'a' + best - 1)
                frames.add(frame)
            }
            previous = best
        }
        return Decoding(text.toString(), frames.toIntArray())
    }

    companion object {
        private const val NGRAM = 12

        internal fun longestAnchorChain(anchors: List<CtcAnchor>): List<CtcAnchor> {
            if (anchors.isEmpty()) return emptyList()
            val tails = ArrayList<Int>()
            val predecessor = IntArray(anchors.size) { -1 }
            for (index in anchors.indices) {
                val position = anchors[index].document
                var low = 0
                var high = tails.size
                while (low < high) {
                    val middle = (low + high) / 2
                    if (anchors[tails[middle]].document < position) low = middle + 1 else high = middle
                }
                if (low > 0) predecessor[index] = tails[low - 1]
                if (low == tails.size) tails.add(index) else tails[low] = index
            }
            val chain = ArrayList<CtcAnchor>(tails.size)
            var cursor = tails.last()
            while (cursor >= 0) {
                chain.add(anchors[cursor])
                cursor = predecessor[cursor]
            }
            chain.reverse()
            return chain
        }

        internal fun normalize(text: String): String =
            Normalizer.normalize(text.replace('\u2019', '\''), Normalizer.Form.NFD)
                .lowercase(Locale.ROOT).filter { it in 'a'..'z' || it == '\'' }

        private fun label(character: Char): Int = if (character == '\'') 27 else character - 'a' + 1

        private fun hash(text: String, offset: Int): Long {
            var value = 1L
            for (index in offset until offset + NGRAM) value = value * 31 + text[index].code
            return value
        }
    }
}
