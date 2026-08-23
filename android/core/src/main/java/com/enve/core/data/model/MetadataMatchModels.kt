package com.enve.core.data.model

import java.text.Normalizer
import kotlin.math.max
import kotlin.math.min

enum class MetadataMatchProvider(val displayName: String) {
    GOOGLE_BOOKS("Google Books"),
    OPEN_LIBRARY("Open Library"),
}

data class MetadataMatchCandidate(
    val id: String,
    val provider: MetadataMatchProvider,
    val title: String,
    val author: String?,
    val publisher: String?,
    val publishedDate: String?,
    val pageCount: Int?,
    val seriesName: String?,
    val seriesNumber: String?,
    val isbn13: String?,
    val language: String?,
    val description: String?,
    val confidence: Int,
    val matchReason: String,
)

data class UnmatchedMetadataBook(
    val book: Book,
    val missingFields: List<String>,
    val completeness: Int,
) {
    val summary: String
        get() = missingFields.take(3).joinToString(", ")
}

object MetadataMatchAnalyzer {
    fun unmatchedBooks(
        books: List<Book>,
        locallyMatchedKeys: Set<String>,
    ): List<UnmatchedMetadataBook> =
        books
            .distinctBy { it.uniqueKey }
            .filter { it.title.isNotBlank() }
            .mapNotNull { book ->
                if (book.uniqueKey in locallyMatchedKeys) return@mapNotNull null
                val missing = missingFields(book)
                val completeness = completeness(book)
                if (missing.size >= 3 || completeness < 62) {
                    UnmatchedMetadataBook(book, missing, completeness)
                } else {
                    null
                }
            }
            .sortedWith(
                compareBy<UnmatchedMetadataBook> { it.completeness }
                    .thenBy { it.book.title.lowercase() },
            )

    fun scoreCandidate(
        book: Book,
        provider: MetadataMatchProvider,
        id: String,
        title: String,
        author: String?,
        publisher: String?,
        publishedDate: String?,
        pageCount: Int?,
        seriesName: String?,
        seriesNumber: String?,
        isbn13: String?,
        language: String?,
        description: String?,
    ): MetadataMatchCandidate? {
        val cleanTitle = title.trim()
        if (cleanTitle.isBlank()) return null

        val titleScore = titleSimilarity(normalize(book.title), normalize(cleanTitle))
        val authorScore = tokenSimilarity(normalize(book.author.orEmpty()), normalize(author.orEmpty()))
        val isbnMatch = normalizedIsbn(book.isbn13).isNotEmpty() && normalizedIsbn(book.isbn13) == normalizedIsbn(isbn13)

        val baseScore = when {
            isbnMatch -> 100
            titleScore >= 0.98f && authorScore >= 0.82f -> 96
            titleScore >= 0.92f && authorScore >= 0.72f -> 90
            titleScore >= 0.86f && (authorScore >= 0.65f || book.author.isNullOrBlank() || author.isNullOrBlank()) -> 84
            titleScore >= 0.74f && authorScore >= 0.72f -> 76
            titleScore >= 0.68f && book.author.isNullOrBlank() -> 68
            else -> return null
        }

        val richnessBonus = listOfNotNull(publisher, publishedDate, pageCount, isbn13, language, description)
            .take(4)
            .size
        val confidence = (baseScore + richnessBonus).coerceAtMost(100)
        val reason = when {
            isbnMatch -> "ISBN match"
            titleScore >= 0.98f && authorScore >= 0.82f -> "Exact title and author"
            titleScore >= 0.92f -> "Strong title match"
            else -> "Possible title and author match"
        }

        return MetadataMatchCandidate(
            id = id,
            provider = provider,
            title = cleanTitle,
            author = author.clean(),
            publisher = publisher.clean(),
            publishedDate = publishedDate.clean(),
            pageCount = pageCount?.takeIf { it > 0 },
            seriesName = seriesName.clean(),
            seriesNumber = seriesNumber.clean(),
            isbn13 = isbn13.clean(),
            language = language.clean(),
            description = description.clean(),
            confidence = confidence,
            matchReason = reason,
        )
    }

    private fun missingFields(book: Book): List<String> = buildList {
        if (book.author.isNullOrBlank()) add("author")
        if (book.description.isNullOrBlank()) add("description")
        if (book.publisher.isNullOrBlank()) add("publisher")
        if (book.publishedDate.isNullOrBlank()) add("published date")
        if (book.isbn13.isNullOrBlank()) add("ISBN")
        if (book.language.isNullOrBlank()) add("language")
        if (book.pageCount == null && book.mediaType == AppMediaType.EBOOK) add("page count")
    }

    private fun completeness(book: Book): Int {
        val fields = listOf(
            book.title,
            book.author,
            book.description,
            book.publisher,
            book.publishedDate,
            book.isbn13,
            book.language,
            book.pageCount?.toString(),
        )
        val present = fields.count { !it.isNullOrBlank() }
        return ((present.toFloat() / fields.size.toFloat()) * 100).toInt()
    }

    private fun normalizedIsbn(value: String?): String =
        value.orEmpty().filter { it.isDigit() || it == 'X' || it == 'x' }.uppercase()

    private fun normalize(value: String): String {
        val stripped = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFD)
            .replace(Regex("""\p{Mn}+"""), "")
        return stripped
            .replace("&", " and ")
            .replace(Regex("""['’]s\b"""), "")
            .replace(Regex("""\([^)]*\)|\[[^]]*]"""), " ")
            .replace(Regex("""\b(the|a|an|book|volume|vol|edition|unabridged)\b"""), " ")
            .replace(Regex("""[^a-z0-9]+"""), " ")
            .replace(Regex("""\s+"""), " ")
            .trim()
    }

    private fun tokenSimilarity(left: String, right: String): Float {
        if (left.isBlank() || right.isBlank()) return 0f
        if (left == right) return 1f
        val leftTokens = left.tokenSet()
        val rightTokens = right.tokenSet()
        if (leftTokens.isEmpty() || rightTokens.isEmpty()) return 0f
        val intersection = leftTokens.intersect(rightTokens).size.toFloat()
        return intersection / min(leftTokens.size, rightTokens.size)
    }

    private fun titleSimilarity(left: String, right: String): Float {
        if (left.isBlank() || right.isBlank()) return 0f
        if (left == right) return 1f
        val leftTokens = left.tokenSet()
        val rightTokens = right.tokenSet()
        if (leftTokens.isEmpty() || rightTokens.isEmpty()) return 0f
        val intersection = leftTokens.intersect(rightTokens).size.toFloat()
        val union = leftTokens.union(rightTokens).size.toFloat()
        val minTokenCount = min(leftTokens.size, rightTokens.size)
        val overlap = intersection / minTokenCount
        val jaccard = intersection / union
        val tokenScore = if (minTokenCount == 1 && leftTokens.size != rightTokens.size) {
            jaccard
        } else {
            overlap * 0.85f + jaccard * 0.15f
        }
        val containment = if (left.contains(right) || right.contains(left)) {
            min(left.length, right.length).toFloat() / max(left.length, right.length)
        } else {
            0f
        }
        return max(max(jaccard, tokenScore), containment)
    }

    private fun String.tokenSet(): Set<String> =
        split(' ')
            .asSequence()
            .map { it.trim() }
            .filter { it.length > 1 }
            .toSet()

    private fun String?.clean(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
}
