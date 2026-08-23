package com.enve.app.storyalign.export

import com.enve.app.storyalign.align.SentenceRange
import java.util.Locale
import kotlin.math.roundToLong

object AssetPaths {
    const val ROOT = "storyalign"
    const val STYLES = "$ROOT/Styles"
    const val AUDIO = "$ROOT/Audio"
    const val MEDIA_OVERLAYS = "$ROOT/MediaOverlays"
    const val SENTENCE_PFX = "sentence"
}

data class OverlayClip(
    val sentenceId: Int,
    val startSeconds: Double,
    val endSeconds: Double,
    val audioFileName: String,
)

class MediaOverlay(
    val manifestId: String,
    val chapterHref: String,
    val basename: String,
    val clips: List<OverlayClip>,
    val sentenceTagPfx: String = AssetPaths.SENTENCE_PFX,
) {
    val itemId: String get() = "${manifestId}_overlay"
    val href: String get() = "${AssetPaths.MEDIA_OVERLAYS}/$basename.smil"

    val audioFileNames: List<String> get() = clips.map { it.audioFileName }.distinct().sorted()

    fun overlayXml(): String {
        val depth = AssetPaths.MEDIA_OVERLAYS.split("/").count { it.isNotEmpty() }
        val dots = if (depth <= 0) "." else List(depth) { ".." }.joinToString("/")

        val sb = StringBuilder()
        sb.append("<smil xmlns=\"http://www.w3.org/ns/SMIL\" xmlns:epub=\"http://www.idpf.org/2007/ops\" version=\"3.0\">\n")
        sb.append("  <body>\n")
        sb.append("    <seq id=\"$itemId\" epub:textref=\"$dots/$chapterHref\" epub:type=\"chapter\">\n")
        for (c in clips) {
            val sid = "$manifestId-$sentenceTagPfx${c.sentenceId}"
            val clipBegin = formatClip(c.startSeconds)
            val clipEnd = formatClip(c.endSeconds)
            sb.append("      <par id=\"$sid\">\n")
            sb.append("        <text src=\"$dots/$chapterHref#$sid\"/>\n")
            sb.append("        <audio src=\"$dots/${AssetPaths.AUDIO}/${c.audioFileName}\" clipBegin=\"$clipBegin\" clipEnd=\"$clipEnd\"/>\n")
            sb.append("      </par>\n")
        }
        sb.append("    </seq>\n")
        sb.append("  </body>\n")
        sb.append("</smil>\n")
        return sb.toString()
    }

    companion object {
        fun fromChapter(
            manifestId: String,
            chapterHref: String,
            basename: String,
            ranges: List<SentenceRange>,
            sentenceTagPfx: String = AssetPaths.SENTENCE_PFX,
        ): MediaOverlay {
            val clips = ranges
                .filter { it.duration > 0.0 }
                .map { r ->
                    OverlayClip(
                        sentenceId = r.id,
                        startSeconds = r.absoluteStart,
                        endSeconds = r.absoluteEnd,
                        audioFileName = r.audioFile.path.substringAfterLast('/'),
                    )
                }
            return MediaOverlay(manifestId, chapterHref, basename, clips, sentenceTagPfx)
        }
    }
}

internal fun formatClip(seconds: Double): String =
    String.format(Locale.US, "%.3fs", roundToMs(seconds))

internal fun roundToMs(seconds: Double): Double = (seconds * 1000.0).roundToLong() / 1000.0

internal fun formatDuration(seconds: Double): String {
    val totalMs = (seconds * 1000.0).roundToLong()
    val ms = totalMs % 1000
    val totalSec = totalMs / 1000
    val s = totalSec % 60
    val m = (totalSec / 60) % 60
    val h = totalSec / 3600
    return String.format(Locale.US, "%02d:%02d:%02d.%03d", h, m, s, ms)
}
