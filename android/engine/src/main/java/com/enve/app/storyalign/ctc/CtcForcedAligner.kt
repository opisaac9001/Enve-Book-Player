package com.enve.app.storyalign.ctc

import kotlin.math.exp

data class CtcEmissions(
    val values: FloatArray,
    val frames: Int,
    val classes: Int,
    val blank: Int,
    val secondsPerFrame: Double,
) {
    init {
        require(frames >= 0 && classes > 0 && blank in 0 until classes)
        require(values.size.toLong() == frames.toLong() * classes)
        require(secondsPerFrame.isFinite() && secondsPerFrame > 0)
        require(values.all { it.isFinite() || it == Float.NEGATIVE_INFINITY })
    }
}

data class CtcTokenTiming(val startFrame: Int, val endFrame: Int, val logProbability: Double)

object CtcForcedAligner {
    private const val MAX_CELLS = 12_000_000L

    fun align(
        emissions: CtcEmissions,
        labels: IntArray,
        checkCancellation: () -> Unit = {},
    ): List<CtcTokenTiming>? {
        if (labels.isEmpty()) return emptyList()
        require(labels.all { it in 0 until emissions.classes && it != emissions.blank })
        val states = labels.size * 2 + 1
        require(emissions.frames.toLong() * states <= MAX_CELLS) { "CTC alignment section exceeds memory limit" }
        val minimumFrames = labels.size + (1 until labels.size).count { labels[it] == labels[it - 1] }
        if (emissions.frames < minimumFrames) return null
        val back = ByteArray(emissions.frames * states)
        var previous = FloatArray(states) { Float.NEGATIVE_INFINITY }
        var current = FloatArray(states)
        previous[0] = 0f
        previous[1] = emissions.values[labels[0]] - maxOf(-30f, emissions.values[emissions.blank])
        for (frame in 1 until emissions.frames) {
            if (frame % 16 == 0) checkCancellation()
            val row = frame * emissions.classes
            for (state in 0 until states) {
                var best = previous[state]
                var step = 0
                if (state > 0 && previous[state - 1] >= best) {
                    best = previous[state - 1]
                    step = 1
                }
                val token = if (state % 2 == 0) emissions.blank else labels[state / 2]
                if (state > 1 && state % 2 == 1 && token != labels[state / 2 - 1] && previous[state - 2] >= best) {
                    best = previous[state - 2]
                    step = 2
                }
                val score = if (state % 2 == 0) 0f else emissions.values[row + token] - maxOf(-30f, emissions.values[row + emissions.blank])
                current[state] = best + score
                back[frame * states + state] = step.toByte()
            }
            val swap = previous
            previous = current
            current = swap
        }
        var state = if (previous[states - 1] >= previous[states - 2]) states - 1 else states - 2
        if (!previous[state].isFinite()) return null
        val starts = IntArray(labels.size) { -1 }
        val ends = IntArray(labels.size)
        val sums = DoubleArray(labels.size)
        val counts = IntArray(labels.size)
        for (frame in emissions.frames - 1 downTo 0) {
            if (state % 2 == 1) {
                val index = state / 2
                starts[index] = frame
                if (counts[index] == 0) ends[index] = frame + 1
                sums[index] += emissions.values[frame * emissions.classes + labels[index]]
                counts[index]++
            }
            if (frame > 0) state -= back[frame * states + state].toInt()
        }
        if (starts.any { it < 0 }) return null
        return labels.indices.map { CtcTokenTiming(starts[it], ends[it], sums[it] / counts[it]) }
    }

    fun foldSpaceIntoBlank(values: FloatArray, classes: Int, blank: Int, space: Int) {
        require(values.size % classes == 0 && blank != space)
        for (row in values.indices step classes) {
            val a = values[row + blank]
            val b = values[row + space]
            val max = maxOf(a, b)
            values[row + blank] = if (max == Float.NEGATIVE_INFINITY) max
                else (max + kotlin.math.ln(exp((a - max).toDouble()) + exp((b - max).toDouble()))).toFloat()
            values[row + space] = Float.NEGATIVE_INFINITY
        }
    }
}
