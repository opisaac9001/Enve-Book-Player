package com.enve.app.data.discover

import com.enve.app.di.PublicMetadataHttpClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.jsoup.Jsoup
import java.time.Year
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DiscoverRepository @Inject constructor(
    @PublicMetadataHttpClient private val httpClient: OkHttpClient,
) {
    @Volatile
    private var cache: CacheEntry? = null

    suspend fun loadSections(force: Boolean = false): List<DiscoverSection> = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        cache?.takeIf { !force && now - it.fetchedAtMs < CACHE_TTL_MS }?.let { return@withContext it.sections }

        val specs = discoverSectionSpecs(Year.now().value)
        val sections = specs.map { spec ->
            val books = spec.queries
                .flatMap { query ->
                    try {
                        searchPublicCatalog(query.text, query.orderBy)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        emptyList()
                    }
                }
                .deduplicatedDiscoverBooks()
                .take(MAX_SECTION_BOOKS)
            DiscoverSection(
                id = spec.id,
                title = spec.title,
                subtitle = spec.subtitle,
                books = books,
            )
        }.filter { it.books.isNotEmpty() }

        if (sections.isEmpty()) {
            cache?.let { return@withContext it.sections }
            error("Discover metadata is unavailable")
        }

        cache = CacheEntry(fetchedAtMs = now, sections = sections)
        sections
    }

    private fun searchPublicCatalog(
        query: String,
        orderBy: GoogleBooksOrder,
    ): List<DiscoverBook> {
        try {
            val audiobooks = searchAudibleAudiobooks(query)
            if (audiobooks.isNotEmpty()) return audiobooks
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        try {
            val audiobooks = searchItunesAudiobooks(query)
            if (audiobooks.isNotEmpty()) return audiobooks
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        return searchGoogleBooks(query, orderBy)
    }

    private fun searchAudibleAudiobooks(
        query: String,
        maxResults: Int = AUDIBLE_PAGE_SIZE,
    ): List<DiscoverBook> {
        val url = "https://api.audible.com/1.0/catalog/products".toHttpUrl()
            .newBuilder()
            .addQueryParameter("keywords", query)
            .addQueryParameter("num_results", maxResults.toString())
            .addQueryParameter("products_sort_by", "Relevance")
            .addQueryParameter("response_groups", AUDIBLE_RESPONSE_GROUPS)
            .addQueryParameter("image_sizes", "500,1024")
            .addQueryParameter("country_code", "us")
            .build()
        val request = Request.Builder().url(url).build()
        httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Audible discover provider returned HTTP ${response.code}")
            return decodeAudibleCatalogResponse(response.body?.string().orEmpty())
        }
    }

    private fun searchItunesAudiobooks(
        query: String,
        maxResults: Int = ITUNES_PAGE_SIZE,
    ): List<DiscoverBook> {
        val url = "https://itunes.apple.com/search".toHttpUrl()
            .newBuilder()
            .addQueryParameter("term", query)
            .addQueryParameter("media", "audiobook")
            .addQueryParameter("entity", "audiobook")
            .addQueryParameter("country", "US")
            .addQueryParameter("lang", "en_us")
            .addQueryParameter("limit", maxResults.toString())
            .build()
        val request = Request.Builder().url(url).build()
        httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Discover audiobook provider returned HTTP ${response.code}")
            return decodeItunesAudiobookResponse(response.body?.string().orEmpty())
        }
    }

    private fun searchGoogleBooks(
        query: String,
        orderBy: GoogleBooksOrder,
        maxResults: Int = GOOGLE_BOOKS_PAGE_SIZE,
    ): List<DiscoverBook> {
        val url = "https://www.googleapis.com/books/v1/volumes".toHttpUrl()
            .newBuilder()
            .addQueryParameter("q", query)
            .addQueryParameter("maxResults", maxResults.toString())
            .addQueryParameter("printType", "books")
            .addQueryParameter("orderBy", orderBy.value)
            .build()
        val request = Request.Builder().url(url).build()
        httpClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Discover provider returned HTTP ${response.code}")
            return decodeGoogleBooksResponse(response.body?.string().orEmpty())
        }
    }

    private data class CacheEntry(
        val fetchedAtMs: Long,
        val sections: List<DiscoverSection>,
    )

    companion object {
        private const val CACHE_TTL_MS = 60L * 60L * 1000L
        private const val AUDIBLE_PAGE_SIZE = 12
        private const val AUDIBLE_RESPONSE_GROUPS =
            "contributors,product_attrs,product_desc,media,product_extended_attrs,series,category_ladders"
        private const val ITUNES_PAGE_SIZE = 12
        private const val GOOGLE_BOOKS_PAGE_SIZE = 10
        private const val MAX_SECTION_BOOKS = 12
    }
}

