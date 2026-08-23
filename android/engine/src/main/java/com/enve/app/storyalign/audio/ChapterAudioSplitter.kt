package com.enve.app.storyalign.audio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

class ChapterAudioSplitter {

    data class TimeRange(val startSeconds: Double, val endSeconds: Double)
    data class Clip(val name: String, val file: File)

    fun split(srcPath: String, ranges: List<TimeRange>, outDir: File, baseName: String): List<Clip> {
        outDir.mkdirs()
        val extractor = MediaExtractor()
        extractor.setDataSource(srcPath)
        val trackIndex = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: run { extractor.release(); throw IllegalArgumentException("No audio track in $srcPath") }
        val format = extractor.getTrackFormat(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME).orEmpty()
        extractor.release()

        val muxable = mime == "audio/mp4a-latm" || mime == MediaFormat.MIMETYPE_AUDIO_AAC
        if (!muxable || ranges.isEmpty()) {
            val ext = srcPath.substringAfterLast('.', "mp3")
            val dest = File(outDir, "$baseName.$ext")
            File(srcPath).copyTo(dest, overwrite = true)
            return listOf(Clip(dest.name, dest))
        }

        return ranges.mapIndexed { index, range ->
            val dest = File(outDir, "%s-%04d.m4a".format(baseName, index))
            extractRange(srcPath, dest, (range.startSeconds * 1_000_000).toLong(), (range.endSeconds * 1_000_000).toLong())
            Clip(dest.name, dest)
        }
    }

    private fun extractRange(srcPath: String, dest: File, startUs: Long, endUs: Long) {
        val extractor = MediaExtractor()
        extractor.setDataSource(srcPath)
        val trackIndex = (0 until extractor.trackCount).first {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        }
        extractor.selectTrack(trackIndex)
        val format = extractor.getTrackFormat(trackIndex)
        val maxInput = if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
            format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE)
        } else {
            256 * 1024
        }

        val muxer = MediaMuxer(dest.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        val outTrack = muxer.addTrack(format)
        muxer.start()

        val buffer = ByteBuffer.allocate(maxInput)
        val info = MediaCodec.BufferInfo()
        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
        val clipStart = extractor.sampleTime.coerceAtLeast(0)
        try {
            while (true) {
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                val time = extractor.sampleTime
                if (time > endUs) break
                info.offset = 0
                info.size = size
                info.presentationTimeUs = (time - clipStart).coerceAtLeast(0)
                info.flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                    MediaCodec.BUFFER_FLAG_KEY_FRAME
                } else {
                    0
                }
                muxer.writeSampleData(outTrack, buffer, info)
                extractor.advance()
            }
        } finally {
            runCatching { muxer.stop() }
            muxer.release()
            extractor.release()
        }
    }
}
