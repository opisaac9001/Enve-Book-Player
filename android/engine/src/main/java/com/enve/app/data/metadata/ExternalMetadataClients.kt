package com.enve.app.data.metadata

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min
import kotlin.math.pow

data class AudiobookCatalogItem(
    val asin: String,
    val title: String,
    val subtitle: String?,
    val authors: List<String>,
    val narrators: List<String>,
    val durationSec: Long,
    val releaseDate: String?,
    val coverUrl: String?,
    val rating: Double?,
    val description: String?,
    val publisher: String?,
    val seriesName: String?,
    val seriesPosition: String?,
    val categories: List<String>,
    val language: String?,
    val isbn: String?,
)

data class GoogleBookItem(
    val volumeId: String,
    val title: String?,
    val subtitle: String?,
    val authors: List<String>,
    val publisher: String?,
    val publishedDate: String?,
    val description: String?,
    val pageCount: Int?,
    val categories: List<String>,
    val imageLinks: GoogleImageLinks?,
    val language: String?,
    val isbn: String?,
    val averageRating: Double?,
    val ratingsCount: Int?,
)

data class GoogleImageLinks(
    val smallThumbnail: String?,
    val thumbnail: String?,
    val small: String?,
    val medium: String?,
    val large: String?,
    val extraLarge: String?,
) {
    val best: String?
        get() = extraLarge ?: large ?: medium ?: small ?: thumbnail ?: smallThumbnail
}

data class OpenLibraryItem(
    val key: String,
    val title: String?,
    val authors: List<String>,
    val firstPublishYear: Int?,
    val isbn: String?,
    val coverId: Int?,
    val publisher: String?,
    val subjects: List<String>,
    val language: String?,
    val pageCount: Int?,
)

class ExternalMetadataHttpException(val statusCode: Int, message: String) : IOException(message)

