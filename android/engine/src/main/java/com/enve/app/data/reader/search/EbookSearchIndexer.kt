package com.enve.app.data.reader.search

import androidx.room.withTransaction
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.withContext
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.TextNode
import org.jsoup.parser.Parser
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.getOrElse
import org.readium.r2.shared.util.data.decodeString
import org.readium.r2.shared.util.mediatype.MediaType

private const val HEADING_SELECTOR = "h1, h2, h3, h4, h5, h6, dt"
private const val MAX_HEADING_LENGTH = 300
private const val MAX_HEADINGS_PER_SECTION = 20_000
private const val MAX_HEADING_HTML_LENGTH = 16 * 1024 * 1024
private const val CHUNK_INSERT_BATCH = 32

@OptIn(ExperimentalReadiumApi::class)
internal class EbookSearchIndexer(
    private val publication: Publication,
    private val database: EbookSearchIndexDatabase,
) {
    suspend fun index(sectionIndex: Int) {
        val link = publication.readingOrder[sectionIndex]
        if (!(link.mediaType ?: MediaType.XHTML).isHtml) {
            commit(sectionIndex, "", emptyList())
            return
        }
        val resource = publication.get(link) ?: throw EbookSearchException("A book section could not be opened.")
        val html = try {
            resource.read().getOrElse { throw EbookSearchException("A book section could not be read.") }
                .decodeString().getOrElse { throw EbookSearchException("A book section could not be decoded.") }
        } finally {
            resource.close()
        }
        currentCoroutineContext().ensureActive()
        val document = Jsoup.parse(html)
        val text = Parser.unescapeEntities(document.body().text(), false)
        val headings = if (html.length <= MAX_HEADING_HTML_LENGTH) headingRanges(sectionIndex, document, text) else emptyList()
        commit(sectionIndex, text, headings)
    }

    suspend fun markComplete(totalSections: Int) {
        val dao = database.searchDao()
        currentCoroutineContext().ensureActive()
        withContext(NonCancellable) {
            database.withTransaction {
                if (dao.sectionCount() == totalSections) {
                    dao.putMeta(SearchMetaEntity(META_COMPLETE, META_TRUE))
                }
            }
        }
    }

    private suspend fun headingRanges(
        sectionIndex: Int,
        document: Document,
        text: String,
    ): List<SearchHeadingEntity> {
        if (text.isEmpty() || text.any { it in '\uE000'..'\uE002' }) return emptyList()
        val headings = document.body().select(HEADING_SELECTOR)
            .filter { it.text().length in 1..MAX_HEADING_LENGTH }.take(MAX_HEADINGS_PER_SECTION)
        if (headings.isEmpty()) return emptyList()
        headings.forEachIndexed { index, heading ->
            currentCoroutineContext().ensureActive()
            heading.prependChild(TextNode("\uE000$index\uE001"))
            heading.appendChild(TextNode("\uE002$index\uE001"))
        }
        val marked = Parser.unescapeEntities(document.body().text(), false)
        val rebuilt = StringBuilder(text.length)
        val starts = IntArray(headings.size)
        val ends = IntArray(headings.size)
        var previous = 0
        for (marker in Regex("([\uE000\uE002])(\\d+)\uE001").findAll(marked)) {
            currentCoroutineContext().ensureActive()
            rebuilt.append(marked, previous, marker.range.first)
            val index = marker.groupValues[2].toInt()
            if (marker.groupValues[1][0] == '\uE000') starts[index] = rebuilt.length
            else ends[index] = rebuilt.length
            previous = marker.range.last + 1
        }
        rebuilt.append(marked, previous, marked.length)
        if (rebuilt.toString() != text) return emptyList()
        return headings.indices.mapNotNull { index ->
            if (ends[index] <= starts[index]) return@mapNotNull null
            SearchHeadingEntity(
                sectionIndex = sectionIndex,
                startOffset = starts[index],
                endOffset = ends[index],
                normalized = SearchText.fold(text.substring(starts[index], ends[index])).trim(),
            )
        }
    }

    private suspend fun commit(
        sectionIndex: Int,
        text: String,
        headings: List<SearchHeadingEntity>,
    ) {
        val dao = database.searchDao()
        currentCoroutineContext().ensureActive()
        withContext(NonCancellable) {
            database.withTransaction {
                dao.insertSection(SearchSectionEntity(sectionIndex, text.length))
                if (headings.isNotEmpty()) dao.insertHeadings(headings)
                val batch = mutableListOf<SearchChunkEntity>()
                val starts = SearchText.chunkStarts(text.length).map { start ->
                    if (start > 0 && text[start].isLowSurrogate() && text[start - 1].isHighSurrogate()) start - 1 else start
                }
                starts.forEachIndexed { chunkIndex, start ->
                    var end = minOf(start + SearchText.CHUNK_SIZE, text.length)
                    if (end < text.length && text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) end++
                    val body = text.substring(start, end)
                    batch += SearchChunkEntity(
                        sectionIndex = sectionIndex,
                        chunkIndex = chunkIndex,
                        startOffset = start,
                        endOffset = end,
                        ownedEnd = starts.getOrNull(chunkIndex + 1) ?: text.length,
                        text = body,
                        folded = SearchText.fold(body),
                    )
                    if (batch.size >= CHUNK_INSERT_BATCH) {
                        dao.insertChunks(batch)
                        batch.clear()
                    }
                }
                if (batch.isNotEmpty()) dao.insertChunks(batch)
            }
        }
    }
}
