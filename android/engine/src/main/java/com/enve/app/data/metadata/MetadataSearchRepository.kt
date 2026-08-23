package com.enve.app.data.metadata

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import org.jsoup.Jsoup
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class MetadataSearchRepository @Inject constructor(
    private val audibleClient: AudibleMetadataClient,
    private val googleBooksClient: GoogleBooksMetadataClient,
    private val openLibraryClient: OpenLibraryMetadataClient,
) {
    fun defaultQuery(book: Book): String {
        return MetadataScoring.defaultSearchQuery(book.title, book.author)
    }

    suspend fun search(book: Book, rawQuery: String): List<MetadataMatchCandidate> {
        val query = MetadataScoring.normalizeSearchQuery(rawQuery)
        if (query.isBlank()) return emptyList()
        return when (book.mediaType) {
            AppMediaType.AUDIOBOOK -> searchAudiobook(book, query)
            AppMediaType.EBOOK -> searchBook(book, query)
            AppMediaType.PODCAST -> emptyList()
        }
    }

    suspend fun enrichSelectedCandidate(candidate: MetadataMatchCandidate): MetadataMatchCandidate {
        return when (candidate.source) {
            MetadataCandidateSource.AUDIOBOOK_CATALOG -> enrichAudiobookCandidate(candidate)
            MetadataCandidateSource.GOOGLE_BOOKS -> enrichGoogleCandidate(candidate)
            MetadataCandidateSource.OPEN_LIBRARY -> enrichOpenLibraryCandidate(candidate)
        }
    }

    private suspend fun searchAudiobook(book: Book, query: String): List<MetadataMatchCandidate> {
        val snapshot = book.audioSnapshotForMatching()
        val parsed = MetadataScoring.parseTitleAndAuthor(query)
        val trimmedUpper = parsed.first.trim().uppercase()
        val hits = if (audibleClient.looksLikeAsin(trimmedUpper)) {
            listOfNotNull(runCatching { audibleClient.lookup(trimmedUpper) }.getOrNull())
        } else {
            val searchString = parsed.second?.let { "${parsed.first} $it" } ?: query
            audibleClient.search(searchString, limit = 50)
        }
        return hits
            .map { it.toCandidate(snapshot) }
            .dedupeAndRank()
    }

    private suspend fun searchBook(book: Book, query: String): List<MetadataMatchCandidate> = coroutineScope {
        val parsed = MetadataScoring.parseTitleAndAuthor(query)
        val snapshot = book.ebookSnapshotForMatching(parsed)
        val googleQuery = googleBooksQuery(query, parsed, book)
        val openLibraryQuery = parsed.second?.let { "${parsed.first} $it" } ?: parsed.first

        val google = async {
            runCatching {
                googleBooksClient.search(
                    query = googleQuery.query,
                    author = googleQuery.author,
                    isbn = googleQuery.isbn,
                    limit = 10,
                ).map { it.toCandidate(snapshot) }
            }.getOrDefault(emptyList())
        }
        val openLibrary = async {
            runCatching {
                openLibraryClient.search(openLibraryQuery, limit = 40).map { it.toCandidate(snapshot) }
            }.getOrDefault(emptyList())
        }

        (google.await() + openLibrary.await()).dedupeAndRank()
    }

    private suspend fun enrichAudiobookCandidate(candidate: MetadataMatchCandidate): MetadataMatchCandidate {
        val details = runCatching { audibleClient.lookup(candidate.externalId) }.getOrNull() ?: return candidate.copy(
            description = cleanDescription(candidate.description),
        )
        return candidate.copy(
            title = details.title,
            subtitle = details.subtitle ?: candidate.subtitle,
            author = details.authors.firstOrNull() ?: candidate.author,
            authors = details.authors.ifEmpty { candidate.authors },
            narrator = details.narrators.joinToString(", ").takeIf { it.isNotBlank() } ?: candidate.narrator,
            narrators = details.narrators.ifEmpty { candidate.narrators },
            publisher = details.publisher ?: candidate.publisher,
            publishedDate = details.releaseDate ?: candidate.publishedDate,
            publishedYear = yearFrom(details.releaseDate) ?: candidate.publishedYear,
            isbn = details.isbn ?: candidate.isbn,
            coverUrl = details.coverUrl ?: candidate.coverUrl,
            durationSec = details.durationSec.takeIf { it > 0L } ?: candidate.durationSec,
            seriesName = details.seriesName ?: candidate.seriesName,
            seriesPosition = details.seriesPosition ?: candidate.seriesPosition,
            description = cleanDescription(details.description ?: candidate.description),
            categories = details.categories.ifEmpty { candidate.categories },
            language = details.language ?: candidate.language,
        )
    }

    private suspend fun enrichGoogleCandidate(candidate: MetadataMatchCandidate): MetadataMatchCandidate {
        val details = runCatching { googleBooksClient.getVolume(candidate.externalId) }.getOrNull() ?: return candidate.copy(
            description = cleanDescription(candidate.description),
        )
        return candidate.copy(
            title = details.title?.takeIf { it.isNotBlank() } ?: candidate.title,
            subtitle = details.subtitle ?: candidate.subtitle,
            author = details.authors.firstOrNull() ?: candidate.author,
            authors = details.authors.ifEmpty { candidate.authors },
            publisher = details.publisher ?: candidate.publisher,
            publishedDate = details.publishedDate ?: candidate.publishedDate,
            publishedYear = yearFrom(details.publishedDate) ?: candidate.publishedYear,
            isbn = details.isbn ?: candidate.isbn,
            coverUrl = details.imageLinks?.best ?: candidate.coverUrl,
            pageCount = details.pageCount ?: candidate.pageCount,
            description = cleanDescription(details.description ?: candidate.description),
            categories = details.categories.ifEmpty { candidate.categories },
            language = details.language ?: candidate.language,
        )
    }

    private suspend fun enrichOpenLibraryCandidate(candidate: MetadataMatchCandidate): MetadataMatchCandidate {
        val description = runCatching { openLibraryClient.getWorkDescription(candidate.externalId) }.getOrNull()
        return candidate.copy(description = cleanDescription(description ?: candidate.description))
    }

    private fun AudiobookCatalogItem.toCandidate(snapshot: MetadataMatchFileSnapshot): MetadataMatchCandidate {
        val base = MetadataMatchCandidate(
            id = "audio:$asin",
            externalId = asin,
            source = MetadataCandidateSource.AUDIOBOOK_CATALOG,
            mediaType = AppMediaType.AUDIOBOOK,
            title = title,
            subtitle = subtitle,
            author = authors.firstOrNull(),
            authors = authors,
            narrator = narrators.joinToString(", ").takeIf { it.isNotBlank() },
            narrators = narrators,
            publisher = publisher,
            publishedDate = releaseDate,
            publishedYear = yearFrom(releaseDate),
            isbn = isbn,
            coverUrl = coverUrl,
            durationSec = durationSec.takeIf { it > 0L },
            seriesName = seriesName,
            seriesPosition = seriesPosition,
            description = cleanDescription(description),
            categories = categories,
            language = language,
            confidence = 0.0,
            matchReason = "",
        )
        val score = MetadataScoring.calculateAudioScore(snapshot, base)
        return base.copy(confidence = score.total, matchReason = MetadataScoring.confidenceLabel(score.total))
    }

    private fun GoogleBookItem.toCandidate(snapshot: MetadataMatchFileSnapshot): MetadataMatchCandidate {
        val score = MetadataScoring.calculateBookScore(
            file = snapshot,
            title = title.orEmpty(),
            authors = authors,
            isbn = isbn,
        )
        return MetadataMatchCandidate(
            id = "google:$volumeId",
            externalId = volumeId,
            source = MetadataCandidateSource.GOOGLE_BOOKS,
            mediaType = AppMediaType.EBOOK,
            title = title.orEmpty(),
            subtitle = subtitle,
            author = authors.firstOrNull(),
            authors = authors,
            publisher = publisher,
            publishedDate = publishedDate,
            publishedYear = yearFrom(publishedDate),
            isbn = isbn,
            coverUrl = imageLinks?.best,
            pageCount = pageCount,
            description = cleanDescription(description),
            categories = categories,
            language = language,
            confidence = score.total,
            matchReason = MetadataScoring.confidenceLabel(score.total),
        )
    }

    private fun OpenLibraryItem.toCandidate(snapshot: MetadataMatchFileSnapshot): MetadataMatchCandidate {
        val score = MetadataScoring.calculateBookScore(
            file = snapshot,
            title = title.orEmpty(),
            authors = authors,
            isbn = isbn,
        )
        return MetadataMatchCandidate(
            id = "open:${key}",
            externalId = key,
            source = MetadataCandidateSource.OPEN_LIBRARY,
            mediaType = AppMediaType.EBOOK,
            title = title.orEmpty(),
            author = authors.firstOrNull(),
            authors = authors,
            publisher = publisher,
            publishedYear = firstPublishYear,
            isbn = isbn,
            coverUrl = coverId?.let(openLibraryClient::coverUrl),
            pageCount = pageCount,
            categories = subjects,
            language = language,
            confidence = score.total,
            matchReason = MetadataScoring.confidenceLabel(score.total),
        )
    }

    private fun Book.audioSnapshotForMatching(): MetadataMatchFileSnapshot {
        val parsedSeriesNumber = seriesNumber?.toDoubleOrNull()?.toInt()
        return MetadataMatchFileSnapshot(
            title = title,
            author = author,
            durationSec = duration,
            isbn = isbn13,
            seriesNumber = parsedSeriesNumber,
        )
    }

    private fun Book.ebookSnapshotForMatching(parsedQuery: Pair<String, String?>): MetadataMatchFileSnapshot {
        val parsedSeriesNumber = seriesNumber?.toDoubleOrNull()?.toInt()
        return MetadataMatchFileSnapshot(
            title = parsedQuery.first,
            author = parsedQuery.second,
            durationSec = 0L,
            isbn = isbn13,
            seriesNumber = parsedSeriesNumber,
        )
    }

    private fun googleBooksQuery(
        query: String,
        parsed: Pair<String, String?>,
        book: Book,
    ): GoogleQuery {
        val isbn = book.isbn13?.trim().orEmpty()
        if (isbn.isNotBlank()) {
            val sameAsBookTitle = query.equals(book.title, ignoreCase = true) ||
                parsed.first.equals(book.title, ignoreCase = true)
            if (query.isBlank() || sameAsBookTitle) {
                return GoogleQuery(parsed.first, parsed.second, isbn)
            }
        }
        return GoogleQuery(parsed.first, parsed.second, null)
    }

    private fun List<MetadataMatchCandidate>.dedupeAndRank(): List<MetadataMatchCandidate> {
        return filter { it.title.isNotBlank() }
            .groupBy { MetadataScoring.normalizedIdentity(it.title, it.author, it.publishedYear) }
            .map { (_, group) -> group.maxWithOrNull(compareBy<MetadataMatchCandidate> { it.confidence }.thenBy { it.completenessScore() })!! }
            .sortedWith(compareByDescending<MetadataMatchCandidate> { it.confidence }.thenByDescending { it.completenessScore() })
    }

    private fun MetadataMatchCandidate.completenessScore(): Double {
        var score = 0.0
        if (!coverUrl.isNullOrBlank()) score += 0.04
        if (!description.isNullOrBlank()) score += 0.04
        if (!publisher.isNullOrBlank()) score += 0.02
        if (!seriesName.isNullOrBlank()) score += 0.02
        if ((durationSec ?: 0L) > 0L || pageCount != null) score += 0.02
        if (isbn != null) score += 0.02
        return score
    }

    private fun cleanDescription(value: String?): String? {
        val raw = value?.takeIf { it.isNotBlank() } ?: return null
        return Jsoup.parse(raw).text().replace("\\s+".toRegex(), " ").trim().takeIf { it.isNotBlank() }
    }

    private fun yearFrom(value: String?): Int? {
        return value?.take(4)?.toIntOrNull()
    }

    private data class GoogleQuery(val query: String, val author: String?, val isbn: String?)
}
