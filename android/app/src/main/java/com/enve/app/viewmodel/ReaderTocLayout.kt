package com.enve.app.viewmodel

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.epub.pageList
import org.readium.r2.shared.util.Url
import kotlin.math.roundToInt

data class TocEntry(val id: String, val title: String, val href: String, val depth: Int)

data class TocPageCount(val pages: Int, val estimated: Boolean)

data class ChapterMark(val start: Float, val title: String)

internal data class EpubPageMarker(
    val label: String,
    val progression: Double,
)

internal data class ReadiumTocLayout(
    val pageCounts: Map<String, TocPageCount>,
    val chapterMarks: List<ChapterMark>,
    val entryStarts: Map<String, Double>,
)

private data class TocPageBoundary(
    val position: Double,
    val containingPage: Int,
    val pagesBefore: Int,
    val exactStart: Boolean,
    val exactEnd: Boolean,
)

private const val MAX_CHAPTER_DEPTH = 2
private const val MAX_CHAPTER_MARKS = 60
private const val CHAPTER_MERGE_DISTANCE = 0.004f

internal fun readerChapterMarks(candidates: List<Pair<Int, ChapterMark>>): List<ChapterMark> {
    val deepest = candidates.maxOfOrNull { it.first }?.coerceAtMost(MAX_CHAPTER_DEPTH) ?: return emptyList()
    return (deepest downTo 0).asSequence()
        .map { depth -> mergeNearbyChapterMarks(candidates.filter { it.first <= depth }.map { it.second }) }
        .firstOrNull { it.size <= MAX_CHAPTER_MARKS }
        .orEmpty()
}

private fun mergeNearbyChapterMarks(marks: List<ChapterMark>): List<ChapterMark> {
    val merged = mutableListOf<ChapterMark>()
    marks.sortedBy { it.start }.forEach { mark ->
        val last = merged.lastOrNull()
        if (last != null && mark.start - last.start < CHAPTER_MERGE_DISTANCE) merged[merged.lastIndex] = last.copy(title = mark.title)
        else merged += mark
    }
    return merged
}

internal fun parsePublicationHref(href: String?): Url? {
    if (href.isNullOrBlank()) return null
    return Url(href) ?: Url.fromDecodedPath(href)
}

internal fun normalizePublicationHref(href: String?): String? =
    parsePublicationHref(href)?.normalize()?.removeFragment()?.toString()

internal suspend fun readResourceText(pub: Publication, link: Link): String? = withContext(Dispatchers.IO) {
    val resource = pub.get(link) ?: return@withContext null
    try {
        resource.read().getOrNull()?.toString(Charsets.UTF_8)
    } finally {
        resource.close()
    }
}

internal fun publicationTocEntries(pub: Publication): List<TocEntry> = buildList {
    fun append(links: List<Link>, depth: Int) {
        links.forEach { link ->
            val href = link.url().toString()
            val title = link.title?.trim().takeUnless { it.isNullOrEmpty() }
                ?: href.substringBefore('#').substringAfterLast('/').ifBlank { "Untitled" }
            add(TocEntry(id = "${size}:$depth:$href", title = title, href = href, depth = depth))
            append(link.children, depth + 1)
        }
    }
    append(pub.tableOfContents, 0)
}

internal fun currentTocEntry(
    entries: List<TocEntry>,
    entryStarts: Map<String, Double>,
    locator: Locator,
): TocEntry? {
    val locatorHref = normalizePublicationHref(locator.href.toString()) ?: return null
    val candidates = entries.filter { entry ->
        val entryHref = normalizePublicationHref(entry.href)
        entryHref == locatorHref || entryHref?.endsWith(locatorHref) == true || locatorHref.endsWith(entryHref.orEmpty())
    }
    if (candidates.isEmpty()) return null

    val locatorFragments = locator.locations.fragments.toSet()
    val progression = locator.locations.totalProgression
    return candidates.firstOrNull { entry ->
        entry.href.substringAfter('#', missingDelimiterValue = "") in locatorFragments
    } ?: progression?.let { current ->
        candidates.lastOrNull { entry -> entryStarts[entry.id]?.let { it <= current + 0.0005 } == true }
    } ?: candidates.firstOrNull { it.title == locator.title } ?: candidates.first()
}

