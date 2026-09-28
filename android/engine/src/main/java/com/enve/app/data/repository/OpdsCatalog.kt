package com.enve.app.data.repository

import com.enve.core.data.local.CachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.ReadStatus
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.Locale

enum class OpdsAcquisitionKind {
    OPEN_ACCESS,
    GENERIC,
    PREVIEW,
    BORROW,
    BUY,
    SUBSCRIBE,
}

enum class OpdsFormat {
    EPUB,
    PDF,
    CBZ,
    CBR,
    MOBI,
    AZW3,
    AUDIO,
    AUDIOBOOK_PACKAGE,
    WEBPUB,
    DIVINA,
    OPDS_PUBLICATION,
    OPDS_FEED,
    UNKNOWN,
}

enum class OpdsDrm {
    NONE,
    LCP,
    ADEPT,
}

val OpdsFormat.isReadableContent: Boolean
    get() = when (this) {
        OpdsFormat.EPUB,
        OpdsFormat.PDF,
        OpdsFormat.CBZ,
        OpdsFormat.CBR,
        OpdsFormat.MOBI,
        OpdsFormat.AZW3,
        OpdsFormat.AUDIO -> true

        else -> false
    }

data class OpdsIndirectAcquisition(
    val type: String,
    val children: List<OpdsIndirectAcquisition> = emptyList(),
)

data class OpdsPrice(
    val currency: String?,
    val value: Double,
)

data class OpdsAvailability(
    val state: String?,
    val since: String? = null,
    val until: String? = null,
)

data class OpdsCopies(
    val total: Int? = null,
    val available: Int? = null,
)

data class OpdsHolds(
    val total: Int? = null,
    val position: Int? = null,
)

data class OpdsAcquisition(
    val kind: OpdsAcquisitionKind,
    val href: String,
    val mediaType: String,
    val format: OpdsFormat,
    val drm: OpdsDrm = OpdsDrm.NONE,
    val title: String? = null,
    val requiresIndirectFetch: Boolean = false,
    val indirect: List<OpdsIndirectAcquisition> = emptyList(),
    val price: OpdsPrice? = null,
    val availability: OpdsAvailability? = null,
    val copies: OpdsCopies? = null,
    val holds: OpdsHolds? = null,
) {
    val isTransactional: Boolean
        get() = kind == OpdsAcquisitionKind.BORROW ||
            kind == OpdsAcquisitionKind.BUY ||
            kind == OpdsAcquisitionKind.SUBSCRIBE

    val isSupported: Boolean
        get() = drm == OpdsDrm.NONE && format.isReadableContent

    val isDirectlyDownloadable: Boolean
        get() = isSupported && !isTransactional && !requiresIndirectFetch

    val downloadHref: String?
        get() = href.takeIf { isDirectlyDownloadable }
}

data class OpdsPublication(
    val id: String,
    val identifier: String?,
    val selfUrl: String?,
    val summary: BookSummary,
    val acquisitions: List<OpdsAcquisition>,
    val selectedAcquisition: OpdsAcquisition?,
    val progressionUrl: String? = null,
    val progressionAuthenticateUrl: String? = null,
) {
    val downloadUrl: String? get() = selectedAcquisition?.downloadHref
    val isDownloadable: Boolean get() = downloadUrl != null
}

data class OpdsGroup(
    val title: String,
    val selfUrl: String?,
    val navigationLinks: List<OpdsFeedParser.NavigationLink> = emptyList(),
    val publications: List<OpdsPublication> = emptyList(),
)

data class OpdsFacet(
    val groupTitle: String,
    val title: String,
    val href: String,
    val type: String = "",
    val numberOfItems: Int? = null,
    val isActive: Boolean = false,
)

data class OpdsSearchLink(
    val href: String,
    val type: String = "",
    val title: String? = null,
    val templated: Boolean = false,
)

private val kindRank = mapOf(
    OpdsAcquisitionKind.OPEN_ACCESS to 0,
    OpdsAcquisitionKind.GENERIC to 1,
    OpdsAcquisitionKind.PREVIEW to 2,
    OpdsAcquisitionKind.BORROW to 3,
    OpdsAcquisitionKind.BUY to 4,
    OpdsAcquisitionKind.SUBSCRIBE to 5,
)

private val formatRank = mapOf(
    OpdsFormat.EPUB to 0,
    OpdsFormat.AUDIO to 1,
    OpdsFormat.CBZ to 2,
    OpdsFormat.CBR to 3,
    OpdsFormat.PDF to 4,
    OpdsFormat.MOBI to 5,
    OpdsFormat.AZW3 to 6,
    OpdsFormat.AUDIOBOOK_PACKAGE to 7,
    OpdsFormat.DIVINA to 8,
    OpdsFormat.WEBPUB to 9,
)

fun selectAcquisition(acquisitions: List<OpdsAcquisition>): OpdsAcquisition? =
    acquisitions.withIndex()
        .minWithOrNull(
            compareBy<IndexedValue<OpdsAcquisition>>(
                { if (it.value.isDirectlyDownloadable) 0 else 1 },
                { if (it.value.isSupported) 0 else 1 },
                { kindRank[it.value.kind] ?: Int.MAX_VALUE },
                { formatRank[it.value.format] ?: Int.MAX_VALUE },
                { it.index },
            )
        )
        ?.value

fun isHttpUrl(url: String): Boolean =
    when (url.substringBefore("://", "").lowercase(Locale.ROOT)) {
        "http", "https" -> true
        else -> false
    }

fun resolveOpdsAcquisitionUrl(cached: CachedBook?, bookId: String, serverUrl: String?): String? =
    cached?.opdsAcquisitionUrl?.takeIf { isSameOpdsOrigin(serverUrl, it) }
        ?: bookId.takeIf { isSameOpdsOrigin(serverUrl, it) }

