package com.enve.app.data.sync

import com.enve.core.data.sync.PassageAccuracy
import com.enve.core.data.sync.ProgressConflictPassage
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import org.jsoup.Jsoup
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.positionsByReadingOrder
import org.readium.r2.shared.util.getOrElse

private const val SNIPPET_LENGTH = 240
private const val MIN_ANCHOR_LENGTH = 8
private const val MIN_SECTION_TEXT_LENGTH = 20

private val WHITESPACE = Regex("\\s+")

private data class Placement(val index: Int, val fraction: Double)

@Singleton
class ProgressConflictPassageService @Inject constructor() {

    suspend fun passages(
        publication: Publication,
        localLocatorJson: String?,
        localPercentage: Float,
        remoteLocatorJson: String?,
        remotePercentage: Float,
    ): Pair<ProgressConflictPassage?, ProgressConflictPassage?> = withContext(Dispatchers.IO) {
        val readingOrder = publication.readingOrder
        if (readingOrder.isEmpty()) return@withContext null to null

        val localMatch = sectionIndexFor(localLocatorJson, readingOrder)
        val remoteMatch = sectionIndexFor(remoteLocatorJson, readingOrder)
        val positions = if (localMatch == null || remoteMatch == null) {
            try {
                publication.positionsByReadingOrder()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                emptyList()
            }
        } else {
            emptyList()
        }

        val localPlacement = placement(localMatch, localLocatorJson, localPercentage, positions, readingOrder.size)
        val remotePlacement = placement(remoteMatch, remoteLocatorJson, remotePercentage, positions, readingOrder.size)

        passage(publication, readingOrder, localPlacement.index, localLocatorJson, localPlacement.fraction) to
            passage(publication, readingOrder, remotePlacement.index, remoteLocatorJson, remotePlacement.fraction)
    }

    private fun sectionIndexFor(locatorJson: String?, readingOrder: List<Link>): Int? {
        val target = hrefFrom(locatorJson) ?: return null
        val normalized = normalizedHref(target)
        return readingOrder.indexOfFirst { normalizedHref(it.url().toString()) == normalized }.takeIf { it >= 0 }
    }

    private fun placement(
        matchedIndex: Int?,
        locatorJson: String?,
        percentage: Float,
        positions: List<List<Locator>>,
        sectionCount: Int,
    ): Placement {
        if (matchedIndex != null) return Placement(matchedIndex, resourceProgression(locatorJson) ?: 0.0)
        return place(percentage.toDouble(), positions, sectionCount)
    }

    private suspend fun passage(
        publication: Publication,
        readingOrder: List<Link>,
        index: Int,
        locatorJson: String?,
        fallbackFraction: Double,
    ): ProgressConflictPassage? {
        val link = readingOrder[index]
        val html = readHtml(publication, link) ?: return null
        val document = Jsoup.parse(html)
        val text = document.body().text().replace(WHITESPACE, " ").trim()
        if (text.length <= MIN_SECTION_TEXT_LENGTH) return null

        val title = titleFor(link, publication.tableOfContents)

        val highlight = highlightFrom(locatorJson)
        if (highlight != null && highlight.length >= MIN_ANCHOR_LENGTH) {
            val at = text.indexOf(highlight)
            if (at >= 0 && text.indexOf(highlight, at + highlight.length) < 0) {
                return ProgressConflictPassage(snippet(text, at), title, PassageAccuracy.EXACT)
            }
        }

        val fragment = fragmentIdentifier(locatorJson)
        if (fragment != null) {
            val anchored = document.getElementById(fragment)?.let { element ->
                val builder = StringBuilder(element.text())
                var sibling = element.nextElementSibling()
                while (sibling != null && builder.length < SNIPPET_LENGTH * 2) {
                    builder.append(' ').append(sibling.text())
                    sibling = sibling.nextElementSibling()
                }
                builder.toString().replace(WHITESPACE, " ").trim()
            }
            if (anchored != null && anchored.length > MIN_SECTION_TEXT_LENGTH) {
                return ProgressConflictPassage(snippet(anchored, 0), title, PassageAccuracy.EXACT)
            }
        }

        val offset = (text.length * fallbackFraction).toInt().coerceIn(0, (text.length - 1).coerceAtLeast(0))
        return ProgressConflictPassage(snippet(text, offset), title, PassageAccuracy.APPROXIMATE)
    }

