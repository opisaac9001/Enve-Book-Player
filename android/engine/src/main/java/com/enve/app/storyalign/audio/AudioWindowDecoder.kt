package com.enve.app.storyalign.audio

import android.content.Context
import android.media.MediaCodec
import android.media.MediaDataSource
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import com.enve.core.data.remote.ConnectionScope
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.IOException
import javax.inject.Inject
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlin.math.roundToInt

class AudioWindowDecoder @Inject constructor(
    @ApplicationContext private val context: Context,
    private val client: OkHttpClient,
) {
    suspend fun decode(source: String, connectionId: String?, start: Double, duration: Double, revision: String? = null): FloatArray {
        require(start.isFinite() && start >= 0 && duration > 0 && duration <= 60)
        val execution = currentCoroutineContext()
        val extractor = MediaExtractor()
        val uri = Uri.parse(source)
        val remote = if (uri.scheme == "https" || uri.scheme == "http")
            RangeAudioSource(client, source, connectionId, revision) { execution.ensureActive() } else null
        val cancellation = remote?.let { active ->
            CoroutineScope(execution).launch(Dispatchers.Default, start = CoroutineStart.UNDISPATCHED) {
                try { awaitCancellation() } finally { active.close() }
            }
        }
        try {
            if (remote != null) extractor.setDataSource(remote)
            else if (uri.scheme == "content") extractor.setDataSource(context, uri, null)
            else extractor.setDataSource(if (uri.scheme == "file") requireNotNull(uri.path) else source)
            val track = (0 until extractor.trackCount).firstOrNull {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: throw IOException("No audio track")
            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            extractor.seekTo((start * 1_000_000).toLong(), MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val codec = MediaCodec.createDecoderByType(requireNotNull(format.getString(MediaFormat.KEY_MIME)))
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                try {
                    val result = FloatArray((duration * AudioDecoder.TARGET_SAMPLE_RATE).roundToInt())
                    var written = 0
                    var inputDone = false
                    val info = MediaCodec.BufferInfo()
                    var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    var resampler = LinearResampler(format.getInteger(MediaFormat.KEY_SAMPLE_RATE), AudioDecoder.TARGET_SAMPLE_RATE)
                    while (true) {
                        execution.ensureActive()
                        if (!inputDone) {
                            val input = codec.dequeueInputBuffer(10_000)
                            if (input >= 0) {
                                val size = extractor.readSampleData(requireNotNull(codec.getInputBuffer(input)), 0)
                                val time = extractor.sampleTime
                                inputDone = size < 0 || time >= ((start + duration) * 1_000_000).toLong()
                                codec.queueInputBuffer(input, 0, if (inputDone) 0 else size,
                                    if (inputDone) 0 else time, if (inputDone) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0)
                                if (!inputDone) extractor.advance()
                            }
                        }
                        val output = codec.dequeueOutputBuffer(info, 10_000)
                        if (output == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            channels = codec.outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            resampler = LinearResampler(codec.outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE), AudioDecoder.TARGET_SAMPLE_RATE)
                        } else if (output >= 0) {
                            try {
                                if (info.size > 0) {
                                    val samples = toMono16k(requireNotNull(codec.getOutputBuffer(output)), info.offset, info.size, channels, resampler)
                                    val offset = ((info.presentationTimeUs / 1_000_000.0 - start) * AudioDecoder.TARGET_SAMPLE_RATE).roundToInt()
                                    val skip = maxOf(0, -offset)
                                    val destination = maxOf(0, offset)
                                    val count = minOf(samples.size - skip, result.size - destination)
                                    if (count > 0) {
                                        samples.copyInto(result, destination, skip, skip + count)
                                        written = maxOf(written, destination + count)
                                    }
                                }
                            } finally { codec.releaseOutputBuffer(output, false) }
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                        }
                    }
                    return result.copyOf(written)
                } finally { codec.stop() }
            } finally { codec.release() }
        } catch (error: Exception) {
            execution.ensureActive()
            throw remote?.failure?.get() ?: error
        } finally {
            extractor.release()
            remote?.close()
            withContext(NonCancellable) { cancellation?.cancelAndJoin() }
        }
    }
}

internal class RangeAudioSource(
    private val client: OkHttpClient,
    private val source: String,
    private val connectionId: String?,
    private var revision: String?,
    private val checkCancellation: () -> Unit,
) : MediaDataSource() {
    private var blockStart = -1L
    private var block = ByteArray(0)
    private var length = -1L
    @Volatile private var closed = false
    private val active = java.util.concurrent.atomic.AtomicReference<okhttp3.Call?>(null)
    val failure = java.util.concurrent.atomic.AtomicReference<Exception?>(null)

    @Synchronized
    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        return try { readBlock(position, buffer, offset, size) }
        catch (error: Exception) { failure.set(error); throw error }
    }

    private fun readBlock(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        checkCancellation()
        if (closed) throw IOException("Audio source closed")
        require(position >= 0 && offset >= 0 && size >= 0 && offset + size <= buffer.size)
        if (size == 0) return 0
        if (length >= 0 && position >= length) return -1
        if (position < blockStart || position >= blockStart + block.size) {
            val end = position + 262_143
            val request = Request.Builder().url(source).header("Range", "bytes=$position-$end")
                .apply { revision?.let { header("If-Range", it) } }.build()
            ConnectionScope.withConnectionId(connectionId) {
                val call = client.newCall(request)
                active.set(call)
                if (closed) { call.cancel(); throw IOException("Audio source closed") }
                call.execute().use { response ->
                    checkCancellation()
                    if (response.code != 206) throw IOException("The audio server must support byte ranges (${response.code})")
                    val tag = response.header("ETag")?.takeUnless { it.startsWith("W/") }
                    if (revision != null && tag != revision) throw IOException("The audio file changed")
                    if (revision == null) revision = tag
                    val range = response.header("Content-Range")?.let(CONTENT_RANGE::matchEntire)
                        ?: throw IOException("Missing audio byte range")
                    if (range.groupValues[1].toLong() != position) throw IOException("Incorrect audio byte range")
                    val endAt = range.groupValues[2].toLong()
                    val total = range.groupValues[3].toLongOrNull()
                    if (endAt < position || endAt > end || total == null || total <= endAt) throw IOException("Invalid audio byte range")
                    if (length >= 0 && length != total) throw IOException("The audio file changed")
                    length = total
                    val body = response.body ?: throw IOException("Empty audio response")
                    block = body.source().readByteArray(endAt - position + 1)
                    if (block.size.toLong() != endAt - position + 1) throw IOException("Incomplete audio byte range")
                    blockStart = position
                }
            }
        }
        val start = (position - blockStart).toInt()
        val count = minOf(size, block.size - start)
        if (count <= 0) return -1
        block.copyInto(buffer, offset, start, start + count)
        return count
    }

    @Synchronized
    override fun getSize(): Long {
        if (length < 0) readAt(0, ByteArray(1), 0, 1)
        return length
    }

    override fun close() {
        closed = true
        active.getAndSet(null)?.cancel()
        synchronized(this) { block = ByteArray(0) }
    }

    private companion object {
        val CONTENT_RANGE = Regex("bytes (\\d+)-(\\d+)/(\\d+)")
    }
}
