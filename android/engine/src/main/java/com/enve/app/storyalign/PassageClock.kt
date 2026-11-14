package com.enve.app.storyalign

import com.enve.app.playback.PlaybackState

internal class PassageClock(private val now: () -> Long) {
    private var observed = Long.MIN_VALUE
    private var observedAt = 0L

    fun seconds(state: PlaybackState): Double {
        val at = now()
        if (state.currentPositionMs != observed) {
            observed = state.currentPositionMs
            observedAt = at
        }
        val speed = state.playbackSpeed.toDouble().takeIf { it.isFinite() && it > 0 } ?: 1.0
        val elapsed = if (state.isPlaying && !state.isBuffering) (at - observedAt).coerceIn(0L, MAX_EXTRAPOLATION_MS) else 0L
        return (observed + elapsed * speed) / 1000.0
    }

    private companion object {
        const val MAX_EXTRAPOLATION_MS = 400L
    }
}
