package com.enve.app.data.reader.search

import android.os.SystemClock
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.positionsByReadingOrder
import org.readium.r2.shared.util.mediatype.MediaType

private const val FINGERPRINT_FAILED = "Enve couldn't read this book's file."
private const val OPEN_FAILED = "Enve couldn't open this book's search index."
private const val INDEX_FAILED = "Enve couldn't build this book's search index."
private const val READ_FAILED = "Enve couldn't read this book's search index."

private const val SCAN_PAGE_SIZE = 64
private const val EMIT_INTERVAL_MS = 250L
private const val SNIPPET_BEFORE = 120
private const val SNIPPET_AFTER = 180

class EbookSearchException(message: String, cause: Throwable? = null) : Exception(message, cause)

data class EbookSearchUpdate(
    val results: List<Locator>,
    val indexedSections: Int,
    val totalSections: Int,
    val indexing: Boolean,
    val hasMore: Boolean,
)

@Singleton
class EbookSearchService @Inject constructor(
    private val indexStore: EbookSearchIndexStore,
) {
    fun search(
        publication: Publication,
        epubFile: File,
        query: String,
        wholeWords: Boolean,
        limit: Int,
    ): Flow<EbookSearchUpdate> {
        require(limit >= 1) { "limit must be at least 1" }
        return flow {
            val trimmed = query.trim()
            if (trimmed.isEmpty() || trimmed.length > SearchText.MAX_QUERY_LENGTH) {
                throw EbookSearchException("Search for 1 to ${SearchText.MAX_QUERY_LENGTH} characters.")
            }
            if (publication.readingOrder.isEmpty()) {
                emit(EbookSearchUpdate(emptyList(), 0, 0, indexing = false, hasMore = false))
                return@flow
            }
            val fingerprint = friendlySearch(FINGERPRINT_FAILED) {
                EbookSearchFingerprint.compute(epubFile)
            }
            val handle = friendlySearch(OPEN_FAILED) { indexStore.acquire(fingerprint) }
            try {
                EbookSearchSession(publication, handle, trimmed, wholeWords, limit).run(this)
            } finally {
                withContext(NonCancellable) { indexStore.release(fingerprint) }
            }
        }.flowOn(Dispatchers.IO)
    }
}

private inline fun <T> friendlySearch(message: String, block: () -> T): T =
    try {
        block()
    } catch (error: CancellationException) {
        throw error
    } catch (error: EbookSearchException) {
        throw error
    } catch (error: Exception) {
        throw EbookSearchException(message, error)
    }

private class SearchHit(val sectionIndex: Int, val start: Int, val end: Int) {
    val key: Long = (sectionIndex.toLong() shl 32) or (start.toLong() and 0xFFFF_FFFFL)
}