private data class DiscoverSectionSpec(
    val id: DiscoverSectionId,
    val title: String,
    val subtitle: String,
    val queries: List<DiscoverQuery>,
)

private data class DiscoverQuery(
    val text: String,
    val orderBy: GoogleBooksOrder = GoogleBooksOrder.RELEVANCE,
)

private enum class GoogleBooksOrder(val value: String) {
    RELEVANCE("relevance"),
    NEWEST("newest"),
}

private fun discoverSectionSpecs(currentYear: Int): List<DiscoverSectionSpec> =
    listOf(
        DiscoverSectionSpec(
            id = DiscoverSectionId.TRENDING,
            title = "Trending",
            subtitle = "Popular books readers are finding now",
            queries = listOf(
                DiscoverQuery("bestseller audiobook"),
                DiscoverQuery("popular audiobooks $currentYear"),
                DiscoverQuery("audiobook thriller"),
                DiscoverQuery("audiobook fiction"),
            ),
        ),
        DiscoverSectionSpec(
            id = DiscoverSectionId.BESTSELLERS,
            title = "Bestsellers",
            subtitle = "High-signal mainstream picks",
            queries = listOf(
                DiscoverQuery("James Patterson audiobook"),
                DiscoverQuery("Stephen King audiobook"),
                DiscoverQuery("Colleen Hoover audiobook"),
                DiscoverQuery("Brandon Sanderson audiobook"),
                DiscoverQuery("Rebecca Yarros audiobook"),
            ),
        ),
        DiscoverSectionSpec(
            id = DiscoverSectionId.NEW_RELEASES,
            title = "New Releases",
            subtitle = "Recent books across fiction and genre shelves",
            queries = listOf(
                DiscoverQuery("new audiobook $currentYear", GoogleBooksOrder.NEWEST),
                DiscoverQuery("new release audiobook", GoogleBooksOrder.NEWEST),
                DiscoverQuery("audiobook mystery $currentYear", GoogleBooksOrder.NEWEST),
                DiscoverQuery("audiobook romance $currentYear", GoogleBooksOrder.NEWEST),
                DiscoverQuery("audiobook science fiction $currentYear", GoogleBooksOrder.NEWEST),
            ),
        ),
    )

private val googleBooksJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
}

fun decodeGoogleBooksResponse(response: String): List<DiscoverBook> {
    val decoded = googleBooksJson.decodeFromString(GoogleBooksResponse.serializer(), response)
    return decoded.items.mapNotNull { item ->
        val info = item.volumeInfo
        val title = listOfNotNull(
            info.title?.cleanText(),
            info.subtitle?.cleanText()?.takeUnless { subtitle ->
                info.title?.contains(subtitle, ignoreCase = true) == true
            },
        ).joinToString(": ").ifBlank { return@mapNotNull null }
        DiscoverBook(
            id = item.id,
            title = title,
            author = info.authors?.joinToString(", ")?.cleanText(),
            artworkUrl = info.imageLinks?.thumbnail ?: info.imageLinks?.smallThumbnail,
            description = info.description?.cleanHtmlText(),
            publishedDate = info.publishedDate?.cleanText(),
            genre = info.categories?.firstOrNull()?.cleanText(),
            pageCount = info.pageCount,
            durationMillis = null,
            previewUrl = info.previewLink?.toHttpsUrl(),
            infoUrl = info.infoLink?.toHttpsUrl(),
            collectionId = info.industryIdentifiers
                ?.firstOrNull { it.type.equals("ISBN_13", ignoreCase = true) }
                ?.identifier
                ?: info.industryIdentifiers?.firstOrNull()?.identifier
                ?: item.id,
        )
    }
}

