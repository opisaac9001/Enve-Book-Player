package com.enve.app.storyalign.export

import com.enve.app.storyalign.align.AlignmentQuality
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class StoryAlignOutputQuality(
    val acceptedSentenceCount: Int,
    val eligibleSentenceCount: Int,
    val audioCoverage: Double,
    val assessment: AlignmentQuality? = null,
) {
    val textCoverage: Double get() = acceptedSentenceCount.toDouble() / eligibleSentenceCount

    private fun valid(): Boolean = acceptedSentenceCount > 0 && eligibleSentenceCount >= acceptedSentenceCount &&
        audioCoverage.isFinite() && audioCoverage in 0.0..1.0 && assessment?.let {
            it.unitCount == acceptedSentenceCount && it.coverage.isFinite() && it.coverage in 0.0..1.0 &&
                it.largestGap.isFinite() && it.largestGap in 0.0..1.0 &&
                it.monotonicity.isFinite() && it.monotonicity in 0.0..1.0 &&
                it.timingConsistency.isFinite() && it.timingConsistency in 0.0..1.0 &&
                it.purity.isFinite() && it.purity in 0.0..1.0 &&
                (it.confidence == null || it.confidence.isFinite() && it.confidence in 0.0..1.0)
        } != false

    fun encode(): ByteArray {
        require(valid()) { "Invalid alignment output quality" }
        return JSON.encodeToString(serializer(), this).toByteArray(Charsets.UTF_8)
    }

    data class Snapshot(val metadata: StoryAlignOutputQuality?, val clipCount: Int)

    companion object {
        const val ENTRY = "META-INF/enve-ctc-quality.json"
        private val JSON = Json { ignoreUnknownKeys = true }
        private val AUDIO_TAG = Regex("<(?:[A-Za-z_][\\w.-]*:)?audio\\b", RegexOption.IGNORE_CASE)

        fun read(file: File): Snapshot? = try {
            ZipFile(file).use { zip ->
                val entry = zip.getEntry(ENTRY)
                if (entry != null) {
                    val metadata = JSON.decodeFromString<StoryAlignOutputQuality>(zip.readBounded(entry, 65_536).toString(Charsets.UTF_8))
                    if (metadata.valid()) Snapshot(metadata, metadata.acceptedSentenceCount) else null
                } else {
                    var clips = 0
                    val entries = zip.entries()
                    while (entries.hasMoreElements()) {
                        val item = entries.nextElement()
                        if (!item.isDirectory && item.name.endsWith(".smil", ignoreCase = true)) {
                            clips += AUDIO_TAG.findAll(zip.readBounded(item, 2_097_152).toString(Charsets.UTF_8)).count()
                            if (clips > 1_000_000) throw IOException("Too many legacy narration clips")
                        }
                    }
                    if (clips > 0) Snapshot(null, clips) else null
                }
            }
        } catch (_: IOException) {
            null
        } catch (_: IllegalArgumentException) {
            null
        }

        private fun ZipFile.readBounded(entry: ZipEntry, limit: Int): ByteArray {
            if (entry.size > limit) throw IOException("Alignment output metadata exceeds its size limit")
            return getInputStream(entry).use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8_192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) throw IOException("Alignment output metadata exceeds its size limit")
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        }
    }
}