private class EbookSearchSession(
    private val publication: Publication,
    private val handle: EbookSearchIndexHandle,
    query: String,
    private val wholeWords: Boolean,
    private val limit: Int,
) {
    private val dao = handle.database.searchDao()
    private val indexer = EbookSearchIndexer(publication, handle.database)
    private val readingOrder = publication.readingOrder
    private val total = readingOrder.size
    private val cap = limit + 1

    private val foldedQuery = SearchText.fold(query)
    private val normalizedQuery = SearchText.collapse(foldedQuery)
    private val ftsMatch = ftsMatchOrNull()

    private var headingHits: List<SearchHit> = emptyList()
    private val bodyHits = mutableListOf<SearchHit>()
    private var cursorSection = -1
    private var cursorChunk = -1

    private val locatorCache = HashMap<Long, Locator>()
    private val sectionLengths = HashMap<Int, Int>()
    private var positions: List<List<Locator>>? = null
    private var lastEmitAt = 0L
    private var snippetSection = -1
    private var snippetRows: List<SearchChunkText> = emptyList()

    suspend fun run(collector: FlowCollector<EbookSearchUpdate>) {
        val complete = friendlySearch(READ_FAILED) {
            dao.meta(META_COMPLETE) == META_TRUE && dao.sectionCount() == total
        }
        if (complete) {
            refreshHeadings(total - 1)
            advanceBody(total - 1)
            collector.emit(update(total, indexing = false))
            return
        }
        handle.indexMutex.withLock {
            val present = friendlySearch(READ_FAILED) { dao.indexedSections() }.toHashSet()
            currentCoroutineContext().ensureActive()
            collector.emit(update(present.size, indexing = true))
            for (section in 0 until total) {
                currentCoroutineContext().ensureActive()
                if (present.add(section)) {
                    friendlySearch(INDEX_FAILED) { indexer.index(section) }
                }
                refreshHeadings(section)
                advanceBody(section)
                emitThrottled(collector, present.size)
            }
            friendlySearch(INDEX_FAILED) { indexer.markComplete(total) }
        }
        currentCoroutineContext().ensureActive()
        collector.emit(update(total, indexing = false))
    }

    private fun ftsMatchOrNull(): String? {
        if (!wholeWords || !SearchText.isAscii(foldedQuery)) return null
        val tokens = SearchText.asciiTokens(foldedQuery)
        return if (tokens.isEmpty()) null else SearchText.ftsPhrase(tokens)
    }

    private suspend fun refreshHeadings(maxSection: Int) {
        if (headingHits.size >= cap || normalizedQuery.isEmpty()) return
        headingHits = friendlySearch(READ_FAILED) {
            dao.headingMatches(normalizedQuery, maxSection, cap)
        }.map { SearchHit(it.sectionIndex, it.startOffset, it.endOffset) }
    }

    private suspend fun advanceBody(maxSection: Int) {
        while (bodyHits.size < cap) {
            currentCoroutineContext().ensureActive()
            val page = friendlySearch(READ_FAILED) {
                if (ftsMatch != null) {
                    dao.matchedChunksAfter(ftsMatch, cursorSection, cursorChunk, maxSection, SCAN_PAGE_SIZE)
                } else {
                    dao.chunksAfter(cursorSection, cursorChunk, maxSection, SCAN_PAGE_SIZE)
                }
            }
            if (page.isEmpty()) return
            for (chunk in page) {
                currentCoroutineContext().ensureActive()
                cursorSection = chunk.sectionIndex
                cursorChunk = chunk.chunkIndex
                val offsets = SearchText.matches(
                    folded = chunk.folded,
                    foldedQuery = foldedQuery,
                    wholeWords = wholeWords,
                    minMatchEnd = 0,
                    limit = SearchText.CHUNK_SIZE,
                )
                if (offsets.isEmpty()) continue
                val normalized = SearchText.normalize(chunk.text)
                for (offset in offsets) {
                    val start = chunk.startOffset + normalized.starts[offset]
                    if (start >= chunk.ownedEnd) break
                    val end = chunk.startOffset + normalized.ends[offset + foldedQuery.length - 1]
                    if (wholeWords && start == chunk.startOffset && start > 0) {
                        val previous = textWindow(chunk.sectionIndex, (start - 2).coerceAtLeast(0), start)
                        if (previous.isNotEmpty() && Character.isLetterOrDigit(previous.codePointBefore(previous.length))) continue
                    }
                    bodyHits += SearchHit(chunk.sectionIndex, start, end)
                    if (bodyHits.size >= cap) break
                }
                if (bodyHits.size >= cap) return
            }
            if (page.size < SCAN_PAGE_SIZE) return
        }
    }

    private suspend fun emitThrottled(collector: FlowCollector<EbookSearchUpdate>, indexedSections: Int) {
        val now = SystemClock.elapsedRealtime()
        if (now - lastEmitAt < EMIT_INTERVAL_MS) return
        lastEmitAt = now
        currentCoroutineContext().ensureActive()
        collector.emit(update(indexedSections, indexing = true))
    }

    private suspend fun update(indexedSections: Int, indexing: Boolean): EbookSearchUpdate {
        currentCoroutineContext().ensureActive()
        val merged = mutableListOf<SearchHit>()
        val seen = HashSet<Long>()
        for (hit in headingHits) {
            if (merged.size >= cap) break
            if (seen.add(hit.key)) merged += hit
        }
        for (hit in bodyHits) {
            if (merged.size >= cap) break
            if (seen.add(hit.key)) merged += hit
        }
        return EbookSearchUpdate(
            results = merged.take(limit).map { locatorFor(it) },
            indexedSections = indexedSections,
            totalSections = total,
            indexing = indexing,
            hasMore = merged.size > limit,
        )
    }

    private suspend fun locatorFor(hit: SearchHit): Locator {
        currentCoroutineContext().ensureActive()
        locatorCache[hit.key]?.let { return it }
        val link = readingOrder[hit.sectionIndex]
        val base = publication.locatorFromLink(link)
            ?: Locator(href = link.url(), mediaType = link.mediaType ?: MediaType.XHTML)
        val textLength = sectionLength(hit.sectionIndex)
        val progression = if (textLength > 0) {
            (hit.start.toDouble() / textLength).coerceIn(0.0, 1.0)
        } else {
            0.0
        }
        val anchor = positionsFor(hit.sectionIndex)
            .lastOrNull { (it.locations.progression ?: 0.0) <= progression }
        val windowStart = (hit.start - SNIPPET_BEFORE).coerceAtLeast(0)
        val windowEnd = (hit.end + SNIPPET_AFTER).coerceAtMost(textLength)
        val window = friendlySearch(READ_FAILED) { textWindow(hit.sectionIndex, windowStart, windowEnd) }
        val highlightStart = (hit.start - windowStart).coerceIn(0, window.length)
        val highlightEnd = (hit.end - windowStart).coerceIn(highlightStart, window.length)
        val locator = base.copy(
            title = base.title?.takeIf { it.isNotBlank() } ?: "Section ${hit.sectionIndex + 1}",
            locations = base.locations.copy(
                progression = progression,
                totalProgression = anchor?.locations?.totalProgression ?: base.locations.totalProgression,
                position = anchor?.locations?.position ?: base.locations.position,
            ),
            text = Locator.Text(
                before = window.substring(0, highlightStart).takeIf { it.isNotEmpty() },
                highlight = window.substring(highlightStart, highlightEnd).takeIf { it.isNotEmpty() },
                after = window.substring(highlightEnd).takeIf { it.isNotEmpty() },
            ),
        )
        locatorCache[hit.key] = locator
        return locator
    }

    private suspend fun textWindow(sectionIndex: Int, start: Int, end: Int): String {
        if (end <= start) return ""
        if (snippetSection != sectionIndex || snippetRows.isEmpty() ||
            snippetRows.first().startOffset > start || snippetRows.last().endOffset < end
        ) {
            snippetRows = dao.chunkText(sectionIndex, start, end + SearchText.CHUNK_SIZE * 2)
            snippetSection = sectionIndex
        }
        val builder = StringBuilder(end - start)
        var cursor = start
        for (row in snippetRows) {
            if (row.endOffset <= cursor) continue
            val from = maxOf(cursor, row.startOffset)
            val to = minOf(end, row.endOffset)
            if (to <= from) continue
            builder.append(row.text, from - row.startOffset, to - row.startOffset)
            cursor = to
            if (cursor >= end) break
        }
        return builder.toString()
    }

    private suspend fun sectionLength(sectionIndex: Int): Int {
        sectionLengths[sectionIndex]?.let { return it }
        val length = friendlySearch(READ_FAILED) { dao.sectionLength(sectionIndex) } ?: 0
        sectionLengths[sectionIndex] = length
        return length
    }

    private suspend fun positionsFor(sectionIndex: Int): List<Locator> {
        var all = positions
        if (all == null) {
            all = try {
                publication.positionsByReadingOrder()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                emptyList()
            }
            positions = all
        }
        return all.getOrNull(sectionIndex).orEmpty()
    }
}