@Singleton
class AudibleMetadataClient @Inject constructor(
    @ExternalMetadataHttpClient private val client: OkHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }
    private val baseUrl = "https://api.audible.com/1.0/catalog/products".toHttpUrl()

    suspend fun search(query: String, limit: Int = 50, countryCode: String = DEFAULT_COUNTRY): List<AudiobookCatalogItem> {
        val cleaned = cleanSearchQuery(query)
        if (cleaned.isBlank()) return emptyList()

        val url = baseUrl.newBuilder()
            .addQueryParameter("response_groups", RESPONSE_GROUPS_SEARCH)
            .addQueryParameter("num_results", min(limit.coerceAtLeast(1), 50).toString())
            .addQueryParameter("products_sort_by", "Relevance")
            .addQueryParameter("image_sizes", "500,1024")
            .addQueryParameter("keywords", cleaned)
            .addQueryParameter("country_code", countryCode)
            .build()

        return client.getJson<AudibleSearchResponse>(url.toString(), json)
            .products
            .map(::toCatalogItem)
            .distinctBy { it.asin }
    }

    suspend fun lookup(asin: String, countryCode: String = DEFAULT_COUNTRY): AudiobookCatalogItem? {
        val cleaned = asin.trim().uppercase()
        if (!looksLikeAsin(cleaned)) return null
        val url = baseUrl.newBuilder()
            .addPathSegment(cleaned)
            .addQueryParameter("response_groups", RESPONSE_GROUPS_DETAIL)
            .addQueryParameter("image_sizes", "500,1024")
            .addQueryParameter("country_code", countryCode)
            .build()

        return client.getJson<AudibleDetailResponse>(url.toString(), json).product.let(::toCatalogItem)
    }

    fun looksLikeAsin(raw: String): Boolean {
        val value = raw.trim().uppercase()
        return value.length == 10 && value.all { it.isDigit() || it in 'A'..'Z' }
    }

    private fun cleanSearchQuery(query: String): String {
        return query
            .replace(":", " ")
            .replace("-", " ")
            .replace("\\([^)]*\\)".toRegex(), "")
            .replace("\\[[^\\]]*\\]".toRegex(), "")
            .replace("\\s+".toRegex(), " ")
            .trim()
    }

    private fun toCatalogItem(product: AudibleProduct): AudiobookCatalogItem {
        val cover = product.productImages?.get("500") ?: product.productImages?.get("1024") ?: product.productImages?.values?.firstOrNull()
        val categories = product.genres.orEmpty().mapNotNull { it.name?.takeIf(String::isNotBlank) }.distinct()
        val series = product.series?.firstOrNull()
        return AudiobookCatalogItem(
            asin = product.asin,
            title = product.title,
            subtitle = product.subtitle,
            authors = product.authors.orEmpty().map { it.name }.filter { it.isNotBlank() },
            narrators = product.narrators.orEmpty().map { it.name }.filter { it.isNotBlank() },
            durationSec = (product.runtimeLengthMin ?: 0L) * 60L,
            releaseDate = product.releaseDate ?: product.publicationDate,
            coverUrl = cover,
            rating = product.rating?.overallDistribution?.averageRating,
            description = product.htmlDescription
                ?: product.publisherSummary
                ?: product.summary
                ?: product.productDescription
                ?: product.editorialReview
                ?: product.shortSummary,
            publisher = product.publisherName,
            seriesName = series?.title,
            seriesPosition = series?.sequence,
            categories = categories,
            language = product.language,
            isbn = product.isbn,
        )
    }

    @Serializable
    private data class AudibleSearchResponse(val products: List<AudibleProduct> = emptyList())

    @Serializable
    private data class AudibleDetailResponse(val product: AudibleProduct)

    @Serializable
    private data class AudibleProduct(
        val asin: String,
        val title: String,
        val subtitle: String? = null,
        val authors: List<AudibleContributor>? = null,
        val narrators: List<AudibleContributor>? = null,
        @SerialName("runtime_length_min") val runtimeLengthMin: Long? = null,
        @SerialName("release_date") val releaseDate: String? = null,
        @SerialName("publication_date") val publicationDate: String? = null,
        @SerialName("product_images") val productImages: Map<String, String>? = null,
        @SerialName("publisher_name") val publisherName: String? = null,
        val series: List<AudibleSeries>? = null,
        val genres: List<AudibleGenre>? = null,
        val rating: AudibleRating? = null,
        @SerialName("html_description") val htmlDescription: String? = null,
        val summary: String? = null,
        @SerialName("publisher_summary") val publisherSummary: String? = null,
        @SerialName("product_description") val productDescription: String? = null,
        @SerialName("editorial_review") val editorialReview: String? = null,
        @SerialName("short_summary") val shortSummary: String? = null,
        val language: String? = null,
        val isbn: String? = null,
    )

    @Serializable
    private data class AudibleContributor(val name: String)

    @Serializable
    private data class AudibleSeries(val title: String? = null, val sequence: String? = null)

    @Serializable
    private data class AudibleGenre(val name: String? = null)

    @Serializable
    private data class AudibleRating(
        @SerialName("overall_distribution") val overallDistribution: AudibleRatingDistribution? = null,
    )

    @Serializable
    private data class AudibleRatingDistribution(
        @SerialName("average_rating") val averageRating: Double? = null,
    )

    companion object {
        private const val DEFAULT_COUNTRY = "us"
        private const val RESPONSE_GROUPS_SEARCH = "contributors,product_attrs,product_desc,media,product_extended_attrs,series,category_ladders"
        private const val RESPONSE_GROUPS_DETAIL = "contributors,product_attrs,product_desc,media,product_extended_attrs,series,reviews,category_ladders"
    }
}

