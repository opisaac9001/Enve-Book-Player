package com.enve.app.readium

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.html.cssSelector
import org.readium.r2.shared.publication.services.content.Content
import org.readium.r2.shared.publication.services.content.content

@OptIn(ExperimentalReadiumApi::class)
class EbookTTSContent(private val publication: Publication, private val anchor: Locator) {
    private var iterator: Content.Iterator? = null
    private val pending = ArrayDeque<EbookTTSParagraph>()

    suspend fun next(): EbookTTSParagraph? {
        if (iterator == null) {
            val content = publication.content(anchor.copy(locations = Locator.Locations(), text = Locator.Text()))
                ?.iterator() ?: error("No text content")
            val chapter = mutableListOf<EbookTTSParagraph>()
            var following: EbookTTSParagraph? = null
            while (true) {
                currentCoroutineContext().ensureActive()
                val paragraph = content.nextParagraph() ?: break
                if (paragraph.locator?.href != anchor.href) {
                    following = paragraph
                    break
                }
                chapter.add(paragraph)
            }
            val (index, offset) = speechStart(chapter, anchor)
            val first = chapter[index]
            val text = first.text.substring(offset)
            val locator = checkNotNull(first.locator)
            val remaining = chapter.drop(index + 1) + listOfNotNull(following)
            pending.clear()
            pending.add(EbookTTSParagraph(text, anchor.copy(text = Locator.Text(
                before = anchor.text.before ?: (locator.text.before.orEmpty() + first.text.take(offset)).takeLast(80).ifEmpty { null },
                highlight = text,
                after = locator.text.after,
            ))))
            pending.addAll(remaining)
            iterator = content
        }
        return pending.removeFirstOrNull() ?: checkNotNull(iterator).nextParagraph()
    }
}

@OptIn(ExperimentalReadiumApi::class)
private suspend fun Content.Iterator.nextParagraph(): EbookTTSParagraph? {
    while (hasNext()) {
        currentCoroutineContext().ensureActive()
        val element = next() as? Content.TextElement ?: continue
        if (element.text.isNotBlank()) return EbookTTSParagraph(element.text, element.locator)
    }
    return null
}

private fun speechStart(paragraphs: List<EbookTTSParagraph>, anchor: Locator): Pair<Int, Int> {
    val whitespace = Regex("[\\s\\p{Z}]+")
    fun normalized(text: String) = text.replace(whitespace, " ").trim()
    val quote = normalized(anchor.text.highlight.orEmpty())
    check(quote.isNotEmpty()) { "No visible text anchor" }
    val pattern = Regex(quote.split(' ').joinToString("[\\s\\p{Z}]+", transform = Regex::escape))
    val before = normalized(anchor.text.before.orEmpty())
    val after = normalized(anchor.text.after.orEmpty())
    var best: Pair<Int, Int>? = null
    var bestScore = -1
    var ambiguous = false
    paragraphs.forEachIndexed { index, paragraph ->
        pattern.findAll(paragraph.text).forEach { match ->
            val prefix = normalized(paragraph.locator?.text?.before.orEmpty() + paragraph.text.take(match.range.first))
            val suffix = normalized(paragraph.text.substring(match.range.last + 1) + paragraph.locator?.text?.after.orEmpty())
            val context = before.reversed().zip(prefix.reversed()).takeWhile { (a, b) -> a == b }.size +
                after.zip(suffix).takeWhile { (a, b) -> a == b }.size
            val selector = anchor.locations.cssSelector
            val sameElement = selector != null && selector == paragraph.locator?.locations?.cssSelector
            val score = context * 2 + if (sameElement) 1 else 0
            when {
                score > bestScore -> {
                    best = index to match.range.first
                    bestScore = score
                    ambiguous = false
                }
                score == bestScore -> ambiguous = true
            }
        }
    }
    check(best != null && !ambiguous) { "Cannot locate the visible passage" }
    return checkNotNull(best)
}
