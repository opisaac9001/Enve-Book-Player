package com.enve.app.playback.clips

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import com.enve.app.storyalign.audio.LinearResampler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.coroutines.CoroutineContext

private const val OUTPUT_SAMPLE_RATE = 44_100
private const val OUTPUT_BIT_RATE = 96_000
private const val CODEC_TIMEOUT_US = 10_000L

internal class ClipAudioExporter(private val context: Context) {

    suspend fun export(segments: List<ClipSegment>, output: File) = withContext(Dispatchers.Default) {
        val execution = currentCoroutineContext()
        var complete = false
        try {
            val encoder = AacFileEncoder.open(output, execution)
            try {
                segments.forEach { segment -> decode(segment, execution, encoder::write) }
                encoder.finish()
                if (!encoder.wroteAudio) throw IOException("No audio was decoded")
            } finally {
                encoder.release()
            }
            complete = true
        } finally {
            if (!complete) output.delete()
        }
    }

    private fun decode(segment: ClipSegment, execution: CoroutineContext, sink: (FloatArray) -> Unit) {
        val extractor = MediaExtractor()
        try {
            openSource(extractor, segment.uri)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IOException("No audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track).apply {
                setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
            }
            val startUs = segment.startMs * 1_000L
            val endUs = segment.endMs * 1_000L
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val codec = MediaCodec.createDecoderByType(requireNotNull(format.getString(MediaFormat.KEY_MIME)))
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                try {
                    var pcm = PcmLayout.of(codec.outputFormat, format)
                    var resampler = LinearResampler(pcm.sampleRate, OUTPUT_SAMPLE_RATE)
                    val info = MediaCodec.BufferInfo()
                    var inputDone = false
                    while (true) {
                        execution.ensureActive()
                        if (!inputDone) {
                            val input = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                            if (input >= 0) {
                                val size = extractor.readSampleData(requireNotNull(codec.getInputBuffer(input)), 0)
                                val time = extractor.sampleTime
                                inputDone = size < 0 || time >= endUs
                                codec.queueInputBuffer(
                                    input, 0, if (inputDone) 0 else size, if (inputDone) 0 else time,
                                    if (inputDone) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0,
                                )
                                if (!inputDone) extractor.advance()
                            }
                        }
                        val output = codec.dequeueOutputBuffer(info, CODEC_TIMEOUT_US)
                        if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            pcm = PcmLayout.of(codec.outputFormat, format)
                            resampler = LinearResampler(pcm.sampleRate, OUTPUT_SAMPLE_RATE)
                        } else if (output >= 0) {
                            try {
                                if (info.size > 0) {
                                    val frames = pcm.downmix(requireNotNull(codec.getOutputBuffer(output)), info.offset, info.size)
                                    val first = framesFrom(startUs - info.presentationTimeUs, pcm.sampleRate, frames.size)
                                    val last = framesFrom(endUs - info.presentationTimeUs, pcm.sampleRate, frames.size)
                                    if (last > first) sink(resampler.resample(frames.copyOfRange(first, last)))
                                }
                            } finally {
                                codec.releaseOutputBuffer(output, false)
                            }
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0 || info.presentationTimeUs >= endUs) break
                        }
                    }
                } finally {
                    codec.stop()
                }
            } finally {
                codec.release()
            }
        } finally {
            extractor.release()
        }
    }

    private fun framesFrom(offsetUs: Long, sampleRate: Int, frameCount: Int): Int =
        (offsetUs * sampleRate / 1_000_000L).coerceIn(0L, frameCount.toLong()).toInt()

    private fun openSource(extractor: MediaExtractor, source: String) {
        val uri = Uri.parse(source)
        when (uri.scheme) {
            "content" -> extractor.setDataSource(context, uri, null)
            "file" -> extractor.setDataSource(requireNotNull(uri.path))
            else -> throw IOException("Clips can only be cut from local audio")
        }
    }
}

private class PcmLayout(val sampleRate: Int, val channels: Int, val encoding: Int) {

