package com.enve.app.data.podcasts

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastFeedKey
import com.enve.core.data.model.PodcastShow
import java.text.Normalizer
import java.util.Locale
import java.util.UUID
import kotlin.math.abs

private const val TITLE_MATCH_WINDOW_MS = 86_400_000L
private val diacritics = Regex("\\p{M}+")
private val whitespace = Regex("\\s+")

internal fun feedOnlyEpisodes(stored: List<PodcastFeedKey>, feed: List<PodcastFeedEpisode>): List<PodcastFeedEpisode> {
    val episodes = feed.distinctBy { it.guid }
    val indexByGuid = episodes.withIndex().associate { (index, episode) -> episode.guid to index }
    val indexByEnclosure = mutableMapOf<String, Int>()
    val indicesByTitle = mutableMapOf<String, MutableList<Int>>()
    episodes.forEachIndexed { index, episode ->
        normalizedEnclosure(episode.enclosureUrl)?.let { indexByEnclosure.putIfAbsent(it, index) }
        indicesByTitle.getOrPut(normalizedTitle(episode.title)) { mutableListOf() }.add(index)
    }

    val claimed = mutableSetOf<Int>()
    for (key in stored) {
        val byGuid = key.guid?.let(indexByGuid::get)?.takeIf { it !in claimed }
        val byEnclosure = normalizedEnclosure(key.enclosureUrl)?.let(indexByEnclosure::get)?.takeIf { it !in claimed }
        val byTitle = normalizedTitle(key.title).takeIf { it.isNotEmpty() }?.let { title ->
            indicesByTitle[title]?.firstOrNull { index ->
                index !in claimed && publishedWithinWindow(key.publishedAtMs, episodes[index].publishedAtMs)
            }
        }
        (byGuid ?: byEnclosure ?: byTitle)?.let(claimed::add)
    }
    return episodes.filterIndexed { index, _ -> index !in claimed }
}

internal fun PodcastFeedEpisode.toFeedOnlyBook(show: PodcastShow, showBook: Book): Book = Book(
    id = "${show.id}_rss_${UUID.nameUUIDFromBytes(guid.toByteArray())}",
    title = title,
    author = show.author,
    description = description,
    coverUrl = show.coverUrl,
    duration = durationSec,
    source = BookSource.AUDIOBOOKSHELF,
    mediaType = AppMediaType.PODCAST,
    libraryId = showBook.libraryId,
    connectionId = showBook.connectionId,
    addedOn = publishedAtMs ?: 0L,
    hasAudio = true,
    podcastName = show.title,
    episodeId = guid,
    podcastLibraryItemId = show.id,
    podcastEnclosureUrl = enclosureUrl,
)

private fun publishedWithinWindow(storedMs: Long?, feedMs: Long?): Boolean =
    storedMs == null || feedMs == null || abs(storedMs - feedMs) <= TITLE_MATCH_WINDOW_MS

private fun normalizedEnclosure(raw: String?): String? {
    val value = raw?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return value.substringAfter("://")
}

private fun normalizedTitle(title: String): String =
    Normalizer.normalize(title, Normalizer.Form.NFD)
        .replace(diacritics, "")
        .lowercase(Locale.ROOT)
        .trim()
        .replace(whitespace, " ")
