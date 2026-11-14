package com.enve.app.readium.narrator

import androidx.annotation.Keep
import java.io.File

@Keep
internal class PhononBackend(directory: File) : NarratorBackend {
    private val handle = open(directory.absolutePath.toByteArray(Charsets.UTF_8))

    override fun synthesize(
        text: String,
        voice: String,
        language: String,
        speed: Float,
        isCurrent: () -> Boolean,
    ): NarratorAudio {
        val audio = AudioFrames(isCurrent)
        speak(handle, text.toByteArray(Charsets.UTF_8), voice, audio)
        check(audio.size > 0 || !isCurrent()) { "Phonon produced no audio" }
        return NarratorAudio(audio.samples(), 24_000, speed)
    }

    override fun close() = free(handle)

    private external fun open(directory: ByteArray): Long
    private external fun speak(handle: Long, text: ByteArray, voice: String, audio: AudioFrames)
    private external fun free(handle: Long)

    @Keep
    private class AudioFrames(private val isCurrent: () -> Boolean) {
        private var buffer = FloatArray(24_000)
        var size = 0
            private set

        fun append(frame: FloatArray): Boolean {
            if (!isCurrent()) return false
            val end = size + frame.size
            if (end > buffer.size) buffer = buffer.copyOf(maxOf(end, buffer.size * 2))
            frame.copyInto(buffer, size)
            size = end
            return true
        }

        fun samples() = buffer.copyOf(size)
    }

    private companion object {
        init {
            System.loadLibrary("enve_phonon")
        }
    }
}
