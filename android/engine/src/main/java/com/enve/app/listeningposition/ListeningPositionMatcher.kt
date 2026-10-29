package com.enve.app.listeningposition

import com.enve.app.data.metadata.MetadataScoring
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.engine.listeningposition.ListeningPositionCandidate
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToLong

object ListeningPositionMatcher {
    fun rank(books: List<Book>, payload: ListeningPositionPayload): List<ListeningPositionCandidate> = books
        .filter { (payload.readingLocation != null) == (it.mediaType == AppMediaType.EBOOK) }
        .distinctBy { it.uniqueKey }.map { evaluate(it, payload) }
        .sortedWith(compareByDescending<ListeningPositionCandidate> { it.hasCredibleIdentity }.thenByDescending { it.score }.thenBy { it.book.title })

    fun evaluate(book: Book, payload: ListeningPositionPayload): ListeningPositionCandidate {
        val identifier = payload.isbn != null && book.isbn13?.let(ListeningPositionPayload::normalizedISBN) == payload.isbn
        val title = max(MetadataScoring.calculateTitleScore(payload.title, book.title), MetadataScoring.calculateTitleScore(book.title, payload.title))
        val authorsKnown = payload.authors.isNotEmpty() && !book.author.isNullOrBlank()
        val author = if (authorsKnown) payload.authors.maxOf { MetadataScoring.calculateAuthorScore(it, listOf(book.author!!)) } else 0.5
        val credible = identifier || title >= 0.85 && (!authorsKnown || author >= 0.8)
        val warnings = mutableListOf<String>()
        if (!credible) {
            if (title < 0.85) warnings += "The title doesn't match the shared book."
            if (authorsKnown && author < 0.8) warnings += "The author doesn't match the shared book."
        }
        val reading = payload.readingLocation
        if (reading != null) {
            val sameFormat = reading.format == SharedReadingLocation.format(book)
            if (!sameFormat) warnings += "Different reading format; the shared percentage is approximate across editions."
            if (reading.pageCount != null && book.pageCount != null && reading.pageCount != book.pageCount) {
                warnings += "The page counts differ. The same page may show a different passage."
            }
            if (reading.page == null) warnings += "This is a saved reading percentage; editions may place the passage differently."
            val beyondEnd = sameFormat && reading.page != null && (book.pageCount ?: 0) > 0 && reading.page!! > book.pageCount!!
            if (beyondEnd) warnings += "The shared page is past the end of this copy."
            return ListeningPositionCandidate(book, (0.7 * title + 0.3 * author + if (identifier) 0.2 else 0.0).coerceIn(0.0, 1.0),
                credible, warnings, book.mediaType == AppMediaType.EBOOK && !beyondEnd)
        }
        val length = if (book.duration > 0) MetadataScoring.calculateDurationScore(payload.durationMilliseconds / 1000.0, book.duration.toDouble()) else 0.1
        if (book.duration <= 0) warnings += "This copy's length is unknown. The position can only be saved on this device."
        else {
            val difference = abs(book.duration.toDouble() - payload.durationMilliseconds / 1000.0)
            if (difference > 120) warnings += "Length differs by about ${(difference / 60).roundToLong().coerceAtLeast(1)} min; the same time may land on a different passage."
        }
        val beyondEnd = book.duration > 0 && payload.positionMilliseconds / 1000.0 > book.duration
        if (beyondEnd) warnings += "The shared time is past the end of this copy."
        var narrator = 0.5
        if (payload.narrators.isNotEmpty() && !book.narrator.isNullOrBlank()) {
            val names = book.narrator.orEmpty().split(',', ';', '&')
            narrator = if (payload.narrators.maxOf { MetadataScoring.calculateAuthorScore(it, names) } >= 0.8) 1.0 else 0.0
            if (narrator == 0.0) warnings += "Different narrator, which usually means a different recording."
        }
        val differentSeriesPosition = payload.series != null && payload.seriesSequence != null &&
            book.seriesName?.let(MetadataScoring::cleanTitleForCompare) == MetadataScoring.cleanTitleForCompare(payload.series.orEmpty()) &&
            book.seriesNumber != null && sequence(book.seriesNumber.orEmpty()) != sequence(payload.seriesSequence.orEmpty())
        if (differentSeriesPosition) warnings += "A different book in the series."
        val score = (0.55 * title + 0.25 * author + 0.15 * length + 0.05 * narrator +
            (if (identifier) 0.2 else 0.0) - (if (differentSeriesPosition) 0.3 else 0.0)).coerceIn(0.0, 1.0)
        return ListeningPositionCandidate(book, score, credible, warnings, book.mediaType != AppMediaType.EBOOK && !beyondEnd)
    }

    private fun sequence(value: String): String = value.trim().toDoubleOrNull()?.toString() ?: value.trim().lowercase(java.util.Locale.ROOT)
}
