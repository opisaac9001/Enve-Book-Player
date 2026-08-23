package com.enve.core.data.model

data class LinkedBookCandidate(
    val ebook: Book,
    val audiobook: Book,
    val confidence: Int,
)

data class LinkedBookMatch(
    val book: Book,
    val confidence: Int,
)

object BookLinkAnalyzer {
    private const val MIN_CONFIDENCE = 88

    fun findPairs(books: List<Book>): List<LinkedBookCandidate> {
        val candidates = books
            .asSequence()
            .filter { it.title.isNotBlank() }
            .distinctBy { it.uniqueKey }
            .toList()
        val ebooks = candidates.filter { it.mediaType == AppMediaType.EBOOK && !it.hasAudio }
        val audiobooks = candidates.filter { it.mediaType == AppMediaType.AUDIOBOOK && !it.hasEbook }
        if (ebooks.isEmpty() || audiobooks.isEmpty()) return emptyList()

        val scored = ebooks.flatMap { ebook ->
            audiobooks.mapNotNull { audiobook ->
                val score = BookIdentity.linkScore(ebook, audiobook)
                if (score >= MIN_CONFIDENCE) LinkedBookCandidate(ebook, audiobook, score) else null
            }
        }
        if (scored.isEmpty()) return emptyList()

        val bestByEbook = scored.bestBy { it.ebook.uniqueKey }
        val bestByAudiobook = scored.bestBy { it.audiobook.uniqueKey }
        return bestByEbook.values
            .filter { candidate ->
                bestByAudiobook[candidate.audiobook.uniqueKey]?.ebook?.uniqueKey == candidate.ebook.uniqueKey
            }
            .sortedWith(
                compareByDescending<LinkedBookCandidate> { it.confidence }
                    .thenBy { it.ebook.title.lowercase() }
                    .thenBy { it.ebook.uniqueKey },
            )
    }

    fun rankMatches(forBook: Book, books: List<Book>, limit: Int = Int.MAX_VALUE): List<LinkedBookMatch> {
        val targetType = when (forBook.mediaType) {
            AppMediaType.EBOOK -> AppMediaType.AUDIOBOOK
            AppMediaType.AUDIOBOOK -> AppMediaType.EBOOK
            else -> return emptyList()
        }
        return books.asSequence()
            .filter { it.uniqueKey != forBook.uniqueKey }
            .filter { it.title.isNotBlank() }
            .filter { it.mediaType == targetType }
            .distinctBy { it.uniqueKey }
            .map { candidate ->
                LinkedBookMatch(
                    book = candidate,
                    confidence = when (forBook.mediaType) {
                        AppMediaType.EBOOK -> BookIdentity.linkScore(forBook, candidate)
                        AppMediaType.AUDIOBOOK -> BookIdentity.linkScore(candidate, forBook)
                    },
                )
            }
            .sortedWith(
                compareByDescending<LinkedBookMatch> { it.confidence }
                    .thenByDescending { sameConnectionScore(forBook, it.book) }
                    .thenByDescending { sameSourceScore(forBook, it.book) }
                    .thenBy { it.book.title.lowercase() }
                    .thenBy { it.book.uniqueKey },
            )
            .take(limit)
            .toList()
    }

    private fun List<LinkedBookCandidate>.bestBy(key: (LinkedBookCandidate) -> String): Map<String, LinkedBookCandidate> =
        groupBy(key).mapValues { (_, candidates) ->
            candidates.maxWith(
                compareBy<LinkedBookCandidate> { it.confidence }
                    .thenBy { sameConnectionScore(it) }
                    .thenBy { sameSourceScore(it) }
                    .thenBy { it.audiobook.uniqueKey },
            )
        }

    private fun sameConnectionScore(candidate: LinkedBookCandidate): Int =
        sameConnectionScore(candidate.ebook, candidate.audiobook)

    private fun sameSourceScore(candidate: LinkedBookCandidate): Int =
        sameSourceScore(candidate.ebook, candidate.audiobook)

    private fun sameConnectionScore(left: Book, right: Book): Int =
        if (!left.connectionId.isNullOrBlank() && left.connectionId == right.connectionId) 1 else 0

    private fun sameSourceScore(left: Book, right: Book): Int =
        if (left.source == right.source) 1 else 0
}
