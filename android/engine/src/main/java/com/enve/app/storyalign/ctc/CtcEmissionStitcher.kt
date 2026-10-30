package com.enve.app.storyalign.ctc

import kotlin.math.abs
import kotlin.math.roundToInt

data class CtcEmissionWindow(val emissions: CtcEmissions, val start: Double, val duration: Double)

object CtcEmissionStitcher {
    fun stitch(previous: CtcEmissionWindow, current: CtcEmissionWindow): CtcEmissionWindow {
        val before = previous.emissions
        val after = current.emissions
        require(previous.start < current.start && current.start < previous.start + previous.duration)
        require(before.classes == after.classes && before.blank == after.blank)
        require(abs(before.secondsPerFrame - after.secondsPerFrame) < 1e-9)
        val step = before.secondsPerFrame
        val seam = (previous.start + previous.duration + current.start) / 2
        val beforeFrames = ((seam - previous.start) / step).roundToInt().coerceIn(0, before.frames)
        val cut = previous.start + beforeFrames * step
        val afterStart = ((cut - current.start) / step).roundToInt().coerceIn(0, after.frames)
        val duration = current.start + current.duration - previous.start
        require(duration <= 74.001) { "CTC analysis section exceeds the window limit" }
        val totalFrames = minOf(beforeFrames + after.frames - afterStart, (duration / step).roundToInt())
        require(totalFrames > beforeFrames)
        val values = FloatArray(totalFrames * before.classes)
        before.values.copyInto(values, 0, 0, beforeFrames * before.classes)
        after.values.copyInto(values, beforeFrames * before.classes, afterStart * after.classes, (afterStart + totalFrames - beforeFrames) * after.classes)
        return CtcEmissionWindow(CtcEmissions(values, totalFrames, before.classes, before.blank, step), previous.start, duration)
    }
}
