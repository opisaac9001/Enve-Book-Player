package com.enve.app.storyalign.ctc

object CtcSentenceSelector {
    private data class Position(val file: Int, val seconds: Double) : Comparable<Position> {
        override fun compareTo(other: Position): Int =
            if (file != other.file) file.compareTo(other.file) else seconds.compareTo(other.seconds)
    }

    fun select(candidates: Collection<CtcSentenceMatch>, checkCancellation: () -> Unit = {}): List<CtcSentenceMatch> {
        val ordered = candidates.filter {
            it.start.isFinite() && it.end.isFinite() && it.score.isFinite() && it.start >= 0 && it.end - it.start >= 0.04
        }.sortedBy { it.sentence }
        if (ordered.isEmpty()) return emptyList()
        val ends = ordered.map { Position(it.audioIndex, it.end) }.distinct().sorted()
        val starts = ordered.map { Position(it.audioIndex, it.start) }.distinct().sorted()
        val endRanks = ends.withIndex().associate { it.value to it.index + 1 }
        val startRanks = starts.withIndex().associate { it.value to it.index + 1 }
        val x = IntArray(ordered.size) { endRanks.getValue(Position(ordered[it].audioIndex, ordered[it].end)) }
        val y = IntArray(ordered.size) { startRanks.getValue(Position(ordered[it].audioIndex, ordered[it].start)) }
        val columns = Array(ends.size + 1) { ArrayList<Int>() }
        for (index in ordered.indices) {
            var row = x[index]
            while (row < columns.size) {
                columns[row].add(y[index])
                row += row and -row
            }
        }
        val coordinates = columns.map { it.distinct().sorted() }
        val tree = coordinates.map { IntArray(it.size + 1) { -1 } }
        val lengths = IntArray(ordered.size) { 1 }
        val scores = DoubleArray(ordered.size) { ordered[it].score }
        val previous = IntArray(ordered.size) { -1 }
        fun better(a: Int, b: Int): Int = when {
            a < 0 -> b
            b < 0 -> a
            lengths[a] != lengths[b] -> if (lengths[a] > lengths[b]) a else b
            scores[a] != scores[b] -> if (scores[a] > scores[b]) a else b
            else -> minOf(a, b)
        }
        var winner = -1
        for (index in ordered.indices) {
            if (index % 64 == 0) checkCancellation()
            val item = ordered[index]
            val maximumEnd = Position(item.audioIndex, minOf(item.start + 0.499, item.end - 0.04))
            val maximumStart = Position(item.audioIndex, item.start - 0.04)
            var row = upperBound(ends, maximumEnd)
            val startLimit = upperBound(starts, maximumStart)
            var predecessor = -1
            while (row > 0) {
                var column = upperBound(coordinates[row], startLimit)
                while (column > 0) {
                    predecessor = better(predecessor, tree[row][column])
                    column -= column and -column
                }
                row -= row and -row
            }
            if (predecessor >= 0) {
                lengths[index] = lengths[predecessor] + 1
                scores[index] += scores[predecessor]
                previous[index] = predecessor
            }
            row = x[index]
            while (row < tree.size) {
                var column = upperBound(coordinates[row], y[index])
                while (column < tree[row].size) {
                    tree[row][column] = better(tree[row][column], index)
                    column += column and -column
                }
                row += row and -row
            }
            winner = better(winner, index)
        }
        val result = ArrayList<CtcSentenceMatch>()
        while (winner >= 0) {
            result.add(ordered[winner])
            winner = previous[winner]
        }
        result.reverse()
        for (index in 0 until result.lastIndex) {
            val before = result[index]
            val after = result[index + 1]
            if (before.audioIndex == after.audioIndex && before.end > after.start) {
                result[index] = before.copy(end = after.start)
            }
        }
        return result
    }

    private fun <T : Comparable<T>> upperBound(values: List<T>, limit: T): Int {
        var low = 0
        var high = values.size
        while (low < high) {
            val middle = (low + high) / 2
            if (values[middle] <= limit) low = middle + 1 else high = middle
        }
        return low
    }
}
