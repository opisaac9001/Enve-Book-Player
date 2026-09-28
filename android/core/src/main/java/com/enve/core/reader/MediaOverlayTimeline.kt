package com.enve.core.reader

import com.enve.core.data.util.optArray
import com.enve.core.data.util.optDouble
import com.enve.core.data.util.optObject
import com.enve.core.data.util.optString
import com.enve.core.data.util.stringOrNull
import java.io.File
import java.io.IOException
import kotlin.math.abs
import kotlin.math.ceil
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.xml.sax.Attributes

class MediaOverlayTimeline(
    val clips: List<Clip>,
    audioDurationsBySource: Map<String, Double> = emptyMap(),
    clipTextProgressions: List<Double> = emptyList(),
) {
    data class Clip(
        val fragmentId: String,
        val textHref: String,
        val audioSrc: String,
        val clipBegin: Double,
        val clipEnd: Double,
    ) {
        val duration: Double get() = clipEnd - clipBegin
    }

    data class ClipTiming(
        val audioStart: Double,
        val audioEnd: Double,
        val spokenStart: Double,
        val spokenEnd: Double,
    )

    enum class Source { FRAGMENT, PROGRESSION }

    data class ResolvedPosition(
        val clipIndex: Int,
        val audioTime: Double,
        val source: Source,
    )

    private val audioStartBySource: Map<String, Double>
    val clipTimings: List<ClipTiming>
    val totalAudioDuration: Double
    private val totalSpokenDuration: Double
    val clipTextProgressions: List<Double> = clipTextProgressions.takeIf { it.size == clips.size }.orEmpty()
    private val clipIndicesByFragment: Map<String, List<Int>> = clips.indices.groupBy { clips[it].fragmentId }
    private val clipIndicesByAudioStart: List<Int>

    init {
        val maximumClipEndBySource = LinkedHashMap<String, Double>()
        for (clip in clips) {
            maximumClipEndBySource[clip.audioSrc] = maxOf(maximumClipEndBySource[clip.audioSrc] ?: 0.0, clip.clipEnd)
        }
        val starts = HashMap<String, Double>()
        var audioOffset = 0.0
        for ((source, maximumClipEnd) in maximumClipEndBySource) {
            starts[source] = audioOffset
            audioOffset += maxOf(audioDurationsBySource[source] ?: 0.0, maximumClipEnd)
        }
        var spokenOffset = 0.0
        clipTimings = clips.map { clip ->
            val fileStart = starts[clip.audioSrc] ?: 0.0
            val duration = maxOf(0.0, clip.duration)
            ClipTiming(
                audioStart = fileStart + clip.clipBegin,
                audioEnd = fileStart + clip.clipEnd,
                spokenStart = spokenOffset,
                spokenEnd = spokenOffset + duration,
            ).also { spokenOffset += duration }
        }
        audioStartBySource = starts
        totalAudioDuration = audioOffset
        totalSpokenDuration = spokenOffset
        clipIndicesByAudioStart = clips.indices.sortedWith(compareBy({ clipTimings[it].audioStart }, { it }))
    }

    fun clipIndex(fragmentId: String, preferredHref: String?): Int? {
        val candidates = clipIndicesByFragment[fragmentId]?.takeIf { it.isNotEmpty() } ?: return null
        if (preferredHref != null) {
            candidates.firstOrNull { hrefMatches(clips[it].textHref, preferredHref) }?.let { return it }
        }
        return candidates.first()
    }

    fun clipIndexAtAudioTime(time: Double): Int? {
        if (clipIndicesByAudioStart.isEmpty()) return null
        val clampedTime = time.coerceIn(0.0, totalAudioDuration)
        var lowerBound = 0
        var upperBound = clipIndicesByAudioStart.size
        while (lowerBound < upperBound) {
            val middle = (lowerBound + upperBound) / 2
            if (clipTimings[clipIndicesByAudioStart[middle]].audioStart <= clampedTime) lowerBound = middle + 1
            else upperBound = middle
        }
        if (lowerBound == 0) return clipIndicesByAudioStart[0]
        val previousIndex = clipIndicesByAudioStart[lowerBound - 1]
        if (lowerBound >= clipIndicesByAudioStart.size) return previousIndex
        val nextIndex = clipIndicesByAudioStart[lowerBound]
        return if (
            clips[previousIndex].audioSrc == clips[nextIndex].audioSrc &&
            clampedTime >= clipTimings[previousIndex].audioEnd &&
            clampedTime < clipTimings[nextIndex].audioStart
        ) nextIndex else previousIndex
    }

    private fun clipIndexAtSpokenProgression(progression: Double): Int? {
        if (clips.isEmpty()) return null
        if (totalSpokenDuration <= 0.0) {
            return minOf((progression.coerceIn(0.0, 0.999_999) * clips.size).toInt(), clips.lastIndex)
        }
        val target = progression.coerceIn(0.0, 1.0) * totalSpokenDuration
        return clipTimings.indexOfFirst { it.spokenEnd >= target }.takeIf { it >= 0 } ?: clipTimings.lastIndex
    }

    private fun spokenProgression(time: Double, clipIndex: Int?): Double {
        if (totalSpokenDuration <= 0.0) return 0.0
        val index = clipIndex ?: clipIndexAtAudioTime(time) ?: return 0.0
        val clip = clips.getOrNull(index) ?: return 0.0
        val timing = clipTimings[index]
        val elapsed = audioStartBySource[clip.audioSrc]?.let { fileStart ->
            val localTime = (time - fileStart).coerceIn(clip.clipBegin, maxOf(clip.clipBegin, clip.clipEnd))
            timing.spokenStart + maxOf(0.0, localTime - clip.clipBegin)
        } ?: timing.spokenStart
        return (elapsed / totalSpokenDuration).coerceIn(0.0, 1.0)
    }

    fun readingProgression(time: Double, clipIndex: Int? = null): Double {
        if (totalAudioDuration > 0.0 && time >= totalAudioDuration) return 1.0
        val index = clipIndex ?: clipIndexAtAudioTime(time)
        index?.let(clipTextProgressions::getOrNull)?.let { return it }
        return spokenProgression(time, clipIndex)
    }

    private fun clipIndexAtReadingProgression(progression: Double): Int? {
        if (clipTextProgressions.isEmpty()) return clipIndexAtSpokenProgression(progression)
        val target = progression.coerceIn(0.0, 1.0)
        return clipTextProgressions.indexOfLast { it <= target }.takeIf { it >= 0 } ?: 0
    }

    private fun chapterProgression(time: Double, clipIndex: Int): Double {
        val clip = clips.getOrNull(clipIndex) ?: return 0.0
        val chapterIndices = clips.indices.filter { hrefMatches(clips[it].textHref, clip.textHref) }
        val chapterDuration = chapterIndices.sumOf { maxOf(0.0, clips[it].duration) }
        if (chapterDuration <= 0.0) return 0.0
        var elapsed = 0.0
        for (index in chapterIndices) {
            if (index == clipIndex) {
                val fileStart = audioStartBySource[clip.audioSrc] ?: break
                val localTime = (time - fileStart).coerceIn(clip.clipBegin, maxOf(clip.clipBegin, clip.clipEnd))
                elapsed += maxOf(0.0, localTime - clip.clipBegin)
                break
            }
            elapsed += maxOf(0.0, clips[index].duration)
        }
        return (elapsed / chapterDuration).coerceIn(0.0, 1.0)
    }

    private fun clipIndexAtChapterProgression(progression: Double, href: String): Int? {
        val chapterIndices = clips.indices.filter { hrefMatches(clips[it].textHref, href) }
        if (chapterIndices.isEmpty()) return null
        val chapterDuration = chapterIndices.sumOf { maxOf(0.0, clips[it].duration) }
        if (chapterDuration <= 0.0) return chapterIndices.first()
        val target = progression.coerceIn(0.0, 1.0) * chapterDuration
        var elapsed = 0.0
        for (index in chapterIndices) {
            elapsed += maxOf(0.0, clips[index].duration)
            if (elapsed >= target) return index
        }
        return chapterIndices.last()
    }

    fun resolveEpub3Locator(locatorJson: String): ResolvedPosition? {
        val locator = EpubCfi.jsonObject(locatorJson) ?: return null
        val locations = locator.optObject("locations") ?: return null
        val href = locator.optString("href")
        val type = locator.optString("type")?.lowercase().orEmpty()

        fun resolved(clipIndex: Int?, source: Source): ResolvedPosition? =
            clipIndex?.let { index -> clipTimings.getOrNull(index)?.let { ResolvedPosition(index, it.audioStart, source) } }

        if (type.contains("audio") || href?.lowercase()?.startsWith("audiobook://") == true) {
            return resolved(clipIndexAtSpokenProgression(locations.optDouble("totalProgression") ?: 0.0), Source.PROGRESSION)
        }
        fragments(locations).firstOrNull { !it.startsWith("t=") && !it.startsWith("epubcfi(") }
            ?.let { clipIndex(it, href) }
            ?.let { return resolved(it, Source.FRAGMENT) }
        if (href != null) {
            locations.optDouble("progression")
                ?.let { clipIndexAtChapterProgression(it, href) }
                ?.let { return resolved(it, Source.PROGRESSION) }
        }
        return locations.optDouble("totalProgression")
            ?.let(::clipIndexAtReadingProgression)
            ?.let { resolved(it, Source.PROGRESSION) }
    }

    fun textLocatorJson(clipIndex: Int, audioTime: Double): String? {
        val clip = clips.getOrNull(clipIndex) ?: return null
        val clampedAudioTime = audioTime.coerceIn(0.0, totalAudioDuration)
        return buildJsonObject {
            put("href", clip.textHref)
            put("type", "application/xhtml+xml")
            put("locations", buildJsonObject {
                put("fragments", JsonArray(listOf(JsonPrimitive(clip.fragmentId))))
                EpubCfi.idSelector(clip.fragmentId)?.let { put("cssSelector", it) }
                put("progression", chapterProgression(clampedAudioTime, clipIndex))
                put("totalProgression", readingProgression(clampedAudioTime, clipIndex).coerceIn(0.0, 1.0))
            })
        }.toString()
    }

    private fun fragments(locations: kotlinx.serialization.json.JsonObject): List<String> {
        locations.optArray("fragments")?.mapNotNull { it.stringOrNull() }?.takeIf { it.isNotEmpty() }?.let { return it }
        return listOfNotNull(
            EpubCfi.simpleIdSelector(locations.optString("cssSelector"))
                ?: EpubCfi.simpleIdSelector(locations.optObject("domRange")?.optObject("start")?.optString("cssSelector")),
        )
    }

    companion object {
        fun narrationMatchesAudio(narrationDuration: Double, audioDuration: Double): Boolean =
            narrationDuration > 0.0 && audioDuration > 0.0 && abs(narrationDuration - audioDuration) <= audioDuration * 0.01

        fun hrefMatches(lhs: String, rhs: String): Boolean {
            val a = normalizedHref(lhs)
            val b = normalizedHref(rhs)
            if (a.isEmpty() || b.isEmpty()) return a == b
            if (a == b || a.endsWith(b) || b.endsWith(a)) return true
            val fileA = a.substringAfterLast('/')
            return fileA.isNotEmpty() && fileA == b.substringAfterLast('/')
        }

        private fun normalizedHref(href: String): String =
            EpubPackage.percentDecoded(href.substringBefore('#')).trim('/').lowercase()

        fun load(epubFile: File): MediaOverlayTimeline? = EpubArchive.open(epubFile).use(::load)

        fun load(archive: EpubArchive): MediaOverlayTimeline? {
            val spine = archive.epubPackage.spine
            val clips = ArrayList<Clip>()
            val audioDurations = HashMap<String, Double>()
            for (item in spine) {
                val smilPath = item.mediaOverlayHref ?: continue
                val smil = try {
                    archive.html(smilPath)
                } catch (_: IOException) {
                    continue
                }
                val parsed = SmilClipHandler(smilPath.substringBeforeLast('/', "")).also { parseXml(smil, it) }.clips
                val sources = parsed.map { it.audioSrc }.distinct()
                val overlayDuration = item.mediaOverlayDuration
                if (sources.size == 1 && overlayDuration != null) {
                    audioDurations[sources[0]] = maxOf(audioDurations[sources[0]] ?: 0.0, overlayDuration)
                }
                clips += parsed
            }
            if (clips.isEmpty()) return null
            return MediaOverlayTimeline(clips, audioDurations, textProgressions(archive, clips))
        }

        private fun textProgressions(archive: EpubArchive, clips: List<Clip>): List<Double> {
            val linear = archive.epubPackage.spine.filter { it.isLinear }
            val positionCounts = linear.map { maxOf(1L, ceil(archive.archivedLength(it.href) / 1024.0).toLong()) }
            val totalPositions = positionCounts.sum().toDouble()
            val spanByHref = HashMap<String, Pair<Double, Double>>()
            var cursor = 0L
            for ((item, count) in linear.zip(positionCounts)) {
                spanByHref.putIfAbsent(item.href, cursor / totalPositions to count / totalPositions)
                cursor += count
            }
            val fractionsByHref = clips.map { it.textHref }.distinct().associateWith { href ->
                val spineIndex = archive.epubPackage.spine.indexOfFirst { it.href == href }
                if (spineIndex < 0) return emptyList()
                val document = archive.document(spineIndex)
                val textIndex = document.textIndex()
                clips.asSequence().filter { it.textHref == href }.mapNotNull { clip ->
                    document.element(clip.fragmentId)?.let {
                        clip.fragmentId to textIndex.offset(EpubCfi.Point(it, null)).toDouble() / maxOf(1, textIndex.length)
                    }
                }.toMap()
            }
            return clips.map { clip ->
                val (start, span) = spanByHref[clip.textHref] ?: return emptyList()
                val fraction = fractionsByHref[clip.textHref]?.get(clip.fragmentId) ?: return emptyList()
                (start + fraction * span).coerceIn(0.0, 1.0)
            }
        }
    }

    private class SmilClipHandler(private val smilDirectory: String) : XmlHandler() {
        val clips = ArrayList<Clip>()
        private var textSrc: String? = null
        private var audio: Triple<String, Double?, Double?>? = null

        override fun startElement(uri: String?, localName: String?, qName: String, attributes: Attributes) {
            when (qName.substringAfterLast(':')) {
                "par" -> {
                    textSrc = null
                    audio = null
                }
                "text" -> if (textSrc == null) textSrc = attributes.getValue("src")
                "audio" -> if (audio == null) {
                    attributes.getValue("src")?.let { src ->
                        audio = Triple(
                            src,
                            attributes.getValue("clipBegin")?.let(::clockSeconds),
                            attributes.getValue("clipEnd")?.let(::clockSeconds),
                        )
                    }
                }
            }
        }

        override fun endElement(uri: String?, localName: String?, qName: String) {
            if (qName.substringAfterLast(':') != "par") return
            val text = textSrc?.split('#', limit = 2) ?: return
            val (audioSrc, clipBegin, clipEnd) = audio ?: return
            val audioParts = audioSrc.split('#', limit = 2)
            val mediaFragment = audioParts.getOrNull(1)?.substringAfter("t=", "")?.split(',')
            val begin = clipBegin ?: mediaFragment?.getOrNull(0)?.let(::clockSeconds) ?: 0.0
            val end = clipEnd ?: mediaFragment?.getOrNull(1)?.let(::clockSeconds) ?: begin
            clips += Clip(
                fragmentId = text.getOrElse(1) { "" },
                textHref = archivePath(text[0]),
                audioSrc = archivePath(audioParts[0]),
                clipBegin = begin,
                clipEnd = maxOf(begin, end),
            )
        }

        private fun archivePath(href: String): String {
            val decoded = EpubPackage.percentDecoded(href)
            return EpubPackage.resolvingDotSegments(if (smilDirectory.isEmpty()) decoded else "$smilDirectory/$decoded")
        }
    }
}
