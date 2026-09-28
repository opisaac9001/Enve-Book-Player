package com.enve.app.data.repository

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.opds.OpdsAcquisitionStore
import com.enve.app.data.opds.OpdsAuthenticationRequiredException
import com.enve.app.data.opds.OPDS_CATALOG_ACCEPT
import com.enve.app.data.opds.OpdsCatalogApi
import com.enve.app.data.opds.OpdsProgressionStateStore
import com.enve.app.data.opds.parseOpdsAuthenticationDocument
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsRepository @Inject constructor(
    private val api: OpdsCatalogApi,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
    private val acquisitions: OpdsAcquisitionStore,
    private val progressionState: OpdsProgressionStateStore,
) {
    private val connectionMutex = Mutex()
    private val cursorsMutex = Mutex()
    private val cursors = ConcurrentHashMap<String, CursorEntry>()

    data class OpdsDocument(val url: String, val payload: String)

    data class OpdsPage(
        val items: List<BookSummary>,
        val nextUrl: String?,
        val totalResults: Int? = null,
        val title: String? = null,
        val navigationLinks: List<OpdsFeedParser.NavigationLink> = emptyList(),
        val facets: List<OpdsFacet> = emptyList(),
        val searchLinks: List<OpdsSearchLink> = emptyList(),
        val publications: List<OpdsPublication> = emptyList(),
        val groups: List<OpdsGroup> = emptyList(),
        val isSinglePublicationDocument: Boolean = false,
        val previousUrl: String? = null,
        val firstUrl: String? = null,
        val lastUrl: String? = null,
        val currentPage: Int? = null,
        val hasMore: Boolean = false,
        val truncated: Boolean = false,
    )

    private class CursorEntry(val cursor: OpdsCatalogCursor) {
        val mutex = Mutex()
        val items = mutableListOf<BookSummary>()
        private val itemIds = mutableSetOf<String>()
        private val parsed = LinkedHashMap<String, OpdsFeedParser.ParsedPage>()

        var rootTotalResults: Int? = null
            private set

        fun remember(url: String, page: OpdsFeedParser.ParsedPage) {
            if (url == cursor.rootUrl) rootTotalResults = page.totalResults
            page.items.forEach { if (itemIds.add(it.id)) items += it }
            parsed.remove(url)
            parsed[url] = page
            while (parsed.size > PARSED_PAGE_CACHE) {
                parsed.remove(parsed.keys.first())
            }
        }

        fun parsedAt(url: String): OpdsFeedParser.ParsedPage? = parsed[url]?.also {
            parsed.remove(url)
            parsed[url] = it
        }
    }

    suspend fun getLibraries(connectionId: String): Result<List<Library>> {
        val conn = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
            ?: return Result.failure(IllegalStateException("Connection $connectionId not found"))
        return Result.success(listOf(
            Library(
                id = "$connectionId::root",
                name = conn.username.ifBlank { "OPDS Catalog" },
                bookCount = 0,
                source = BookSource.OPDS,
                connectionId = connectionId,
            )
        ))
    }

    fun getRootCatalogUrl(connectionId: String): String? {
        val conn = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
            ?: return null
        return conn.serverUrl.takeIf { it.isNotBlank() }?.trimEnd('/')
    }

    suspend fun getPage(connectionId: String, url: String): Result<OpdsPage> =
        withCatalogUrl(connectionId, url) {
            fetchParsedPage(url, connectionId).map { parsed -> parsed.toPage(hasMore = parsed.nextUrl != null) }
        }

    suspend fun getDocument(connectionId: String, url: String, accept: String): Result<OpdsDocument> =
        withCatalogUrl(connectionId, url) {
            runSuspendCatching {
                val response = api.fetch(url, accept)
                if (!response.isSuccessful) throw IllegalStateException("OPDS HTTP ${response.code()}")
                val payload = response.body()?.use { it.string() }
                    ?: throw IllegalStateException("OPDS empty body")
                OpdsDocument(url = response.raw().request.url.toString(), payload = payload)
            }
        }

    suspend fun getRootPage(connectionId: String): Result<OpdsPage> {
        val root = getRootCatalogUrl(connectionId)
            ?: return Result.failure(IllegalStateException("No OPDS root URL for $connectionId"))
        return getPage(connectionId, root)
    }

    suspend fun getDocumentPage(connectionId: String, index: Int): Result<OpdsPage> =
        withConnection(connectionId) { resolveDocument(connectionId, index.coerceAtLeast(0)) }

    suspend fun getItemsPage(connectionId: String, page: Int, size: Int): Result<OpdsPage> =
        withConnection(connectionId) {
            val pageSize = size.coerceAtLeast(1)
            val offset = page.coerceAtLeast(0) * pageSize
            val entry = cursorEntry(connectionId)
                ?: return@withConnection Result.success(OpdsPage(emptyList(), null))

            entry.mutex.withLock {
                advanceUntil(entry, connectionId) { entry.items.size >= offset + pageSize }
                    ?.let { error -> return@withLock Result.failure(error) }

                val cursor = entry.cursor
                Result.success(
                    OpdsPage(
                        items = entry.items.drop(offset).take(pageSize),
                        nextUrl = null,
                        totalResults = entry.rootTotalResults
                            .takeIf { !cursor.truncated && cursor.documentCount <= 1 },
                        hasMore = entry.items.size > offset + pageSize || cursor.peekFetch() != null,
                        truncated = cursor.truncated,
                    )
                )
            }
        }

    fun invalidateCaches(connectionId: String? = null) {
        if (connectionId == null) {
            cursors.clear()
        } else {
            cursors.remove(connectionId)
        }
    }

    private suspend fun resolveDocument(connectionId: String, index: Int): Result<OpdsPage> {
        val entry = cursorEntry(connectionId) ?: return Result.success(OpdsPage(emptyList(), null))
        return entry.mutex.withLock {
            val cursor = entry.cursor
            advanceUntil(entry, connectionId) { cursor.documentCount > index }
                ?.let { error -> return@withLock Result.failure(error) }

            val url = cursor.documentUrlAt(index)
                ?: return@withLock Result.success(OpdsPage(emptyList(), null, truncated = cursor.truncated))
            val parsed = entry.parsedAt(url)
                ?: fetchParsedPage(url, connectionId)
                    .onSuccess { entry.remember(url, it) }
                    .getOrElse { error -> return@withLock Result.failure(error) }

            Result.success(
                parsed.toPage(
                    hasMore = cursor.hasMoreAfter(index),
                    truncated = cursor.truncated,
                )
            )
        }
    }

    private suspend fun advanceUntil(
        entry: CursorEntry,
        connectionId: String,
        satisfied: () -> Boolean,
    ): Throwable? {
        val cursor = entry.cursor
        while (!satisfied()) {
            val url = cursor.peekFetch() ?: return null
            val parsed = fetchParsedPage(url, connectionId).getOrElse { error ->
                if (url == cursor.rootUrl && cursor.documentCount == 0) return error
                cursor.markFailed()
                null
            } ?: continue
            if (cursor.accept(parsed)) entry.remember(url, parsed)
        }
        return null
    }

    private suspend fun cursorEntry(connectionId: String): CursorEntry? {
        val root = getRootCatalogUrl(connectionId) ?: return null
        return cursorsMutex.withLock {
            cursors.getOrPut(connectionId) { CursorEntry(OpdsCatalogCursor(root)) }
        }
    }

    private suspend fun fetchParsedPage(url: String, connectionId: String): Result<OpdsFeedParser.ParsedPage> =
        runSuspendCatching {
            val response = api.fetch(url, OPDS_CATALOG_ACCEPT)
            val requestedUrl = response.raw().request.url.toString()
            if (response.code() == HTTP_UNAUTHORIZED) {
                val payload = response.errorBody()?.use { it.string() }
                throw OpdsAuthenticationRequiredException(
                    url = requestedUrl,
                    document = parseOpdsAuthenticationDocument(payload, requestedUrl),
                )
            }
            if (!response.isSuccessful) throw IllegalStateException("OPDS HTTP ${response.code()}")
            val text = response.body()?.use { it.string() }
                ?: throw IllegalStateException("OPDS empty body")
            val parsed = OpdsFeedParser.parse(
                document = text,
                baseUrl = requestedUrl,
                connectionId = connectionId,
            )
            persistPublications(connectionId, parsed)
            parsed
        }

    private suspend fun persistPublications(connectionId: String, parsed: OpdsFeedParser.ParsedPage) {
        if (parsed.publications.isEmpty()) return
        acquisitions.saveAll(connectionId, parsed.publications.associate { it.id to it.acquisitions })
        progressionState.saveAuthenticateUrls(
            connectionId,
            parsed.publications.mapNotNull { pub -> pub.progressionAuthenticateUrl?.let { pub.id to it } }.toMap(),
        )
    }

    private suspend fun <T> withCatalogUrl(
        connectionId: String,
        url: String,
        block: suspend () -> Result<T>,
    ): Result<T> {
        val conn = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
            ?: return Result.failure(IllegalStateException("Connection $connectionId not found"))
        val rootOrigin = opdsOrigin(conn.serverUrl)
            ?: return Result.failure(IllegalStateException("This source has no usable catalog URL"))
        if (rootOrigin != opdsOrigin(url)) return Result.failure(OpdsForeignOriginException())
        return applyConnection(conn) { block() }
    }

    private fun OpdsFeedParser.ParsedPage.toPage(hasMore: Boolean, truncated: Boolean = false) = OpdsPage(
        items = items,
        nextUrl = nextUrl,
        totalResults = totalResults,
        title = title,
        navigationLinks = allNavigationLinks,
        facets = facets,
        searchLinks = searchLinks,
        publications = publications,
        groups = groups,
        isSinglePublicationDocument = isSinglePublicationDocument,
        previousUrl = previousUrl,
        firstUrl = firstUrl,
        lastUrl = lastUrl,
        currentPage = currentPage,
        hasMore = hasMore,
        truncated = truncated,
    )

    private suspend fun <T> withConnection(connectionId: String, block: suspend () -> Result<T>): Result<T> {
        val conn = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
            ?: return Result.failure(IllegalStateException("Connection $connectionId not found"))
        return applyConnection(conn, block)
    }

    private suspend fun <T> applyConnection(
        conn: ProviderConnection,
        block: suspend () -> Result<T>,
    ): Result<T> {
        connectionMutex.withLock {
            prefs.setCachedConnectionContext(
                source = conn.source,
                serverUrl = conn.serverUrl,
                username = conn.username,
                connectionId = conn.id,
                accessToken = null,
                refreshToken = null,
                password = null,
            )
        }
        return withContext(ConnectionScope.asContextElement(conn.id)) { block() }
    }

    private companion object {
        const val PARSED_PAGE_CACHE = 8
        const val HTTP_UNAUTHORIZED = 401
    }
}