    fun downmix(buffer: ByteBuffer, offset: Int, size: Int): FloatArray {
        buffer.position(offset)
        buffer.limit(offset + size)
        buffer.order(ByteOrder.nativeOrder())
        return when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> {
                val samples = buffer.asFloatBuffer()
                FloatArray(samples.remaining() / channels) {
                    var sum = 0f
                    repeat(channels) { sum += samples.get() }
                    sum / channels
                }
            }
            else -> {
                val samples = buffer.asShortBuffer()
                FloatArray(samples.remaining() / channels) {
                    var sum = 0
                    repeat(channels) { sum += samples.get() }
                    sum.toFloat() / channels / 32768f
                }
            }
        }
    }

    companion object {
        fun of(output: MediaFormat, input: MediaFormat): PcmLayout {
            val encoding = if (output.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                output.getInteger(MediaFormat.KEY_PCM_ENCODING)
            } else {
                AudioFormat.ENCODING_PCM_16BIT
            }
            if (encoding != AudioFormat.ENCODING_PCM_16BIT && encoding != AudioFormat.ENCODING_PCM_FLOAT) {
                throw IOException("Unsupported decoder output encoding $encoding")
            }
            fun value(key: String) = if (output.containsKey(key)) output.getInteger(key) else input.getInteger(key)
            return PcmLayout(value(MediaFormat.KEY_SAMPLE_RATE), value(MediaFormat.KEY_CHANNEL_COUNT).coerceAtLeast(1), encoding)
        }
    }
}

private class AacFileEncoder private constructor(
    private val codec: MediaCodec,
    private val muxer: MediaMuxer,
    private val execution: CoroutineContext,
) {
    private val info = MediaCodec.BufferInfo()
    private var track = -1
    private var muxing = false
    private var samples = 0L
    var wroteAudio = false
        private set

    fun write(pcm: FloatArray) {
        var offset = 0
        while (offset < pcm.size) {
            execution.ensureActive()
            val index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
            if (index >= 0) {
                val buffer = requireNotNull(codec.getInputBuffer(index)).apply { clear(); order(ByteOrder.nativeOrder()) }
                val count = minOf(pcm.size - offset, buffer.remaining() / 2)
                repeat(count) { buffer.putShort((pcm[offset + it].coerceIn(-1f, 1f) * Short.MAX_VALUE).toInt().toShort()) }
                codec.queueInputBuffer(index, 0, count * 2, presentationTimeUs(), 0)
                samples += count
                offset += count
            }
            drain(endOfStream = false)
        }
    }

    fun finish() {
        while (true) {
            execution.ensureActive()
            val index = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
            if (index >= 0) {
                codec.queueInputBuffer(index, 0, 0, presentationTimeUs(), MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                break
            }
            drain(endOfStream = false)
        }
        drain(endOfStream = true)
    }

    fun release() {
        try {
            codec.stop()
        } catch (_: IllegalStateException) {
        } finally {
            codec.release()
            try {
                if (muxing) muxer.stop()
            } catch (_: IllegalStateException) {
            } finally {
                muxer.release()
            }
        }
    }

    private fun presentationTimeUs(): Long = samples * 1_000_000L / OUTPUT_SAMPLE_RATE

    private fun drain(endOfStream: Boolean) {
        while (true) {
            execution.ensureActive()
            val index = codec.dequeueOutputBuffer(info, if (endOfStream) CODEC_TIMEOUT_US else 0L)
            when {
                index == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!endOfStream) return
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxing = true
                }
                index >= 0 -> {
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (!isConfig && info.size > 0 && muxing) {
                        muxer.writeSampleData(track, requireNotNull(codec.getOutputBuffer(index)), info)
                        wroteAudio = true
                    }
                    codec.releaseOutputBuffer(index, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
            }
        }
    }

    companion object {
        fun open(output: File, execution: CoroutineContext): AacFileEncoder {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, OUTPUT_SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, OUTPUT_BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
            }
            val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                codec.start()
            } catch (error: Throwable) {
                codec.release()
                throw error
            }
            val muxer = try {
                MediaMuxer(output.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            } catch (error: Throwable) {
                codec.stop()
                codec.release()
                throw error
            }
            return AacFileEncoder(codec, muxer, execution)
        }
    }
}
