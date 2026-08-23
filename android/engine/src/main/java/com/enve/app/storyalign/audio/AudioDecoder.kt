package com.enve.app.storyalign.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.nio.ByteBuffer
import kotlin.math.min

class AudioDecoder {

    companion object {
        const val TARGET_SAMPLE_RATE = 16_000
        private const val TIMEOUT_US = 10_000L
    }

    fun interface PcmSink {

        fun onChunk(samples: FloatArray, startSeconds: Double)
    }

    @Volatile private var cancelled = false
    fun cancel() { cancelled = true }

    fun decode(path: String, sink: PcmSink) {
        val extractor = MediaExtractor()
        extractor.setDataSource(path)
        val trackIndex = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw IllegalArgumentException("No audio track in $path")

        extractor.selectTrack(trackIndex)
        val format = extractor.getTrackFormat(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME)!!
        val srcRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val srcChannels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, 0)
        codec.start()

        val bufferInfo = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        val resampler = LinearResampler(srcRate, TARGET_SAMPLE_RATE)
        var producedSamples = 0L

        try {
            while (!outputDone && !cancelled) {
                if (!inputDone) {
                    val inIndex = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (inIndex >= 0) {
                        val inBuf = codec.getInputBuffer(inIndex)!!
                        val sampleSize = extractor.readSampleData(inBuf, 0)
                        if (sampleSize < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            codec.queueInputBuffer(inIndex, 0, sampleSize, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(bufferInfo, TIMEOUT_US)
                if (outIndex >= 0) {
                    if (bufferInfo.size > 0) {
                        val outBuf = codec.getOutputBuffer(outIndex)!!
                        val mono = toMono16k(outBuf, bufferInfo, srcChannels, resampler)
                        if (mono.isNotEmpty()) {
                            val startSeconds = producedSamples.toDouble() / TARGET_SAMPLE_RATE
                            sink.onChunk(mono, startSeconds)
                            producedSamples += mono.size
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                }
            }
        } finally {
            codec.stop()
            codec.release()
            extractor.release()
        }
    }

    private fun toMono16k(
        buffer: ByteBuffer,
        info: MediaCodec.BufferInfo,
        channels: Int,
        resampler: LinearResampler,
    ): FloatArray {
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        val shorts = buffer.asShortBuffer()
        val frameCount = shorts.remaining() / channels
        val mono = FloatArray(frameCount)
        var i = 0
        while (i < frameCount) {
            var acc = 0
            for (c in 0 until channels) acc += shorts.get()
            mono[i] = (acc.toFloat() / channels) / 32768f
            i++
        }
        return resampler.resample(mono)
    }
}

internal class LinearResampler(private val srcRate: Int, private val dstRate: Int) {
    private val ratio = srcRate.toDouble() / dstRate
    private var pos = 0.0
    private var carry: Float? = null

    fun resample(input: FloatArray): FloatArray {
        if (srcRate == dstRate) return input
        if (input.isEmpty()) return input
        val prev = carry
        val src = if (prev != null) FloatArray(input.size + 1).also { it[0] = prev; input.copyInto(it, 1) } else input
        val base = if (prev != null) 1.0 else 0.0
        val out = ArrayList<Float>((input.size / ratio).toInt() + 2)
        var p = pos
        while (p + base < src.size - 1) {
            val idx = (p + base)
            val i0 = idx.toInt()
            val frac = idx - i0
            val s = src[i0] * (1 - frac).toFloat() + src[i0 + 1] * frac.toFloat()
            out.add(s)
            p += ratio
        }

        pos = (p + base) - (src.size - 1)
        carry = src[src.size - 1]
        return FloatArray(out.size) { out[it] }
    }
}
