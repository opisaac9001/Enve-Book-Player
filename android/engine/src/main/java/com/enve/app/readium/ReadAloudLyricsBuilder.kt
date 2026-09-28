package com.enve.app.readium

import com.enve.engine.playback.ReadAloudLyricLine
import org.jsoup.Jsoup

object ReadAloudLyricsBuilder {

    fun audioOffsetsMs(orderedDurationsMs: List<Pair<String, Long>>): Map<String, Long> {
        var running = 0L
        val offsets = LinkedHashMap<String, Long>(orderedDurationsMs.size)
        orderedDurationsMs.forEach { (href, duration) ->
            val key = normalizeHref(href)
            if (!offsets.containsKey(key)) {
                offsets[key] = running
                running += duration.coerceAtLeast(0L)
            }
        }
        return offsets
    }

    fun lines(
        clips: List<SmilClip>,
        html: String,
        textHref: String,
        audioOffsetsMs: Map<String, Long> = emptyMap(),
    ): List<ReadAloudLyricLine> {
        val document = Jsoup.parse(html)
        val target = normalizeHref(textHref)
        val lines = mutableListOf<ReadAloudLyricLine>()
        clips.forEachIndexed { index, clip ->
            if (normalizeHref(clip.textHref) != target) return@forEachIndexed
            val fragmentId = clip.textFragmentId ?: return@forEachIndexed
            val text = document.getElementById(fragmentId)?.text()?.trim().orEmpty()
            if (text.isEmpty()) return@forEachIndexed
            val offset = audioOffsetsMs[normalizeHref(clip.audioHref)] ?: 0L
            lines += ReadAloudLyricLine(
                id = fragmentId,
                text = text,
                clipIndex = index,
                startMs = offset + clip.clipBeginMs,
                endMs = offset + (clip.clipEndMs ?: clip.clipBeginMs),
            )
        }
        return lines
    }

    fun activeLineId(lines: List<ReadAloudLyricLine>, positionMs: Long): String? {
        if (lines.isEmpty()) return null
        val match = lines.lastOrNull { positionMs >= it.startMs }
        return (match ?: lines.first()).id
    }

    private fun normalizeHref(href: String): String =
        href.substringBefore('#').substringAfterLast('/')
}
