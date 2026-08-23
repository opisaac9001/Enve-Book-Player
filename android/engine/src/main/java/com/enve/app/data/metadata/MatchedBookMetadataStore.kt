package com.enve.app.data.metadata

import com.enve.core.data.model.Book
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MatchedBookMetadataStore @Inject constructor(
    private val dao: MatchedBookMetadataDao,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    suspend fun saveMatch(book: Book, candidate: MetadataMatchCandidate): Book {
        val entity = candidate.toEntity(book, metadataKeyFor(book), json)
        dao.upsert(entity)
        return apply(book, entity)
    }

    suspend fun applyStoredMetadata(book: Book): Book {
        val entity = dao.get(metadataKeyFor(book)) ?: return book
        return apply(book, entity)
    }

    suspend fun applyStoredMetadata(books: List<Book>): List<Book> {
        if (books.isEmpty()) return books
        val byKey = dao.getForKeys(books.map(::metadataKeyFor).distinct()).associateBy { it.metadataKey }
        return books.map { book -> byKey[metadataKeyFor(book)]?.let { apply(book, it) } ?: book }
    }

    fun metadataKeyFor(book: Book): String = "${book.source.name}:${book.id}"

    private fun apply(book: Book, metadata: MatchedBookMetadata): Book {
        val categories = decodeCategories(metadata.categoriesJson).ifEmpty { book.categories }
        return book.copy(
            title = metadata.title.nonBlankOr(book.title) ?: book.title,
            subtitle = metadata.subtitle.nonBlankOr(book.subtitle),
            author = metadata.author.nonBlankOr(book.author),
            narrator = metadata.narrator.nonBlankOr(book.narrator),
            description = metadata.description.nonBlankOr(book.description),
            coverUrl = metadata.coverUrl.nonBlankOr(book.coverUrl),
            duration = metadata.durationSec?.takeIf { it > 0L } ?: book.duration,
            seriesName = metadata.seriesName.nonBlankOr(book.seriesName),
            seriesNumber = metadata.seriesNumber.nonBlankOr(book.seriesNumber),
            publisher = metadata.publisher.nonBlankOr(book.publisher),
            publishedDate = metadata.publishedDate.nonBlankOr(book.publishedDate)
                ?: metadata.publishedYear?.toString()
                ?: book.publishedDate,
            isbn13 = metadata.isbn.nonBlankOr(book.isbn13),
            language = metadata.language.nonBlankOr(book.language),
            pageCount = metadata.pageCount ?: book.pageCount,
            categories = categories,
        )
    }

    private fun decodeCategories(value: String): List<String> {
        return runCatching { json.decodeFromString<List<String>>(value) }.getOrDefault(emptyList())
    }

    private fun MetadataMatchCandidate.toEntity(
        book: Book,
        metadataKey: String,
        json: Json,
    ): MatchedBookMetadata {
        val cleanCategories = categories.mapNotNull { it.trim().takeIf(String::isNotBlank) }.distinct()
        return MatchedBookMetadata(
            metadataKey = metadataKey,
            bookId = book.id,
            source = book.source.name,
            mediaType = mediaType.name,
            matchSource = source.name,
            externalId = externalId,
            title = title.takeIf(String::isNotBlank),
            subtitle = subtitle?.takeIf(String::isNotBlank),
            author = author?.takeIf(String::isNotBlank),
            narrator = narrator?.takeIf(String::isNotBlank),
            publisher = publisher?.takeIf(String::isNotBlank),
            publishedDate = publishedDate?.takeIf(String::isNotBlank),
            publishedYear = publishedYear,
            isbn = isbn?.takeIf(String::isNotBlank),
            coverUrl = coverUrl?.takeIf(String::isNotBlank),
            durationSec = durationSec?.takeIf { it > 0L },
            pageCount = pageCount,
            seriesName = seriesName?.takeIf(String::isNotBlank),
            seriesNumber = seriesPosition?.takeIf(String::isNotBlank),
            description = description?.takeIf(String::isNotBlank),
            categoriesJson = json.encodeToString(cleanCategories),
            language = language?.takeIf(String::isNotBlank),
            rawJson = runCatching { json.encodeToString(this) }.getOrNull(),
            updatedAt = System.currentTimeMillis(),
        )
    }

    private fun String?.nonBlankOr(fallback: String?): String? = this?.takeIf { it.isNotBlank() } ?: fallback
}
