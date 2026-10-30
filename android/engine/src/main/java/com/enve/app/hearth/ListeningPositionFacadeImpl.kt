package com.enve.app.hearth

import com.enve.app.listeningposition.ListeningPositionApplier
import com.enve.app.listeningposition.ListeningPositionMatcher
import com.enve.app.listeningposition.LiveListeningPositionProgressTarget
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.engine.listeningposition.*
import com.enve.engine.playback.PlaybackFacade
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ListeningPositionFacadeImpl @Inject constructor(
    private val cache: BookCacheDao,
    private val playback: PlaybackFacade,
    private val connections: ConnectionRegistry,
    target: LiveListeningPositionProgressTarget,
) : ListeningPositionFacade {
    private val applier = ListeningPositionApplier(target)

    override fun share(book: Book): ListeningPositionPayload? {
        val live = book.mediaType != AppMediaType.EBOOK && playback.nowPlaying.value?.bookKey == book.uniqueKey
        val snapshot = playback.transport.value
        return if (live) ListeningPositionPayload.from(book, snapshot.positionMs, snapshot.durationMs.takeIf { it > 0 } ?: book.duration * 1000L)
            else ListeningPositionPayload.from(book)
    }

    override suspend fun suggestions(payload: ListeningPositionPayload): List<ListeningPositionCandidate> {
        val queries = listOfNotNull(payload.title.substringBefore(':').substringBefore(" - "),
            payload.title.split(Regex("[^\\p{L}\\p{N}]+" )).maxByOrNull { it.length }?.takeIf { it.length >= 4 },
            payload.authors.firstOrNull()).filter(String::isNotBlank).distinct()
        val books = queries.flatMap { cache.searchPositionBooksByMetadata(it, mediaTypes(payload)).map { row -> row.toBook() } } +
            payload.series?.let { cache.booksWhereSeries(it).map { row -> row.toBook() } }.orEmpty()
        return labels(withContext(Dispatchers.Default) { ListeningPositionMatcher.rank(books, payload).filter { it.hasCredibleIdentity }.take(60) })
    }

    override suspend fun search(payload: ListeningPositionPayload, query: String): List<ListeningPositionCandidate> {
        if (query.isBlank()) return emptyList()
        val books = cache.searchPositionBooksByMetadata(query.trim(), mediaTypes(payload)).map { it.toBook() }
        return labels(withContext(Dispatchers.Default) { ListeningPositionMatcher.rank(books, payload).take(100) })
    }

    private fun mediaTypes(payload: ListeningPositionPayload): List<String> =
        if (payload.readingLocation != null) listOf(AppMediaType.EBOOK.name)
        else listOf(AppMediaType.AUDIOBOOK.name, AppMediaType.PODCAST.name)

    private suspend fun labels(candidates: List<ListeningPositionCandidate>): List<ListeningPositionCandidate> {
        val sources = connections.connections.first()
        return candidates.map { candidate ->
            val source = sources.firstOrNull { it.id == candidate.book.connectionId }
            candidate.copy(sourceLabel = source?.let { listOf(it.name, it.username, android.net.Uri.parse(it.serverUrl).host.orEmpty()).filter(String::isNotBlank).distinct().joinToString(" · ") })
        }
    }

    override suspend fun apply(payload: ListeningPositionPayload, book: Book): ListeningPositionApplyResult = applier.apply(payload, book)
}