@Singleton
class GoogleBooksMetadataClient @Inject constructor(
    @ExternalMetadataHttpClient private val client: OkHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }
    private val baseUrl = "https://www.googleapis.com/books/v1/volumes".toHttpUrl()
    private val stateMutex = Mutex()
    private var lastRequestAtMs = 0L
    private var rateLimitedUntilMs = 0L
    private var consecutiveRateLimits = 0
    private val searchCache = linkedMapOf<String, List<GoogleBookItem>>()
    private val volumeCache = linkedMapOf<String, GoogleBookItem>()

    suspend fun search(query: String, author: String?, isbn: String?, limit: Int = 10): List<GoogleBookItem> {
        val searchTerms = buildSearchTerms(query.trim(), author, isbn)
        if (searchTerms.isBlank()) return emptyList()
        val resolvedLimit = min(limit.coerceAtLeast(1), 10)
        val cacheKey = "${searchTerms.lowercase()}|$resolvedLimit"
        searchCache[cacheKey]?.let { return it.take(resolvedLimit) }

        val results = retryingGoogleRequest {
            val url = baseUrl.newBuilder()
                .addQueryParameter("q", searchTerms)
                .addQueryParameter("printType", "books")
                .addQueryParameter("projection", "full")
                .addQueryParameter("orderBy", "relevance")
                .addQueryParameter("maxResults", resolvedLimit.toString())
                .build()
            client.getJson<GoogleSearchResponse>(url.toString(), json)
                .items
                .orEmpty()
                .map(::toGoogleBookItem)
        }
        searchCache[cacheKey] = results
        trimCache(searchCache)
        return results.take(resolvedLimit)
    }

    suspend fun getVolume(id: String): GoogleBookItem {
        volumeCache[id]?.let { return it }
        val item = retryingGoogleRequest {
            val url = baseUrl.newBuilder()
                .addPathSegment(id)
                .addQueryParameter("projection", "full")
                .build()
            toGoogleBookItem(client.getJson<GoogleVolume>(url.toString(), json))
        }
        volumeCache[id] = item
        trimCache(volumeCache)
        return item
    }

    private fun buildSearchTerms(query: String, author: String?, isbn: String?): String {
        val cleanIsbn = isbn?.trim().orEmpty()
        if (cleanIsbn.isNotBlank()) return "isbn:$cleanIsbn"
        val terms = mutableListOf<String>()
        if (query.isNotBlank()) terms += query
        if (query.isBlank() && !author.isNullOrBlank()) terms += "inauthor:${author.trim()}"
        return terms.joinToString(" ")
    }

    private suspend fun <T> retryingGoogleRequest(block: suspend () -> T): T {
        var lastError: Throwable? = null
        repeat(3) { attempt ->
            try {
                waitForPermit()
                return block().also {
                    stateMutex.withLock {
                        consecutiveRateLimits = 0
                        rateLimitedUntilMs = 0L
                        lastRequestAtMs = System.currentTimeMillis()
                    }
                }
            } catch (error: ExternalMetadataHttpException) {
                lastError = error
                val retry = error.statusCode == 429 ||
                    error.statusCode == 403 ||
                    error.statusCode in setOf(500, 502, 503, 504)
                if (!retry || attempt == 2) throw error
                if (error.statusCode == 429 || error.statusCode == 403) {
                    stateMutex.withLock {
                        consecutiveRateLimits += 1
                        val backoffMs = min(60_000.0, 4_000.0 * 2.0.pow((consecutiveRateLimits - 1).coerceAtLeast(0))).toLong()
                        rateLimitedUntilMs = System.currentTimeMillis() + backoffMs
                    }
                } else {
                    delay(min(3_000.0, 750.0 * 2.0.pow(attempt)).toLong())
                }
            } catch (error: IOException) {
                lastError = error
                if (attempt == 2) throw error
                delay(min(3_000.0, 750.0 * 2.0.pow(attempt)).toLong())
            }
        }
        throw lastError ?: IOException("Metadata search failed")
    }

    private suspend fun waitForPermit() {
        val now = System.currentTimeMillis()
        val waitMs = stateMutex.withLock {
            val rateLimitWait = (rateLimitedUntilMs - now).coerceAtLeast(0L)
            val spacingWait = (lastRequestAtMs + 1_250L - now).coerceAtLeast(0L)
            maxOf(rateLimitWait, spacingWait)
        }
        if (waitMs > 0) delay(waitMs)
    }

    private fun toGoogleBookItem(volume: GoogleVolume): GoogleBookItem {
        val info = volume.volumeInfo
        val isbn = info.industryIdentifiers
            ?.firstOrNull { it.type == "ISBN_13" }
            ?.identifier
            ?: info.industryIdentifiers?.firstOrNull { it.type == "ISBN_10" }?.identifier
            ?: info.industryIdentifiers?.firstOrNull()?.identifier
        return GoogleBookItem(
            volumeId = volume.id,
            title = info.title,
            subtitle = info.subtitle,
            authors = info.authors.orEmpty(),
            publisher = info.publisher,
            publishedDate = info.publishedDate,
            description = info.description,
            pageCount = info.pageCount,
            categories = info.categories.orEmpty(),
            imageLinks = info.imageLinks?.toModel(),
            language = info.language,
            isbn = isbn,
            averageRating = info.averageRating,
            ratingsCount = info.ratingsCount,
        )
    }

    private fun GoogleImageLinksDto.toModel(): GoogleImageLinks = GoogleImageLinks(
        smallThumbnail = smallThumbnail,
        thumbnail = thumbnail,
        small = small,
        medium = medium,
        large = large,
        extraLarge = extraLarge,
    )

    private fun <K, V> trimCache(map: LinkedHashMap<K, V>) {
        while (map.size > 64) {
            val first = map.keys.firstOrNull() ?: return
            map.remove(first)
        }
    }

    @Serializable
    private data class GoogleSearchResponse(val items: List<GoogleVolume>? = null)

    @Serializable
    private data class GoogleVolume(val id: String, val volumeInfo: GoogleVolumeInfo)

    @Serializable
    private data class GoogleVolumeInfo(
        val title: String? = null,
        val subtitle: String? = null,
        val authors: List<String>? = null,
        val publisher: String? = null,
        val publishedDate: String? = null,
        val description: String? = null,
        val pageCount: Int? = null,
        val categories: List<String>? = null,
        val averageRating: Double? = null,
        val ratingsCount: Int? = null,
        val imageLinks: GoogleImageLinksDto? = null,
        val language: String? = null,
        val industryIdentifiers: List<GoogleIndustryIdentifier>? = null,
    )

    @Serializable
    private data class GoogleImageLinksDto(
        val smallThumbnail: String? = null,
        val thumbnail: String? = null,
        val small: String? = null,
        val medium: String? = null,
        val large: String? = null,
        val extraLarge: String? = null,
    )

    @Serializable
    private data class GoogleIndustryIdentifier(val type: String? = null, val identifier: String? = null)
}