fun decodeAudibleCatalogResponse(response: String): List<DiscoverBook> {
    val decoded = googleBooksJson.decodeFromString(AudibleCatalogResponse.serializer(), response)
    return decoded.products.mapNotNull { item ->
        val asin = item.asin?.cleanText() ?: return@mapNotNull null
        val title = item.displayTitle() ?: return@mapNotNull null
        DiscoverBook(
            id = "audible-$asin",
            title = title,
            author = item.authors.orEmpty()
                .mapNotNull { it.name?.cleanText() }
                .joinToString(", ")
                .takeIf { it.isNotBlank() },
            artworkUrl = item.productImages?.bestAudibleImage(),
            description = item.descriptionText(),
            publishedDate = item.releaseDate?.cleanText()
                ?: item.publicationDate?.cleanText()
                ?: item.publicationDateTime?.cleanText(),
            genre = item.categoryLadders.orEmpty()
                .asSequence()
                .mapNotNull { ladder -> ladder.ladder?.lastOrNull()?.name?.cleanText() }
                .firstOrNull()
                ?: item.genres.orEmpty().firstNotNullOfOrNull { it.name?.cleanText() },
            pageCount = null,
            durationMillis = item.runtimeLengthMin?.let { it * 60_000L },
            previewUrl = null,
            infoUrl = "https://www.audible.com/pd/$asin",
            collectionId = asin,
        )
    }
}

fun decodeItunesAudiobookResponse(response: String): List<DiscoverBook> {
    val decoded = googleBooksJson.decodeFromString(ItunesAudiobookResponse.serializer(), response)
    return decoded.results.mapNotNull { item ->
        val title = (item.collectionName ?: item.collectionCensoredName)?.cleanText() ?: return@mapNotNull null
        DiscoverBook(
            id = item.collectionId?.toString() ?: title,
            title = title,
            author = item.artistName?.cleanText(),
            artworkUrl = item.artworkUrl100?.toHighResolutionItunesArtwork(),
            description = item.description?.cleanHtmlText(),
            publishedDate = item.releaseDate?.cleanText(),
            genre = item.primaryGenreName?.cleanText(),
            pageCount = null,
            durationMillis = item.trackTimeMillis,
            previewUrl = item.previewUrl?.toHttpsUrl(),
            infoUrl = item.collectionViewUrl?.toHttpsUrl(),
            collectionId = item.collectionId?.toString() ?: "${title}:${item.artistName.orEmpty()}",
        )
    }
}

fun List<DiscoverBook>.deduplicatedDiscoverBooks(): List<DiscoverBook> {
    val seen = mutableSetOf<String>()
    return filter { book ->
        val key = book.collectionId
            ?.normalizeDiscoverKey()
            ?.takeIf { it.isNotBlank() }
            ?: "${book.title}:${book.author.orEmpty()}".normalizeDiscoverKey()
        seen.add(key)
    }
}

private fun String.cleanText(): String? =
    trim().replace(Regex("\\s+"), " ").takeIf { it.isNotBlank() }

private fun String.cleanHtmlText(): String? =
    Jsoup.parse(this).text().cleanText()

private fun String.normalizeDiscoverKey(): String =
    lowercase().filter(Char::isLetterOrDigit)

private fun String.toHttpsUrl(): String =
    if (startsWith("http://")) "https://${removePrefix("http://")}" else this

