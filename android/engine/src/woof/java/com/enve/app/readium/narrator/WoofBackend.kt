package com.enve.app.readium.narrator

import android.content.Context
import com.enve.woof.WoofRuntime
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

internal object WoofBackend {
    const val available = true

    fun open(context: Context, directory: File): NarratorBackend = object : NarratorBackend {
        private val runtime = WoofRuntime(context, File(directory, WOOF_WEIGHTS).absolutePath)

        override fun synthesize(
            text: String,
            voice: String,
            language: String,
            speed: Float,
            isCurrent: () -> Boolean,
        ): NarratorAudio {
            val bytes = runtime.synthesize(text, voice) { isCurrent() }
            val pcm = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
            val samples = FloatArray(pcm.remaining())
            pcm.get(samples)
            check(samples.isNotEmpty() || !isCurrent()) { "Underdog Woof produced no audio" }
            return NarratorAudio(samples, 24_000, speed)
        }

        override fun close() = runtime.close()
    }
}