internal suspend fun readiumTocLayout(
    pub: Publication,
    entries: List<TocEntry>,
    positions: List<Locator>,
    pageMarkers: List<EpubPageMarker>,
): ReadiumTocLayout {
    val resourceIndex = pub.readingOrder.withIndex().mapNotNull { (index, link) ->
        normalizePublicationHref(link.url().toString())?.let { it to index }
    }.toMap()
    val targets = entries.map { entry ->
        resourceIndex[normalizePublicationHref(entry.href)]?.let { resource ->
            resource to parsePublicationHref(entry.href)?.fragment?.takeIf(String::isNotEmpty)
        }
    }
    val fragmentFractions = HashMap<Pair<Int, String>, Double>()
    targets.mapNotNull { target -> target?.second?.let { target.first to it } }
        .groupBy({ it.first }, { it.second })
        .forEach { (resource, fragments) ->
            val html = readResourceText(pub, pub.readingOrder[resource]) ?: return@forEach
            fragments.distinct().forEach { fragment ->
                fragmentFraction(html, fragment)?.let { fragmentFractions[resource to fragment] = it }
            }
        }
    val firstPositionOfResource = HashMap<Int, Int>()
    val positionCountOfResource = HashMap<Int, Int>()
    positions.forEachIndexed { index, locator ->
        resourceIndex[normalizePublicationHref(locator.href.toString())]?.let { resource ->
            firstPositionOfResource.putIfAbsent(resource, index)
            positionCountOfResource.merge(resource, 1, Int::plus)
        }
    }
    fun positionOf(resource: Int, fragment: String?): Double? {
        val first = firstPositionOfResource[resource] ?: return null
        val fraction = if (fragment == null) 0.0 else fragmentFractions[resource to fragment] ?: return null
        return first + fraction * positionCountOfResource.getValue(resource)
    }
    val totalPositions = positions.size.toDouble()
    val entryStarts = entries.zip(targets).mapNotNull { (entry, target) ->
        target?.let { (resource, fragment) -> positionOf(resource, fragment) }?.let { entry.id to it / totalPositions }
    }.toMap()
    val chapterMarks = readerChapterMarks(entries.mapNotNull { entry ->
        entryStarts[entry.id]?.let { entry.depth to ChapterMark(it.toFloat(), entry.title) }
    })

    val pageList = pub.pageList
    val pageResources = pageList.mapNotNull { resourceIndex[normalizePublicationHref(it.url().toString())] }
    val pageResourcesOrdered = pageResources.isNotEmpty() &&
        pageResources.size == pageList.size &&
        pageMarkers.size == pageList.size &&
        pageResources.zipWithNext().all { (previous, next) -> next >= previous }
    if (!pageResourcesOrdered) {
        val counts = tocPageCounts(
            entries = entries,
            starts = targets.map { target -> target?.let { (resource, fragment) -> positionOf(resource, fragment) } },
            bookEnd = totalPositions,
        ) { start, end -> estimatedTocPageCount(start, end, totalPositions) }
        return ReadiumTocLayout(counts, chapterMarks, entryStarts)
    }

    var page = 0
    val firstPageOfResource = IntArray(pub.readingOrder.size) { resource ->
        while (page < pageResources.size && pageResources[page] < resource) page++
        page
    }
    fun progressionAt(position: Double): Double? {
        val index = position.toInt().coerceIn(0, positions.lastIndex)
        val base = positions[index].locations.totalProgression ?: return null
        val next = positions.getOrNull(index + 1)?.locations?.totalProgression ?: 1.0
        return (base + (position - index) * (next - base)).takeIf { it.isFinite() }
    }
    fun boundaryOf(resource: Int, fragment: String?): TocPageBoundary? {
        val position = positionOf(resource, fragment) ?: return null
        if (fragment == null) {
            val firstPage = firstPageOfResource[resource]
            val firstPageInResource = firstPage < pageResources.size && pageResources[firstPage] == resource
            val pageAtResourceStart = firstPageInResource && pageList[firstPage].url().fragment == null
            return TocPageBoundary(
                position = position,
                containingPage = if (pageAtResourceStart) firstPage else firstPage - 1,
                pagesBefore = firstPage,
                exactStart = pageAtResourceStart || !firstPageInResource,
                exactEnd = true,
            )
        }
        val progression = progressionAt(position) ?: return null
        return TocPageBoundary(
            position = position,
            containingPage = pageMarkers.indexOfLast { it.progression <= progression },
            pagesBefore = pageMarkers.count { it.progression < progression },
            exactStart = false,
            exactEnd = false,
        )
    }
    val counts = tocPageCounts(
        entries = entries,
        starts = targets.map { target -> target?.let { (resource, fragment) -> boundaryOf(resource, fragment) } },
        bookEnd = TocPageBoundary(totalPositions, pageList.lastIndex, pageList.size, exactStart = true, exactEnd = true),
    ) { start, end ->
        val pages = end.pagesBefore - start.containingPage.coerceAtLeast(0)
        TocPageCount(pages, estimated = !start.exactStart || !end.exactEnd)
            .takeIf { end.position > start.position && pages > 0 }
    }
    return ReadiumTocLayout(counts, chapterMarks, entryStarts)
}

