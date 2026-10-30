package com.enve.core.reader

import kotlin.math.ceil

class ReadingSpeedTracker {
    private data class Sample(val advance: Double, val seconds: Double)
    private val samples = ArrayDeque<Sample>()
    private var lastProgress: Double? = null
    private var lastTimestamp: Long? = null

    fun recordPageTurn(progress: Double, totalPositions: Int, atMillis: Long) {
        if (!progress.isFinite() || progress !in 0.0..1.0 || atMillis < 0) {
            pause()
            return
        }
        val previousProgress = lastProgress
        val previousTimestamp = lastTimestamp
        lastProgress = progress
        lastTimestamp = atMillis
        if (previousProgress == null || previousTimestamp == null) return
        val delta = progress - previousProgress
        val elapsed = (atMillis - previousTimestamp) / 1000.0
        val maximumAdvance = if (totalPositions > 0) 3.0 / totalPositions else 0.015
        if (delta <= 0 || delta > maximumAdvance || elapsed !in 8.0..600.0) return
        val seconds = if (samples.size >= 3) {
            val rates = samples.map { it.seconds / it.advance }.sorted()
            val median = rates[rates.size / 2]
            (elapsed / delta).coerceIn(median / 2, median * 2) * delta
        } else elapsed
        samples.addLast(Sample(delta, seconds))
        if (samples.size > 20) samples.removeFirst()
    }

    val progressPerMinute: Double?
        get() {
            if (samples.size < 3) return null
            val seconds = samples.sumOf { it.seconds }
            return if (seconds >= 30) samples.sumOf { it.advance } / seconds * 60 else null
        }

    fun minutesRemaining(from: Double, to: Double = 1.0): Int? {
        if (!from.isFinite() || !to.isFinite() || from !in 0.0..1.0 || to !in 0.0..1.0 || to <= from) return null
        val rate = progressPerMinute ?: return null
        return ceil(((to - from) / rate).coerceAtMost(99 * 60.0)).toInt()
    }

    fun pause() {
        lastProgress = null
        lastTimestamp = null
    }

    fun reset() {
        samples.clear()
        pause()
    }
}
