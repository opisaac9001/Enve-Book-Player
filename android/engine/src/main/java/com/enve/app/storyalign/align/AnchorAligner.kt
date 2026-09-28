package com.enve.app.storyalign.align

class AnchorAligner(
    private val anchorNgram: Int = ANCHOR_NGRAM,
    private val maxGapTokens: Int = MAX_GAP_TOKENS,
) {

    fun align(ref: List<String>, hyp: List<String>): IntArray {
        val matches = IntArray(ref.size) { UNMATCHED }
        if (ref.isEmpty() || hyp.isEmpty()) return matches

        val anchors = monotonicAnchors(ref, hyp)
        var refCursor = 0
        var hypCursor = 0
        anchors.forEach { (refIndex, hypIndex) ->
            fillGap(ref, hyp, refCursor, refIndex, hypCursor, hypIndex, matches)
            matches[refIndex] = hypIndex
            refCursor = refIndex + 1
            hypCursor = hypIndex + 1
        }
        fillGap(ref, hyp, refCursor, ref.size, hypCursor, hyp.size, matches)
        return matches
    }

    private fun monotonicAnchors(ref: List<String>, hyp: List<String>): List<Pair<Int, Int>> {
        val refGrams = uniqueNgramPositions(ref)
        val hypGrams = uniqueNgramPositions(hyp)
        val candidates = refGrams.mapNotNull { (gram, refIndex) ->
            hypGrams[gram]?.let { hypIndex -> refIndex to hypIndex }
        }.sortedBy { it.first }
        return longestIncreasingByHypIndex(candidates)
    }

    private fun uniqueNgramPositions(tokens: List<String>): Map<String, Int> {
        if (tokens.size < anchorNgram) return emptyMap()
        val seen = HashMap<String, Int>()
        val duplicated = HashSet<String>()
        for (start in 0..tokens.size - anchorNgram) {
            val gram = tokens.subList(start, start + anchorNgram).joinToString(" ")
            if (seen.containsKey(gram)) duplicated += gram else seen[gram] = start
        }
        duplicated.forEach(seen::remove)
        return seen
    }

    private fun longestIncreasingByHypIndex(pairs: List<Pair<Int, Int>>): List<Pair<Int, Int>> {
        if (pairs.isEmpty()) return emptyList()
        val tails = ArrayList<Int>()
        val tailIndices = ArrayList<Int>()
        val predecessor = IntArray(pairs.size) { -1 }
        pairs.forEachIndexed { index, (_, hypIndex) ->
            var low = 0
            var high = tails.size
            while (low < high) {
                val mid = (low + high) / 2
                if (tails[mid] < hypIndex) low = mid + 1 else high = mid
            }
            predecessor[index] = if (low > 0) tailIndices[low - 1] else -1
            if (low == tails.size) {
                tails.add(hypIndex)
                tailIndices.add(index)
            } else {
                tails[low] = hypIndex
                tailIndices[low] = index
            }
        }
        val chain = ArrayList<Pair<Int, Int>>(tails.size)
        var cursor = tailIndices.last()
        while (cursor >= 0) {
            chain.add(pairs[cursor])
            cursor = predecessor[cursor]
        }
        chain.reverse()
        return chain
    }

    private fun fillGap(
        ref: List<String>,
        hyp: List<String>,
        refStart: Int,
        refEnd: Int,
        hypStart: Int,
        hypEnd: Int,
        matches: IntArray,
    ) {
        val refCount = refEnd - refStart
        val hypCount = hypEnd - hypStart
        if (refCount <= 0 || hypCount <= 0) return
        if (refCount > maxGapTokens || hypCount > maxGapTokens) return

        val costs = Array(refCount + 1) { IntArray(hypCount + 1) }
        for (r in 0..refCount) costs[r][0] = r
        for (h in 0..hypCount) costs[0][h] = h
        for (r in 1..refCount) {
            for (h in 1..hypCount) {
                val substitution = costs[r - 1][h - 1] +
                    if (ref[refStart + r - 1] == hyp[hypStart + h - 1]) 0 else 1
                costs[r][h] = minOf(substitution, costs[r - 1][h] + 1, costs[r][h - 1] + 1)
            }
        }

        var r = refCount
        var h = hypCount
        while (r > 0 && h > 0) {
            val substitution = costs[r - 1][h - 1] +
                if (ref[refStart + r - 1] == hyp[hypStart + h - 1]) 0 else 1
            when {
                costs[r][h] == substitution -> {
                    if (ref[refStart + r - 1] == hyp[hypStart + h - 1]) {
                        matches[refStart + r - 1] = hypStart + h - 1
                    }
                    r--
                    h--
                }
                costs[r][h] == costs[r - 1][h] + 1 -> r--
                else -> h--
            }
        }
    }

    companion object {
        const val UNMATCHED = -1
        private const val ANCHOR_NGRAM = 3
        private const val MAX_GAP_TOKENS = 600
    }
}
