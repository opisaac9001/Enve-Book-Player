package com.enve.app.readium.narrator

data class NarratorAudio(val samples: FloatArray, val sampleRate: Int, val playbackSpeed: Float = 1f) {
    override fun equals(other: Any?): Boolean =
        other is NarratorAudio && sampleRate == other.sampleRate && playbackSpeed == other.playbackSpeed && samples.contentEquals(other.samples)

    override fun hashCode(): Int = 31 * (31 * samples.contentHashCode() + sampleRate) + playbackSpeed.hashCode()
}