private fun String.toHighResolutionItunesArtwork(): String =
    toHttpsUrl()
        .replace("100x100bb", "600x600bb")
        .replace("100x100", "600x600")

private fun AudibleProduct.displayTitle(): String? {
    val title = title?.cleanText() ?: return null
    val subtitle = subtitle?.cleanText()?.takeUnless { cleanSubtitle ->
        title.contains(cleanSubtitle, ignoreCase = true)
    }
    return listOfNotNull(title, subtitle).joinToString(": ")
}

private fun AudibleProduct.descriptionText(): String? =
    htmlDescription?.cleanHtmlText()
        ?: publisherSummary?.cleanHtmlText()
        ?: summary?.cleanHtmlText()
        ?: merchandisingSummary?.cleanHtmlText()

private fun Map<String, String>.bestAudibleImage(): String? =
    (get("1024") ?: get("500") ?: entries.maxByOrNull { it.key.toIntOrNull() ?: -1 }?.value)
        ?.toHttpsUrl()

@Serializable
private data class AudibleCatalogResponse(
    val products: List<AudibleProduct> = emptyList(),
)

@Serializable
private data class AudibleProduct(
    val asin: String? = null,
    val title: String? = null,
    val subtitle: String? = null,
    val authors: List<AudibleContributor>? = null,
    val narrators: List<AudibleContributor>? = null,
    @SerialName("runtime_length_min") val runtimeLengthMin: Int? = null,
    @SerialName("release_date") val releaseDate: String? = null,
    @SerialName("publication_date") val publicationDate: String? = null,
    @SerialName("publication_datetime") val publicationDateTime: String? = null,
    @SerialName("product_images") val productImages: Map<String, String>? = null,
    @SerialName("html_description") val htmlDescription: String? = null,
    @SerialName("publisher_summary") val publisherSummary: String? = null,
    val summary: String? = null,
    @SerialName("merchandising_summary") val merchandisingSummary: String? = null,
    @SerialName("category_ladders") val categoryLadders: List<AudibleCategoryLadder>? = null,
    val genres: List<AudibleCategory>? = null,
)

@Serializable
private data class AudibleContributor(
    val name: String? = null,
)

@Serializable
private data class AudibleCategoryLadder(
    val ladder: List<AudibleCategory>? = null,
)

@Serializable
private data class AudibleCategory(
    val name: String? = null,
)

@Serializable
private data class GoogleBooksResponse(
    val items: List<GoogleBookItem> = emptyList(),
)

@Serializable
private data class GoogleBookItem(
    val id: String,
    val volumeInfo: GoogleVolumeInfo = GoogleVolumeInfo(),
)

@Serializable
private data class GoogleVolumeInfo(
    val title: String? = null,
    val subtitle: String? = null,
    val authors: List<String>? = null,
    val publishedDate: String? = null,
    val description: String? = null,
    val industryIdentifiers: List<GoogleIndustryIdentifier>? = null,
    val pageCount: Int? = null,
    val categories: List<String>? = null,
    val imageLinks: GoogleImageLinks? = null,
    val previewLink: String? = null,
    val infoLink: String? = null,
)

@Serializable
private data class GoogleIndustryIdentifier(
    val type: String,
    val identifier: String,
)

@Serializable
private data class GoogleImageLinks(
    @SerialName("smallThumbnail") val smallThumbnail: String? = null,
    val thumbnail: String? = null,
)

@Serializable
private data class ItunesAudiobookResponse(
    val results: List<ItunesAudiobookItem> = emptyList(),
)

@Serializable
private data class ItunesAudiobookItem(
    val collectionId: Long? = null,
    val collectionName: String? = null,
    val collectionCensoredName: String? = null,
    val artistName: String? = null,
    val artworkUrl100: String? = null,
    val description: String? = null,
    val releaseDate: String? = null,
    val primaryGenreName: String? = null,
    val trackTimeMillis: Long? = null,
    val previewUrl: String? = null,
    val collectionViewUrl: String? = null,
)