internal fun foliateTocPageCounts(
    entries: List<TocEntry>,
    progressions: List<Double?>,
    totalPages: Int,
): Map<String, TocPageCount> {
    val total = totalPages.toDouble()
    return tocPageCounts(
        entries = entries,
        starts = progressions.map { it?.times(total) },
        bookEnd = total,
    ) { start, end -> estimatedTocPageCount(start, end, total) }
}

internal fun foliateChapterMarks(entries: List<TocEntry>, progressions: List<Double?>): List<ChapterMark> =
    readerChapterMarks(entries.zip(progressions)
        .mapNotNull { (entry, start) -> start?.let { entry.depth to ChapterMark(it.toFloat(), entry.title) } })

private fun fragmentFraction(html: String, fragment: String): Double? {
    val attribute = Regex("""\s(?:id|name)\s*=\s*(["'])${Regex.escape(fragment)}\1""").find(html) ?: return null
    val tagStart = html.lastIndexOf('<', attribute.range.first)
    if (tagStart < 0) return null
    return tagStart.toDouble() / html.length
}

private fun estimatedTocPageCount(start: Double, end: Double, total: Double): TocPageCount? {
    if (!start.isFinite() || !end.isFinite() || start < 0.0 || end > total || end <= start) return null
    val pages = (end - start).roundToInt()
    return TocPageCount(pages, estimated = true).takeIf { pages > 0 }
}

private fun <T : Any> tocPageCounts(
    entries: List<TocEntry>,
    starts: List<T?>,
    bookEnd: T,
    count: (start: T, end: T) -> TocPageCount?,
): Map<String, TocPageCount> {
    if (starts.size != entries.size) return emptyMap()
    val counts = HashMap<String, TocPageCount>()
    fun close(index: Int, end: T?) {
        val start = starts[index] ?: return
        if (end == null) return
        count(start, end)?.let { counts[entries[index].id] = it }
    }
    val open = ArrayDeque<Int>()
    entries.forEachIndexed { index, entry ->
        while (open.isNotEmpty() && entries[open.last()].depth >= entry.depth) {
            close(open.removeLast(), starts[index])
        }
        open.addLast(index)
    }
    while (open.isNotEmpty()) close(open.removeLast(), bookEnd)
    return counts
}