    private suspend fun readHtml(publication: Publication, link: Link): String? {
        val resource = publication.get(link) ?: return null
        return try {
            resource.read().getOrElse { return null }.toString(Charsets.UTF_8)
        } finally {
            resource.close()
        }
    }

    private fun place(
        percentage: Double,
        positions: List<List<Locator>>,
        sectionCount: Int,
    ): Placement {
        val clamped = percentage.coerceIn(0.0, 1.0)
        val starts = positions.take(sectionCount)
            .map { it.firstOrNull()?.locations?.totalProgression ?: 0.0 }
        if (starts.size <= 1) {
            val index = (clamped * sectionCount).toInt().coerceIn(0, (sectionCount - 1).coerceAtLeast(0))
            return Placement(index, (clamped * sectionCount - index).coerceIn(0.0, 1.0))
        }

        var index = 0
        starts.forEachIndexed { candidate, start -> if (clamped >= start) index = candidate }
        val start = starts[index]
        val end = starts.getOrNull(index + 1) ?: 1.0
        return Placement(index, ((clamped - start) / maxOf(end - start, 0.0001)).coerceIn(0.0, 1.0))
    }

    private fun titleFor(link: Link, tableOfContents: List<Link>): String? {
        val href = normalizedHref(link.url().toString())
        val tocTitle = flattenLinks(tableOfContents).firstOrNull { toc ->
            val tocHref = normalizedHref(toc.url().toString())
            tocHref == href || tocHref.endsWith(href) || href.endsWith(tocHref)
        }?.title?.trim()
        if (!tocTitle.isNullOrBlank()) return tocTitle
        return link.title?.trim()?.takeIf { it.isNotBlank() }
    }

    private fun flattenLinks(links: List<Link>): List<Link> =
        links.flatMap { listOf(it) + flattenLinks(it.children) }

    private fun snippet(text: String, from: Int): String {
        var begin = from.coerceIn(0, (text.length - 1).coerceAtLeast(0))
        val previousSpace = text.lastIndexOf(' ', begin)
        if (begin > 0 && previousSpace >= 0) begin = previousSpace + 1

        var end = (begin + SNIPPET_LENGTH).coerceAtMost(text.length)
        if (end < text.length) {
            val lastSpace = text.lastIndexOf(' ', end)
            if (lastSpace > begin) end = lastSpace
        }
        val slice = text.substring(begin, end).trim()
        if (slice.isEmpty()) return ""
        return (if (begin > 0) "…" else "") + slice + (if (end < text.length) "…" else "")
    }

    private fun locatorJson(value: String?): JSONObject? {
        if (value.isNullOrBlank()) return null
        return runCatching { JSONObject(value) }.getOrNull()
    }

    private fun hrefFrom(value: String?): String? =
        locatorJson(value)?.optString("href")?.takeIf { it.isNotBlank() }

    private fun highlightFrom(value: String?): String? =
        locatorJson(value)?.optJSONObject("text")?.optString("highlight")?.trim()?.takeIf { it.isNotBlank() }

    private fun fragmentIdentifier(value: String?): String? {
        val candidates = mutableListOf<String>()
        hrefFrom(value)?.substringAfter('#', "")?.takeIf { it.isNotBlank() }?.let { candidates += it }
        locatorJson(value)?.optJSONObject("locations")?.optJSONArray("fragments")?.let { fragments ->
            for (index in 0 until fragments.length()) {
                fragments.optString(index).trim().removePrefix("#").takeIf { it.isNotBlank() }?.let { candidates += it }
            }
        }
        return candidates.firstOrNull {
            !it.startsWith("epubcfi(") && !it.startsWith("/") && !it.contains("=") && it.none { char -> char.isWhitespace() }
        }
    }

    private fun resourceProgression(value: String?): Double? =
        locatorJson(value)?.optJSONObject("locations")
            ?.takeIf { it.has("progression") }
            ?.optDouble("progression")
            ?.takeIf { !it.isNaN() }
            ?.coerceIn(0.0, 1.0)

    private fun normalizedHref(value: String): String = value.substringBefore("#")
}
