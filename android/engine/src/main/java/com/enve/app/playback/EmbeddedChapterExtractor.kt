package com.enve.app.playback

import android.content.Context
import androidx.media3.common.MediaItem
import androidx.media3.common.Metadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Chapter
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okio.Buffer
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min

@Singleton
@androidx.annotation.OptIn(UnstableApi::class)
class EmbeddedChapterExtractor @Inject constructor(
    @ApplicationContext private val context: Context,
    okHttpClient: OkHttpClient,
) {
    private val httpClient = okHttpClient.newBuilder()
        .addInterceptor { chain ->
            val request = chain.request()
            val url = request.url
            if (url.username.isNotBlank() && url.password.isNotBlank()) {
                chain.proceed(
                    request.newBuilder()
                        .header("Authorization", Credentials.basic(url.username, url.password))
                        .build()
                )
            } else {
                chain.proceed(request)
            }
        }
        .build()

    suspend fun fetchAvailableChapters(
        tracks: List<AudioTrack>,
        durationSec: Long,
    ): List<Chapter> {
        val playableTracks = tracks.filter { !it.contentUrl.isNullOrBlank() }.sortedBy { it.index }
        if (playableTracks.isEmpty()) return emptyList()

        val embedded = fetchEmbeddedChapters(playableTracks, durationSec)
        if (embedded.isNotEmpty()) return embedded

        return synthesizeChaptersFromTracks(playableTracks, durationSec)
    }

    suspend fun fetchEmbeddedChapters(
        tracks: List<AudioTrack>,
        durationSec: Long,
    ): List<Chapter> {
        val playableTracks = tracks.filter { !it.contentUrl.isNullOrBlank() }.sortedBy { it.index }
        if (playableTracks.isEmpty()) return emptyList()

        val firstUrl = playableTracks.first().contentUrl.orEmpty()
        val mp4Chapters = probeMp4Chapters(firstUrl, durationSec)
        if (mp4Chapters.isNotEmpty()) return mp4Chapters
        if (firstUrl.isRemoteMp4Audio()) return emptyList()

        return probeTrack(firstUrl, durationSec)
    }

    private suspend fun probeTrack(url: String, durationSec: Long): List<Chapter> = withContext(Dispatchers.Main) {
        val candidates = mutableListOf<ChapterCandidate>()
        val completed = CompletableDeferred<Unit>()
        val httpFactory = OkHttpDataSource.Factory(httpClient)
            .setUserAgent("Enve/1.0 (Android; SDK ${android.os.Build.VERSION.SDK_INT})")
        val dataSourceFactory = DefaultDataSource.Factory(context, httpFactory)
        val player = ExoPlayer.Builder(context)
            .setMediaSourceFactory(DefaultMediaSourceFactory(context).setDataSourceFactory(dataSourceFactory))
            .build()

        fun finish() {
            if (!completed.isCompleted) completed.complete(Unit)
        }

        player.volume = 0f
        player.addListener(object : Player.Listener {
            override fun onMetadata(metadata: Metadata) {
                candidates += extractCandidates(metadata)
                if (candidates.isNotEmpty()) finish()
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_READY) {
                    launch {
                        delay(1_500)
                        finish()
                    }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                finish()
            }
        })

        try {
            player.setMediaItem(MediaItem.fromUri(url))
            player.prepare()
            player.playWhenReady = true
            withTimeoutOrNull(5_000) { completed.await() }
        } finally {
            player.stop()
            player.release()
        }

        candidates.toChapters(durationSec)
    }

    private suspend fun probeMp4Chapters(url: String, durationSec: Long): List<Chapter> = withContext(Dispatchers.IO) {
        if (!url.isRemoteMp4Audio()) {
            return@withContext emptyList()
        }

        val first = fetchRange(url, 0, MP4_PROBE_HEAD_BYTES - 1, MP4_PROBE_HEAD_BYTES)
        parseMp4Chapters(first, url, durationSec)?.let { return@withContext it }

        val contentLength = contentLength(url)
        val moov = contentLength?.let { locateTopLevelAtom(url, first, it, "moov") }
        if (moov != null && moov.size in 1..MP4_MAX_MOOV_BYTES) {
            val moovBytes = fetchRange(url, moov.offset, moov.offset + moov.size - 1, moov.size)
            parseMp4Chapters(moovBytes, url, durationSec)?.let { return@withContext it }
        }
        if (contentLength != null && contentLength > MP4_PROBE_TAIL_BYTES) {
            val start = (contentLength - MP4_PROBE_TAIL_BYTES).coerceAtLeast(0)
            val tail = fetchRange(url, start, contentLength - 1, MP4_PROBE_TAIL_BYTES)
            parseMp4Chapters(tail, url, durationSec)?.let { return@withContext it }
        }
        if (contentLength != null && contentLength > MP4_PROBE_EXTENDED_TAIL_BYTES) {
            val start = (contentLength - MP4_PROBE_EXTENDED_TAIL_BYTES).coerceAtLeast(0)
            val tail = fetchRange(url, start, contentLength - 1, MP4_PROBE_EXTENDED_TAIL_BYTES)
            parseMp4Chapters(tail, url, durationSec)?.let { return@withContext it }
        }

        emptyList()
    }

    private fun locateTopLevelAtom(
        url: String,
        firstBytes: ByteArray,
        contentLength: Long,
        type: String,
    ): LocatedMp4Atom? {
        var offset = 0L
        repeat(MP4_MAX_HEADER_HOPS) {
            val atom = if (offset <= firstBytes.size - 8L) {
                readLocatedAtomAt(firstBytes, offset.toInt(), offset, contentLength)
            } else {
                fetchLocatedAtomAt(url, offset, contentLength)
            } ?: return null

            if (atom.type == type) return atom
            val nextOffset = atom.offset + atom.size
            if (nextOffset <= atom.offset || nextOffset >= contentLength) return null

            offset = nextOffset
        }
        return null
    }

    private fun fetchLocatedAtomAt(url: String, offset: Long, contentLength: Long): LocatedMp4Atom? {
        val end = (offset + MP4_ATOM_HEADER_PROBE_BYTES - 1).coerceAtMost(contentLength - 1)
        val header = fetchRange(url, offset, end, MP4_ATOM_HEADER_PROBE_BYTES)
        return readLocatedAtomAt(header, 0, offset, contentLength)
    }

    private fun String.isMp4Audio(): Boolean =
        substringBefore('?').substringBefore('#').lowercase().let { path ->
            path.endsWith(".m4b") || path.endsWith(".m4a") || path.endsWith(".mp4")
        }

    private fun String.isRemoteMp4Audio(): Boolean =
        (startsWith("http://", ignoreCase = true) || startsWith("https://", ignoreCase = true)) && isMp4Audio()

    private fun contentLength(url: String): Long? {
        val head = Request.Builder().url(url).head().build()
        runCatching {
            httpClient.newCall(head).execute().use { response ->
                if (response.isSuccessful) {
                    response.header("Content-Length")?.toLongOrNull()?.let { return it }
                }
            }
        }

        val probe = Request.Builder()
            .url(url)
            .header("Range", "bytes=0-0")
            .build()
        return runCatching {
            httpClient.newCall(probe).execute().use { response ->
                response.header("Content-Range")
                    ?.substringAfter('/')
                    ?.takeIf { it != "*" }
                    ?.toLongOrNull()
                    ?: response.header("Content-Length")?.toLongOrNull()
            }
        }.getOrNull()
    }

    private fun fetchRange(url: String, start: Long, endInclusive: Long, maxBytes: Long): ByteArray {
        val request = Request.Builder()
            .url(url)
            .header("Range", "bytes=$start-$endInclusive")
            .build()
        return runCatching {
            httpClient.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@runCatching ByteArray(0)
                response.body?.source()?.readLimited(maxBytes) ?: ByteArray(0)
            }
        }.getOrDefault(ByteArray(0))
    }

    private fun okio.BufferedSource.readLimited(maxBytes: Long): ByteArray {
        val buffer = Buffer()
        var remaining = maxBytes
        while (remaining > 0) {
            val read = read(buffer, min(remaining, 8_192L))
            if (read == -1L) break
            remaining -= read
        }
        return buffer.readByteArray()
    }

    private fun parseMp4Chapters(bytes: ByteArray, url: String, durationSec: Long): List<Chapter>? {
        if (bytes.size < 16) return null
        val moov = findAtom(bytes, "moov") ?: return null
        parseQuickTimeChapters(bytes, moov.payloadStart, moov.end, url, durationSec)?.let { return it }
        val chpl = findNestedAtom(bytes, moov.payloadStart, moov.end, "chpl") ?: return null
        return parseChpl(bytes, chpl.payloadStart, chpl.end, durationSec)
            ?.takeIf { it.isNotEmpty() }
    }

    private fun parseQuickTimeChapters(
        bytes: ByteArray,
        start: Int,
        end: Int,
        url: String,
        durationSec: Long,
    ): List<Chapter>? {
        val tracks = parseTracks(bytes, start, end)
        val referencedChapterTrackId = tracks.firstNotNullOfOrNull { track ->
            track.chapterTrackIds.firstOrNull()
        }
        val chapterTrack = referencedChapterTrackId
            ?.let { id -> tracks.firstOrNull { it.trackId == id } }
            ?: tracks.firstOrNull { it.handlerType == "text" || it.handlerType == "sbtl" }
            ?: return null
        if (chapterTrack.sampleSizes.isEmpty() || chapterTrack.chunkOffsets.isEmpty()) return null

        val offsets = chapterTrack.sampleOffsets()
        if (offsets.isEmpty()) return null

        val samples = fetchTextSamples(url, offsets, chapterTrack.sampleSizes)
        var currentTime = 0L
        val candidates = chapterTrack.sampleSizes.mapIndexedNotNull { index, size ->
            val sample = samples[index] ?: return@mapIndexedNotNull null
            val title = parseTextSampleTitle(sample).ifBlank { "Chapter ${index + 1}" }
            val startMs = if (chapterTrack.timescale > 0) {
                currentTime * 1000L / chapterTrack.timescale
            } else {
                currentTime
            }
            currentTime += chapterTrack.sampleDeltas.getOrNull(index) ?: 0L
            ChapterCandidate(
                id = null,
                title = title,
                startTimeMs = startMs,
                endTimeMs = null,
            )
        }
        return candidates
            .takeIf { it.size > 1 }
            ?.toChapters(durationSec)
            ?.takeIf { it.isNotEmpty() }
    }

    private fun fetchTextSamples(url: String, offsets: List<Long>, sizes: List<Int>): Map<Int, ByteArray> {
        val samples = mutableMapOf<Int, ByteArray>()
        var index = 0
        val sampleCount = minOf(offsets.size, sizes.size, MP4_MAX_CHAPTER_SAMPLES)
        while (index < sampleCount) {
            val groupStartIndex = index
            val groupStart = offsets[index]
            var groupEnd = sampleEnd(offsets[index], sizes[index])
            var next = index + 1
            while (next < sampleCount) {
                val nextStart = offsets[next]
                val nextEnd = sampleEnd(nextStart, sizes[next])
                val expandedEnd = maxOf(groupEnd, nextEnd)
                val gap = nextStart - groupEnd - 1
                val span = expandedEnd - groupStart + 1
                if (gap > MP4_MAX_SAMPLE_GROUP_GAP_BYTES || span > MP4_MAX_SAMPLE_GROUP_BYTES) break
                groupEnd = expandedEnd
                next++
            }

            val bytes = fetchRange(url, groupStart, groupEnd, groupEnd - groupStart + 1)
            for (sampleIndex in groupStartIndex until next) {
                val start = (offsets[sampleIndex] - groupStart).toInt()
                val size = sizes[sampleIndex].toLong().coerceAtMost(MP4_MAX_TEXT_SAMPLE_BYTES).toInt()
                if (start >= 0 && start + size <= bytes.size) {
                    samples[sampleIndex] = bytes.copyOfRange(start, start + size)
                }
            }
            index = next
        }
        return samples
    }

    private fun sampleEnd(offset: Long, size: Int): Long =
        offset + size.toLong().coerceAtMost(MP4_MAX_TEXT_SAMPLE_BYTES) - 1

    private fun parseTracks(bytes: ByteArray, start: Int, end: Int): List<Mp4Track> {
        val tracks = mutableListOf<Mp4Track>()
        var cursor = start
        while (cursor + 8 <= end) {
            val atom = readAtomAt(bytes, cursor, end) ?: break
            if (atom.type == "trak") {
                parseTrack(bytes, atom.payloadStart, atom.end)?.let { tracks += it }
            }
            cursor = atom.end
        }
        return tracks
    }

    private fun parseTrack(bytes: ByteArray, start: Int, end: Int): Mp4Track? {
        val track = MutableMp4Track()
        walkAtoms(bytes, start, end) { atom ->
            when (atom.type) {
                "tkhd" -> track.trackId = parseTkhdTrackId(bytes, atom.payloadStart, atom.end)
                "hdlr" -> track.handlerType = parseHdlrType(bytes, atom.payloadStart, atom.end)
                "mdhd" -> track.timescale = parseMdhdTimescale(bytes, atom.payloadStart, atom.end)
                "tref" -> track.chapterTrackIds += parseTrefChapterTrackIds(bytes, atom.payloadStart, atom.end)
                "stts" -> track.sampleDeltas += parseStts(bytes, atom.payloadStart, atom.end)
                "stsz" -> track.sampleSizes = parseStsz(bytes, atom.payloadStart, atom.end)
                "stsc" -> track.samplesPerChunk = parseStsc(bytes, atom.payloadStart, atom.end)
                "stco" -> track.chunkOffsets = parseStco(bytes, atom.payloadStart, atom.end)
                "co64" -> track.chunkOffsets = parseCo64(bytes, atom.payloadStart, atom.end)
            }
        }
        val id = track.trackId ?: return null
        return Mp4Track(
            trackId = id,
            handlerType = track.handlerType,
            timescale = track.timescale ?: 0L,
            chapterTrackIds = track.chapterTrackIds,
            sampleDeltas = track.sampleDeltas,
            sampleSizes = track.sampleSizes,
            samplesPerChunk = track.samplesPerChunk,
            chunkOffsets = track.chunkOffsets,
        )
    }

    private fun walkAtoms(bytes: ByteArray, start: Int, end: Int, visit: (Mp4Atom) -> Unit) {
        var cursor = start
        while (cursor + 8 <= end) {
            val atom = readAtomAt(bytes, cursor, end) ?: break
            visit(atom)
            if (atom.type in MP4_CONTAINER_TYPES) {
                val childStart = if (atom.type == "meta") atom.payloadStart + 4 else atom.payloadStart
                walkAtoms(bytes, childStart.coerceAtMost(atom.end), atom.end, visit)
            }
            cursor = atom.end
        }
    }

    private fun parseTkhdTrackId(bytes: ByteArray, start: Int, end: Int): Long? {
        if (start + 4 > end) return null
        val version = bytes[start].toInt() and 0xff
        val offset = start + if (version == 1) 20 else 12
        return readUInt32(bytes, offset)
    }

    private fun parseMdhdTimescale(bytes: ByteArray, start: Int, end: Int): Long? {
        if (start + 4 > end) return null
        val version = bytes[start].toInt() and 0xff
        val offset = start + if (version == 1) 20 else 12
        return readUInt32(bytes, offset)
    }

    private fun parseHdlrType(bytes: ByteArray, start: Int, end: Int): String? {
        val offset = start + 8
        if (offset + 4 > end) return null
        return String(bytes, offset, 4, Charsets.US_ASCII)
    }

    private fun parseTrefChapterTrackIds(bytes: ByteArray, start: Int, end: Int): List<Long> {
        val ids = mutableListOf<Long>()
        var cursor = start
        while (cursor + 8 <= end) {
            val atom = readAtomAt(bytes, cursor, end) ?: break
            if (atom.type == "chap") {
                var idCursor = atom.payloadStart
                while (idCursor + 4 <= atom.end) {
                    readUInt32(bytes, idCursor)?.let { ids += it }
                    idCursor += 4
                }
            }
            cursor = atom.end
        }
        return ids
    }

    private fun parseStts(bytes: ByteArray, start: Int, end: Int): List<Long> {
        val count = readUInt32(bytes, start + 4)?.toInt() ?: return emptyList()
        val deltas = mutableListOf<Long>()
        var cursor = start + 8
        repeat(count.coerceAtMost(10_000)) {
            if (cursor + 8 > end) return deltas
            val sampleCount = readUInt32(bytes, cursor)?.toInt() ?: return deltas
            val sampleDelta = readUInt32(bytes, cursor + 4) ?: return deltas
            repeat(sampleCount.coerceAtMost(10_000)) { deltas += sampleDelta }
            cursor += 8
        }
        return deltas
    }

    private fun parseStsz(bytes: ByteArray, start: Int, end: Int): List<Int> {
        val sampleSize = readUInt32(bytes, start + 4) ?: return emptyList()
        val sampleCount = readUInt32(bytes, start + 8)?.toInt() ?: return emptyList()
        if (sampleSize > 0) return List(sampleCount.coerceAtMost(10_000)) { sampleSize.toInt() }
        val sizes = mutableListOf<Int>()
        var cursor = start + 12
        repeat(sampleCount.coerceAtMost(10_000)) {
            if (cursor + 4 > end) return sizes
            sizes += readUInt32(bytes, cursor)?.toInt() ?: return sizes
            cursor += 4
        }
        return sizes
    }

    private fun parseStsc(bytes: ByteArray, start: Int, end: Int): List<StscEntry> {
        val count = readUInt32(bytes, start + 4)?.toInt() ?: return emptyList()
        val entries = mutableListOf<StscEntry>()
        var cursor = start + 8
        repeat(count.coerceAtMost(10_000)) {
            if (cursor + 12 > end) return entries
            val firstChunk = readUInt32(bytes, cursor) ?: return entries
            val samplesPerChunk = readUInt32(bytes, cursor + 4) ?: return entries
            entries += StscEntry(firstChunk, samplesPerChunk)
            cursor += 12
        }
        return entries
    }

    private fun parseStco(bytes: ByteArray, start: Int, end: Int): List<Long> {
        val count = readUInt32(bytes, start + 4)?.toInt() ?: return emptyList()
        val offsets = mutableListOf<Long>()
        var cursor = start + 8
        repeat(count.coerceAtMost(10_000)) {
            if (cursor + 4 > end) return offsets
            offsets += readUInt32(bytes, cursor) ?: return offsets
            cursor += 4
        }
        return offsets
    }

    private fun parseCo64(bytes: ByteArray, start: Int, end: Int): List<Long> {
        val count = readUInt32(bytes, start + 4)?.toInt() ?: return emptyList()
        val offsets = mutableListOf<Long>()
        var cursor = start + 8
        repeat(count.coerceAtMost(10_000)) {
            if (cursor + 8 > end) return offsets
            offsets += readUInt64(bytes, cursor) ?: return offsets
            cursor += 8
        }
        return offsets
    }

    private fun Mp4Track.sampleOffsets(): List<Long> {
        if (chunkOffsets.isEmpty() || sampleSizes.isEmpty()) return emptyList()
        val offsets = mutableListOf<Long>()
        var sampleIndex = 0
        chunkOffsets.forEachIndexed { chunkIndex, chunkOffset ->
            val chunkNumber = chunkIndex + 1L
            val samplesInChunk = samplesPerChunk
                .lastOrNull { chunkNumber >= it.firstChunk }
                ?.samplesPerChunk
                ?: 1L
            var offset = chunkOffset
            repeat(samplesInChunk.toInt().coerceAtMost(sampleSizes.size - sampleIndex)) {
                offsets += offset
                offset += sampleSizes[sampleIndex]
                sampleIndex++
            }
        }
        return offsets
    }

    private fun parseTextSampleTitle(sample: ByteArray): String {
        if (sample.size < 2) return ""
        val length = (((sample[0].toInt() and 0xff) shl 8) or (sample[1].toInt() and 0xff))
            .coerceAtMost(sample.size - 2)
        if (length <= 0) return ""
        return String(sample, 2, length, Charsets.UTF_8).trim()
    }

    private fun parseChpl(bytes: ByteArray, start: Int, end: Int, durationSec: Long): List<Chapter>? {
        if (start + 5 > end) return null
        val version = bytes[start].toInt() and 0xff
        val chapters = when (version) {
            0 -> parseChplAt(bytes, start + 8, end, fourByteCount = true)
            else -> parseChplAt(bytes, start + 5, end, fourByteCount = false)
        }
        return chapters
            ?.toChapters(durationSec)
            ?.takeIf { chapters -> chapters.size > 1 || durationSec <= 0L }
    }

    private fun parseChplAt(bytes: ByteArray, countOffset: Int, end: Int, fourByteCount: Boolean): List<ChapterCandidate>? {
        if (countOffset < 0 || countOffset >= end) return null
        val count = if (fourByteCount) {
            readUInt32(bytes, countOffset)?.toInt() ?: return null
        } else {
            bytes[countOffset].toInt() and 0xff
        }
        if (count <= 0 || count > 200) return null

        val entries = mutableListOf<RawChapterEntry>()
        var cursor = countOffset + if (fourByteCount) 4 else 1
        repeat(count) {
            if (cursor + 9 > end) return null
            val startRaw = readUInt64(bytes, cursor) ?: return null
            cursor += 8
            val titleLength = bytes[cursor].toInt() and 0xff
            cursor += 1
            if (cursor + titleLength > end) return null
            val title = String(bytes, cursor, titleLength, Charsets.UTF_8).trim()
            cursor += titleLength
            entries += RawChapterEntry(startRaw, title)
        }
        if (entries.size != count || entries.map { it.startRaw }.distinct().size < minOf(2, count)) return null

        val scale = if (entries.maxOf { it.startRaw } > 3_600_000L) 10_000L else 1L
        return entries
            .sortedBy { it.startRaw }
            .mapIndexed { index, entry ->
                ChapterCandidate(
                    id = null,
                    title = entry.title.ifBlank { "Chapter ${index + 1}" },
                    startTimeMs = entry.startRaw / scale,
                    endTimeMs = null,
                )
            }
    }

    private fun readLocatedAtomAt(
        bytes: ByteArray,
        offset: Int,
        absoluteOffset: Long,
        contentLength: Long,
    ): LocatedMp4Atom? {
        if (offset < 0 || offset + 8 > bytes.size) return null
        val smallSize = readUInt32(bytes, offset) ?: return null
        val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
        if (type.any { it.code < 0x20 || it.code > 0x7e }) return null

        val headerSize = if (smallSize == 1L) 16L else 8L
        val size = when (smallSize) {
            0L -> contentLength - absoluteOffset
            1L -> readUInt64(bytes, offset + 8) ?: return null
            else -> smallSize
        }
        if (size < headerSize || absoluteOffset + size > contentLength) return null
        return LocatedMp4Atom(type, absoluteOffset, size)
    }

    private fun findAtom(bytes: ByteArray, type: String): Mp4Atom? {
        readTopLevelAtom(bytes, 0, bytes.size, type)?.let { return it }
        val target = type.encodeToByteArray()
        for (offset in 0..bytes.size - 8) {
            if (!bytes.matches(offset + 4, target)) continue
            readAtomAt(bytes, offset, bytes.size)?.let { atom ->
                if (atom.type == type) return atom
            }
        }
        return null
    }

    private fun readTopLevelAtom(bytes: ByteArray, start: Int, end: Int, type: String): Mp4Atom? {
        var cursor = start
        while (cursor + 8 <= end) {
            val atom = readAtomAt(bytes, cursor, end) ?: break
            if (atom.type == type) return atom
            cursor = atom.end
        }
        return null
    }

    private fun findNestedAtom(bytes: ByteArray, start: Int, end: Int, type: String): Mp4Atom? {
        var cursor = start
        while (cursor + 8 <= end) {
            val atom = readAtomAt(bytes, cursor, end) ?: break
            if (atom.type == type) return atom
            if (atom.type in MP4_CONTAINER_TYPES) {
                val childStart = if (atom.type == "meta") atom.payloadStart + 4 else atom.payloadStart
                findNestedAtom(bytes, childStart.coerceAtMost(atom.end), atom.end, type)?.let { return it }
            }
            cursor = atom.end
        }
        return null
    }

    private fun readAtomAt(bytes: ByteArray, offset: Int, limit: Int): Mp4Atom? {
        if (offset < 0 || offset + 8 > limit) return null
        val smallSize = readUInt32(bytes, offset) ?: return null
        val type = String(bytes, offset + 4, 4, Charsets.US_ASCII)
        val (size, payloadStart) = if (smallSize == 1L) {
            val large = readUInt64(bytes, offset + 8) ?: return null
            large to offset + 16
        } else {
            smallSize to offset + 8
        }
        if (size < (payloadStart - offset) || offset + size > limit) return null
        if (type.any { it.code < 0x20 || it.code > 0x7e }) return null
        return Mp4Atom(type, payloadStart, (offset + size).toInt())
    }

    private fun ByteArray.matches(offset: Int, target: ByteArray): Boolean {
        if (offset < 0 || offset + target.size > size) return false
        for (index in target.indices) {
            if (this[offset + index] != target[index]) return false
        }
        return true
    }

    private fun readUInt32(bytes: ByteArray, offset: Int): Long? {
        if (offset + 4 > bytes.size) return null
        return ((bytes[offset].toLong() and 0xff) shl 24) or
            ((bytes[offset + 1].toLong() and 0xff) shl 16) or
            ((bytes[offset + 2].toLong() and 0xff) shl 8) or
            (bytes[offset + 3].toLong() and 0xff)
    }

    private fun readUInt64(bytes: ByteArray, offset: Int): Long? {
        if (offset + 8 > bytes.size) return null
        var value = 0L
        repeat(8) { index ->
            value = (value shl 8) or (bytes[offset + index].toLong() and 0xff)
        }
        return value
    }

    private fun extractCandidates(metadata: Metadata): List<ChapterCandidate> {
        val chapters = mutableListOf<ChapterCandidate>()
        for (index in 0 until metadata.length()) {
            val entry = metadata[index]
            if (entry.javaClass.simpleName != "ChapterFrame") continue
            val startTimeMs = readNumberField(entry, "startTimeMs") ?: continue
            val endTimeMs = readNumberField(entry, "endTimeMs")
            val id = readStringField(entry, "id")
            chapters += ChapterCandidate(
                id = id,
                title = readChapterTitle(entry) ?: id?.takeIf { it.isNotBlank() },
                startTimeMs = startTimeMs,
                endTimeMs = endTimeMs?.takeIf { it > startTimeMs },
            )
        }
        return chapters
    }

    private fun readChapterTitle(chapterFrame: Any): String? {
        val subFrames = readField(chapterFrame, "subFrames")
        val entries = when (subFrames) {
            is Array<*> -> subFrames.asSequence()
            is Iterable<*> -> subFrames.asSequence()
            else -> emptySequence()
        }
        return entries.mapNotNull { entry ->
            entry ?: return@mapNotNull null
            val id = readStringField(entry, "id") ?: return@mapNotNull null
            if (id != "TIT2" && id != "TT2") return@mapNotNull null
            readStringField(entry, "value")
                ?: readField(entry, "values")?.let { values ->
                    when (values) {
                        is Iterable<*> -> values.firstOrNull()?.toString()
                        is Array<*> -> values.firstOrNull()?.toString()
                        else -> values.toString()
                    }
                }
        }.firstOrNull { it.isNotBlank() }
    }

    private fun readStringField(instance: Any, fieldName: String): String? =
        readField(instance, fieldName)?.toString()?.takeIf { it.isNotBlank() }

    private fun readNumberField(instance: Any, fieldName: String): Long? = when (val value = readField(instance, fieldName)) {
        is Number -> value.toLong()
        is String -> value.toLongOrNull()
        else -> null
    }

    private fun readField(instance: Any, fieldName: String): Any? {
        var type: Class<*>? = instance.javaClass
        while (type != null) {
            runCatching {
                val field = type.getDeclaredField(fieldName)
                field.isAccessible = true
                return field.get(instance)
            }
            type = type.superclass
        }
        return null
    }

    private fun List<ChapterCandidate>.toChapters(durationSec: Long): List<Chapter> {
        val sorted = distinctBy { it.startTimeMs }.sortedBy { it.startTimeMs }
        return sorted.mapIndexedNotNull { index, candidate ->
            val nextStartMs = sorted.getOrNull(index + 1)?.startTimeMs
            val endMs = candidate.endTimeMs
                ?: nextStartMs
                ?: durationSec.takeIf { it > 0L }?.times(1000L)
                ?: return@mapIndexedNotNull null
            if (endMs <= candidate.startTimeMs) return@mapIndexedNotNull null
            Chapter(
                index = index,
                title = candidate.title?.takeIf { it.isNotBlank() } ?: "Chapter ${index + 1}",
                startTime = candidate.startTimeMs / 1000L,
                endTime = endMs / 1000L,
            )
        }
    }

    private data class ChapterCandidate(
        val id: String?,
        val title: String?,
        val startTimeMs: Long,
        val endTimeMs: Long?,
    )

    private data class RawChapterEntry(
        val startRaw: Long,
        val title: String,
    )

    private data class LocatedMp4Atom(
        val type: String,
        val offset: Long,
        val size: Long,
    )

    private data class Mp4Atom(
        val type: String,
        val payloadStart: Int,
        val end: Int,
    )

    private data class StscEntry(
        val firstChunk: Long,
        val samplesPerChunk: Long,
    )

    private data class MutableMp4Track(
        var trackId: Long? = null,
        var handlerType: String? = null,
        var timescale: Long? = null,
        val chapterTrackIds: MutableList<Long> = mutableListOf(),
        val sampleDeltas: MutableList<Long> = mutableListOf(),
        var sampleSizes: List<Int> = emptyList(),
        var samplesPerChunk: List<StscEntry> = emptyList(),
        var chunkOffsets: List<Long> = emptyList(),
    )

    private data class Mp4Track(
        val trackId: Long,
        val handlerType: String?,
        val timescale: Long,
        val chapterTrackIds: List<Long>,
        val sampleDeltas: List<Long>,
        val sampleSizes: List<Int>,
        val samplesPerChunk: List<StscEntry>,
        val chunkOffsets: List<Long>,
    )

    private companion object {
        private const val MP4_PROBE_HEAD_BYTES = 2L * 1024L * 1024L
        private const val MP4_PROBE_TAIL_BYTES = 8L * 1024L * 1024L
        private const val MP4_PROBE_EXTENDED_TAIL_BYTES = 32L * 1024L * 1024L
        private const val MP4_MAX_MOOV_BYTES = 128L * 1024L * 1024L
        private const val MP4_ATOM_HEADER_PROBE_BYTES = 32L
        private const val MP4_MAX_HEADER_HOPS = 16
        private const val MP4_MAX_TEXT_SAMPLE_BYTES = 64L * 1024L
        private const val MP4_MAX_CHAPTER_SAMPLES = 500
        private const val MP4_MAX_SAMPLE_GROUP_BYTES = 2L * 1024L * 1024L
        private const val MP4_MAX_SAMPLE_GROUP_GAP_BYTES = 32L * 1024L
        private val MP4_CONTAINER_TYPES = setOf("moov", "udta", "meta", "ilst", "trak", "tref", "mdia", "minf", "stbl")
    }
}
