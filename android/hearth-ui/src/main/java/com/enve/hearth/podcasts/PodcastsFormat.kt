package com.enve.hearth.podcasts

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

val Book.isPodcastShow: Boolean
    get() = mediaType == AppMediaType.PODCAST && episodeId == null

val Book.isFeedOnlyEpisode: Boolean
    get() = podcastEnclosureUrl != null

object PodcastsFormat {
    private val lineBreakTags = Regex("<br\\s*/?>|</(p|li|div|h[1-6])>", RegexOption.IGNORE_CASE)
    private val tags = Regex("<[^>]+>")
    private val entities = Regex("&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);")
    private val horizontalSpace = Regex("[ \\t\\u00A0]+")
    private val paddedNewline = Regex(" *\\n *")
    private val extraBlankLines = Regex("\\n{3,}")
    private val namedEntities = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ",
        "hellip" to "…", "mdash" to "—", "ndash" to "–", "lsquo" to "‘", "rsquo" to "’", "ldquo" to "“", "rdquo" to "”",
    )

    fun cleanHTML(text: String): String =
        text.replace(lineBreakTags, "\n")
            .replace(tags, "")
            .let(::decodeEntities)
            .replace(horizontalSpace, " ")
            .replace(paddedNewline, "\n")
            .replace(extraBlankLines, "\n\n")
            .trim()

    fun isStarted(episode: Book): Boolean = episode.currentTime > 0L || episode.readProgress > 0f

    fun isInProgress(episode: Book): Boolean = isStarted(episode) && !episode.isFinished

    fun publishedDate(
        epochMillis: Long,
        locale: Locale = Locale.getDefault(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String? {
        if (epochMillis <= 0L) return null
        return DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)
            .withLocale(locale)
            .format(Instant.ofEpochMilli(epochMillis).atZone(zone))
    }

    fun duration(seconds: Long): String = if (seconds < 60L) "${seconds}s" else Book.formatDuration(seconds)

    fun sortedAndFiltered(episodes: List<Book>, query: String, newestFirst: Boolean): List<Book> {
        val sorted = if (newestFirst) episodes.sortedByDescending { it.addedOn } else episodes.sortedBy { it.addedOn }
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return sorted
        return sorted.filter {
            it.title.contains(trimmed, ignoreCase = true) ||
                it.description?.let(::cleanHTML)?.contains(trimmed, ignoreCase = true) == true
        }
    }

    private fun decodeEntities(text: String): String = entities.replace(text) { match ->
        val entity = match.groupValues[1]
        val codePoint = when {
            entity.startsWith("#x", ignoreCase = true) -> entity.drop(2).toIntOrNull(16)
            entity.startsWith("#") -> entity.drop(1).toIntOrNull()
            else -> return@replace namedEntities[entity] ?: match.value
        }
        codePoint?.takeIf(Character::isValidCodePoint)?.let { String(Character.toChars(it)) } ?: match.value
    }
}
