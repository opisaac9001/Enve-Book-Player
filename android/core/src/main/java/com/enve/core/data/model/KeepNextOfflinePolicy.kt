package com.enve.core.data.model

import com.enve.core.data.util.NaturalSort

object KeepNextOfflinePolicy {
    fun seriesCandidates(current: Book, books: List<Book>): List<Book> {
        val series = current.seriesName?.trim()?.takeIf(String::isNotEmpty) ?: return emptyList()
        val ordered = books
            .filter { book ->
                book.source == current.source &&
                    book.connectionId == current.connectionId &&
                    book.libraryId == current.libraryId &&
                    book.mediaType == AppMediaType.AUDIOBOOK &&
                    book.seriesName?.trim()?.equals(series, ignoreCase = true) == true
            }
            .sortedWith { left, right ->
                NaturalSort.compare(left.seriesNumber, right.seriesNumber)
                    .takeIf { it != 0 }
                    ?: NaturalSort.compare(left.title, right.title)
            }

        val currentIndex = ordered.indexOfFirst { it.uniqueKey == current.uniqueKey }
        if (currentIndex < 0) return emptyList()
        return ordered.drop(currentIndex + 1).filterNot { it.isCompleteForKeepOffline() }
    }

    fun downloadsNeeded(
        candidates: List<Book>,
        targetCount: Int,
        isKeptOffline: (Book) -> Boolean,
    ): List<Book> = candidates.take(targetCount.coerceAtLeast(1)).filterNot(isKeptOffline)

    private fun Book.isCompleteForKeepOffline(): Boolean =
        isFinished || readStatus == ReadStatus.COMPLETED || readProgress >= 0.999f
}