@Singleton
class OpenLibraryMetadataClient @Inject constructor(
    @ExternalMetadataHttpClient private val client: OkHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true }
    private val searchUrl = "https://openlibrary.org/search.json".toHttpUrl()
    private val worksUrl = "https://openlibrary.org".toHttpUrl()

    suspend fun search(query: String, limit: Int = 40): List<OpenLibraryItem> {
        val trimmed = query.trim()
        if (trimmed.isBlank()) return emptyList()
        val url = searchUrl.newBuilder()
            .addQueryParameter("q", trimmed)
            .addQueryParameter("limit", min(limit.coerceAtLeast(1), 100).toString())
            .addQueryParameter("fields", "key,title,author_name,first_publish_year,isbn,cover_i,publisher,subject,language,number_of_pages_median")
            .build()

        return client.getJson<OpenLibrarySearchResponse>(url.toString(), json)
            .docs
            .orEmpty()
            .mapNotNull(::toOpenLibraryItem)
    }

    suspend fun getWorkDescription(workKey: String): String? {
        val cleanKey = workKey.trim().trimStart('/')
        if (cleanKey.isBlank()) return null
        val url = worksUrl.newBuilder()
            .addPathSegments(cleanKey)
            .addPathSegment(".json")
            .build()
            .toString()
            .replace("/.json", ".json")

        val element = client.getJson<JsonObject>(url, json)
        val description = element["description"] ?: return null
        return when (description) {
            is JsonPrimitive -> description.contentOrNull
            is JsonObject -> description["value"]?.let { (it as? JsonPrimitive)?.contentOrNull }
            else -> null
        }
    }

    fun coverUrl(coverId: Int, size: String = "L"): String = "https://covers.openlibrary.org/b/id/$coverId-$size.jpg"

    private fun toOpenLibraryItem(doc: OpenLibraryDoc): OpenLibraryItem? {
        val key = doc.key?.takeIf { it.isNotBlank() } ?: return null
        return OpenLibraryItem(
            key = key,
            title = doc.title,
            authors = doc.authorName.orEmpty(),
            firstPublishYear = doc.firstPublishYear,
            isbn = doc.isbn?.firstOrNull(),
            coverId = doc.coverId,
            publisher = doc.publisher?.firstOrNull(),
            subjects = doc.subjects.orEmpty(),
            language = doc.language?.firstOrNull(),
            pageCount = doc.numberOfPagesMedian,
        )
    }

    @Serializable
    private data class OpenLibrarySearchResponse(val docs: List<OpenLibraryDoc>? = null)

    @Serializable
    private data class OpenLibraryDoc(
        val key: String? = null,
        val title: String? = null,
        @SerialName("author_name") val authorName: List<String>? = null,
        @SerialName("first_publish_year") val firstPublishYear: Int? = null,
        val isbn: List<String>? = null,
        @SerialName("cover_i") val coverId: Int? = null,
        val publisher: List<String>? = null,
        @SerialName("subject") val subjects: List<String>? = null,
        val language: List<String>? = null,
        @SerialName("number_of_pages_median") val numberOfPagesMedian: Int? = null,
    )
}

private suspend inline fun <reified T> OkHttpClient.getJson(url: String, json: Json): T {
    val request = Request.Builder().url(url).get().build()
    return withContext(Dispatchers.IO) {
        newCall(request).execute().use { response ->
            val body = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                throw ExternalMetadataHttpException(response.code, "Metadata search failed (${response.code})")
            }
            json.decodeFromString<T>(body)
        }
    }
}
