package com.enve.app.data.discover

import com.enve.core.data.model.Book
import com.enve.core.data.model.MetadataMatchAnalyzer
import com.enve.core.data.model.MetadataMatchProvider

object DiscoverLibraryMatcher {
    fun match(
        sections: List<DiscoverSection>,
        libraryBooks: List<Book>,
    ): Map<String, Book> {
        if (sections.isEmpty() || libraryBooks.isEmpty()) return emptyMap()
        val candidates = libraryBooks
            .asSequence()
            .filter { it.title.isNotBlank() }
            .distinctBy { it.uniqueKey }
            .toList()
        if (candidates.isEmpty()) return emptyMap()

        return sections
            .flatMap { it.books }
            .distinctBy { it.id }
            .mapNotNull { discover ->
                val match = matchBook(discover, candidates) ?: return@mapNotNull null
                discover.id to match
            }
            .toMap()
    }

    fun matchBook(
        discover: DiscoverBook,
        libraryBooks: List<Book>,
    ): Book? {
        val isbn13 = discover.collectionId
            ?.filter(Char::isDigit)
            ?.takeIf { it.length == 13 }
        if (isbn13 != null) {
            libraryBooks.firstOrNull { it.isbn13?.filter(Char::isDigit) == isbn13 }?.let { return it }
        }

        return libraryBooks
            .asSequence()
            .mapNotNull { book ->
                val score = MetadataMatchAnalyzer.scoreCandidate(
                    book = book,
                    provider = MetadataMatchProvider.GOOGLE_BOOKS,
                    id = discover.id,
                    title = discover.title,
                    author = discover.author,
                    publisher = null,
                    publishedDate = discover.publishedDate,
                    pageCount = discover.pageCount,
                    seriesName = null,
                    seriesNumber = null,
                    isbn13 = isbn13,
                    language = null,
                    description = discover.description,
                )?.confidence ?: return@mapNotNull null
                if (score < MATCH_THRESHOLD) return@mapNotNull null
                DiscoverMatch(book = book, score = score)
            }
            .sortedWith(
                compareByDescending<DiscoverMatch> { it.score }
                    .thenByDescending { it.book.lastReadTime }
                    .thenByDescending { it.book.addedOn },
            )
            .firstOrNull()
            ?.book
    }

    private data class DiscoverMatch(
        val book: Book,
        val score: Int,
    )

    private const val MATCH_THRESHOLD = 84
}
