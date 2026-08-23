package com.enve.app.storyalign.align

data class Match(val start: Int, val end: Int, val dist: Int)
private data class ExpandResult(val score: Int, val index: Int)

class FuzzySearcher {

    fun findNearestMatch(needle: String, haystack: String, maxDist: Int): Pair<String, Int>? {
        val candidates = levenshteinNgram(needle, haystack, maxDist)
        val nearest = candidates.minByOrNull { it.dist } ?: return null
        return haystack.substring(nearest.start, nearest.end) to nearest.start
    }

    private fun reverseSlice(str: String, from: Int, to: Int = 0): String =
        str.substring(to, from).reversed()

    private fun searchExact(subsequence: String, hay: CharArray, startIndex: Int, endIndex: Int?): List<Int> {
        val ned = subsequence
        val hCount = hay.size
        val nCount = ned.length
        val e = endIndex ?: hCount
        if (!(nCount > 0 && startIndex >= 0 && e <= hCount && nCount <= e - startIndex)) return emptyList()
        val skip = HashMap<Char, Int>()
        for (i in 0 until nCount - 1) skip[ned[i]] = nCount - i - 1
        val results = ArrayList<Int>()
        var i = startIndex
        while (i <= e - nCount) {
            var j = nCount - 1
            while (j >= 0 && hay[i + j] == ned[j]) j--
            if (j < 0) {
                results.add(i)
                i += 1
            } else {
                val shift = skip[hay[i + nCount - 1]] ?: nCount
                i += shift
            }
        }
        return results
    }

    private fun expand(subsequence: String, sequence: String, maxDist: Int): ExpandResult? {
        val needle = subsequence
        val n = needle.length
        if (n == 0) return ExpandResult(0, 0)
        val scores = IntArray(n + 1) { it }
        var minScore = n
        var minIndex = -1
        var maxGood = maxDist
        var rangeStart: Int? = 0
        var rangeEnd = n - 1

        for (i in 0 until sequence.length) {
            val c0 = i + 1
            val start = rangeStart ?: break
            val end = minOf(n, rangeEnd + 1)
            var a = i
            var c = c0
            if (c <= maxGood) {
                rangeStart = 0
                rangeEnd = 0
            } else {
                rangeStart = null
                rangeEnd = -1
            }
            for (j in start until end) {
                val b = scores[j]
                val cost = if (needle[j] == sequence[i]) 0 else 1
                c = minOf(a + cost, minOf(b + 1, c + 1))
                scores[j] = c
                a = b
                if (c <= maxGood) {
                    if (rangeStart == null) rangeStart = j
                    rangeEnd = maxOf(rangeEnd, j + 1 + (maxGood - c))
                }
            }
            if (rangeStart == null) break
            if (end == n && c <= minScore) {
                minScore = c
                minIndex = i
                if (c < maxGood) maxGood = c
            }
        }
        return if (minScore <= maxDist) ExpandResult(minScore, minIndex + 1) else null
    }

    private fun levenshteinNgram(
        subsequence: String,
        sequence: String,
        maxDist: Int,
        shortCircuit: Triple<Int, Int, Int>? = null,
    ): List<Match> {
        val matches = ArrayList<Match>()
        val subLen = subsequence.length
        val seqLen = sequence.length
        val hayArray = sequence.toCharArray()

        val ngramLength = Math.round(subLen.toDouble() / (maxDist + 1)).toInt()
        require(ngramLength > 0) { "The subsequence length must be greater than maxDist" }

        var ngramStart = 0
        while (ngramStart <= subLen - ngramLength) {
            val ngramEnd = ngramStart + ngramLength
            val subBeforeReversed = reverseSlice(subsequence, ngramStart, 0)
            val subAfter = subsequence.substring(ngramEnd)

            val startIndex = maxOf(0, ngramStart - maxDist)
            val endIndex = minOf(seqLen, seqLen - subLen + ngramEnd + maxDist)
            val ngram = subsequence.substring(ngramStart, ngramEnd)
            val exactMatches = searchExact(ngram, hayArray, startIndex, endIndex)

            for (index in exactMatches) {
                val rightSliceStart = index + ngramLength
                val rightSliceEnd = index - ngramStart + subLen + maxDist
                if (rightSliceStart > seqLen) continue
                val rightSequence = sequence.substring(rightSliceStart, minOf(rightSliceEnd, seqLen))
                val rightMatch = expand(subAfter, rightSequence, maxDist) ?: continue
                val distRight = rightMatch.score
                val rightExpandSize = rightMatch.index

                val leftSliceFrom = maxOf(0, index - ngramStart - (maxDist - distRight))
                val leftSequence = reverseSlice(sequence, index, leftSliceFrom)
                val leftMatch = expand(subBeforeReversed, leftSequence, maxDist - distRight) ?: continue
                val distLeft = leftMatch.score
                val leftExpandSize = leftMatch.index

                val matchStart = index - leftExpandSize
                val matchEnd = index + ngramLength + rightExpandSize
                val dist = distLeft + distRight
                matches.add(Match(matchStart, matchEnd, dist))
                if (shortCircuit != null) {
                    val (scDist, scOffset, scEndOffset) = shortCircuit
                    if (dist <= scDist && matchStart <= scOffset && matchEnd >= seqLen - scEndOffset) return matches
                }
            }
            ngramStart += ngramLength
        }
        return matches
    }
}

class NGramIndex(transcript: String, val ngramSize: Int = 5) {
    private val index: Map<String, List<Int>>

    init {
        val words = words(transcript)
        val charOffsets = IntArray(words.size)
        var offset = 0
        for (i in words.indices) {
            charOffsets[i] = offset
            offset += words[i].length + 1
        }
        val idx = HashMap<String, MutableList<Int>>()
        if (words.size >= ngramSize) {
            for (i in 0..words.size - ngramSize) {
                val gram = words.subList(i, i + ngramSize).joinToString(" ")
                idx.getOrPut(gram) { ArrayList() }.add(charOffsets[i])
            }
        }
        index = idx
    }

    fun candidates(chunk: String): List<Int> {
        val words = words(chunk)
        if (words.size < ngramSize) return emptyList()
        val hits = HashSet<Int>()
        for (i in 0..words.size - ngramSize) {
            val gram = words.subList(i, i + ngramSize).joinToString(" ")
            index[gram]?.let { hits.addAll(it) }
        }
        return hits.sorted()
    }

    companion object {
        fun words(chunk: String): List<String> =
            chunk.lowercase().split(Regex("\\s+")).filter { it.isNotEmpty() }
    }
}