fun opdsOrigin(url: String): String? {
    val parsed = url.toHttpUrlOrNull() ?: return null
    return "${parsed.scheme}://${parsed.host}:${parsed.port}"
}

private fun sameOrigin(origin: String?, url: String): Boolean {
    if (origin == null) return false
    return origin == opdsOrigin(url)
}

class OpdsForeignOriginException :
    IllegalStateException("That link leaves the server this source is configured for")

fun isSameOpdsOrigin(serverUrl: String?, url: String): Boolean {
    val expected = serverUrl?.let(::opdsOrigin) ?: return false
    return expected == opdsOrigin(url)
}

class OpdsCatalogCursor(
    val rootUrl: String,
    private val maxNavigationDepth: Int = DEFAULT_MAX_NAVIGATION_DEPTH,
    private val maxNavigationFetches: Int = DEFAULT_MAX_NAVIGATION_FETCHES,
    private val maxPaginationPages: Int = DEFAULT_MAX_PAGINATION_PAGES,
    private val maxDocuments: Int = DEFAULT_MAX_DOCUMENTS,
    private val maxBooks: Int = DEFAULT_MAX_BOOKS,
) {
    private data class Branch(val url: String, val depth: Int, val page: Int)

    private val rootOrigin = opdsOrigin(rootUrl)
    private val seen = mutableSetOf(rootUrl)
    private val pending = ArrayDeque(listOf(Branch(rootUrl, 0, 0)))
    private val documents = mutableListOf<String>()
    private var navigationFetches = 0
    private var bookCount = 0

    var truncated: Boolean = false
        private set

    val documentCount: Int get() = documents.size

    fun documentUrlAt(index: Int): String? = documents.getOrNull(index)

    fun peekFetch(): String? = pending.firstOrNull()?.url

    fun hasMoreAfter(index: Int): Boolean = documents.size > index + 1 || pending.isNotEmpty()

    fun accept(page: OpdsFeedParser.ParsedPage): Boolean {
        val branch = pending.removeFirstOrNull() ?: return false
        if (branch.page == 0) navigationFetches += 1

        val accepted = page.publications.isNotEmpty()
        if (accepted) {
            bookCount += page.publications.size
            documents += branch.url
        }

        if (documents.size >= maxDocuments || bookCount >= maxBooks) {
            if (pending.isNotEmpty() || page.nextUrl != null || page.allNavigationLinks.isNotEmpty()) {
                truncated = true
            }
            pending.clear()
            return accepted
        }

        enqueueNavigation(page, branch)
        enqueuePagination(page, branch)
        return accepted
    }

    fun markFailed() {
        pending.removeFirstOrNull() ?: return
        truncated = true
    }

    private fun enqueueNavigation(page: OpdsFeedParser.ParsedPage, branch: Branch) {
        val candidates = page.allNavigationLinks
            .filter { OpdsFeedParser.isTraversableFeedType(it.type) }
            .map { it.href }
            .filter { sameOrigin(rootOrigin, it) }
            .filterNot { seen.contains(it) }
            .distinct()
        if (candidates.isEmpty()) return

        val depth = branch.depth + 1
        if (depth > maxNavigationDepth) {
            truncated = true
            return
        }
        val budgetLeft = (maxNavigationFetches - navigationFetches - pending.count { it.page == 0 })
            .coerceAtLeast(0)
        if (candidates.size > budgetLeft) truncated = true
        candidates.take(budgetLeft).forEach {
            seen += it
            pending.addLast(Branch(it, depth, 0))
        }
    }

    private fun enqueuePagination(page: OpdsFeedParser.ParsedPage, branch: Branch) {
        val next = page.nextUrl ?: return
        if (!sameOrigin(rootOrigin, next)) return
        if (branch.page + 1 >= maxPaginationPages) {
            truncated = true
            return
        }
        if (!seen.add(next)) return
        pending.addFirst(Branch(next, branch.depth, branch.page + 1))
    }

    private companion object {
        const val DEFAULT_MAX_NAVIGATION_DEPTH = 4
        const val DEFAULT_MAX_NAVIGATION_FETCHES = 64
        const val DEFAULT_MAX_PAGINATION_PAGES = 200
        const val DEFAULT_MAX_DOCUMENTS = 400
        const val DEFAULT_MAX_BOOKS = 20_000
    }
}

fun BookSummary.toOpdsBook(): Book = Book(
    id = id,
    title = title,
    subtitle = subtitle,
    author = authors.joinToString(", ").takeIf { it.isNotBlank() },
    narrator = narrator,
    description = description,
    coverUrl = thumbnailUrl,
    duration = durationSeconds,
    source = BookSource.OPDS,
    mediaType = mediaType,
    readStatus = readStatus,
    seriesName = seriesName,
    seriesNumber = seriesNumber,
    publisher = publisher,
    publishedDate = publishedDate,
    isbn13 = isbn13,
    language = language,
    pageCount = pageCount,
    categories = categories,
    primaryFileType = primaryFileType,
    libraryId = libraryId,
    connectionId = connectionId,
    addedOn = addedOn,
    lastReadTime = lastReadTime,
    readProgress = readProgress.coerceIn(0f, 1f),
    isFinished = readStatus == ReadStatus.COMPLETED,
    personalRating = personalRating,
    goodreadsRating = goodreadsRating,
    hasAudio = hasAudio || mediaType == AppMediaType.AUDIOBOOK,
    hasEbook = hasEbook || mediaType == AppMediaType.EBOOK,
    opdsAcquisitionUrl = opdsAcquisitionUrl,
    opdsProgressionUrl = opdsProgressionUrl,
)
