package com.enve.app.data.repository

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.Library
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.remote.GrimmoryApi
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsRepository @Inject constructor(
    private val api: GrimmoryApi,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
) {
    private val connectionMutex = Mutex()
    private val pageUrlMutex = Mutex()
    private val pageUrlsByConnection = mutableMapOf<String, MutableMap<Int, String>>()

    data class OpdsPage(
        val items: List<BookSummary>,
        val nextUrl: String?,
        val totalResults: Int? = null,
    )

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

    suspend fun getPage(connectionId: String, url: String): Result<OpdsPage> = withConnection(connectionId) {
        fetchParsedPage(url, connectionId).map { parsed ->
            OpdsPage(
                items = parsed.items,
                nextUrl = parsed.nextUrl,
                totalResults = parsed.totalResults,
            )
        }
    }

    suspend fun getPageByIndex(connectionId: String, page: Int): Result<OpdsPage> {
        val normalizedPage = page.coerceAtLeast(0)
        val url = urlForPage(connectionId, normalizedPage)
            ?: return Result.success(OpdsPage(emptyList(), null))
        val result = getPage(connectionId, url)
        result.getOrNull()?.nextUrl?.let { nextUrl ->
            pageUrlMutex.withLock {
                pageUrlsByConnection.getOrPut(connectionId) { mutableMapOf() }[normalizedPage + 1] = nextUrl
            }
        }
        return result
    }

    suspend fun getItemsPage(connectionId: String, page: Int, size: Int): Result<OpdsPage> {
        val pageSize = size.coerceAtLeast(1)
        val offset = page.coerceAtLeast(0) * pageSize
        var url = getRootCatalogUrl(connectionId) ?: return Result.success(OpdsPage(emptyList(), null))
        val collected = mutableListOf<BookSummary>()
        var totalResults: Int? = null
        var nextUrl: String? = null
        var feedPage = 0

        while (collected.size < offset + pageSize) {
            val result = getPage(connectionId, url)
            val opdsPage = result.getOrElse { return Result.failure(it) }
            if (totalResults == null) totalResults = opdsPage.totalResults
            collected += opdsPage.items
            nextUrl = opdsPage.nextUrl
            if (nextUrl == null) break
            pageUrlMutex.withLock {
                pageUrlsByConnection.getOrPut(connectionId) { mutableMapOf() }[feedPage + 1] = nextUrl
            }
            url = nextUrl
            feedPage += 1
        }

        return Result.success(
            OpdsPage(
                items = collected.drop(offset).take(pageSize),
                nextUrl = nextUrl.takeIf { collected.size >= offset + pageSize },
                totalResults = totalResults,
            )
        )
    }

    fun invalidateCaches(connectionId: String? = null) {
        if (connectionId == null) {
            pageUrlsByConnection.clear()
        } else {
            pageUrlsByConnection.remove(connectionId)
        }
    }

    private suspend fun urlForPage(connectionId: String, page: Int): String? {
        if (page == 0) return getRootCatalogUrl(connectionId)
        val cached = pageUrlMutex.withLock { pageUrlsByConnection[connectionId]?.get(page) }
        if (cached != null) return cached
        var currentUrl = getRootCatalogUrl(connectionId) ?: return null
        repeat(page) { index ->
            val parsed = getPage(connectionId, currentUrl).getOrNull() ?: return null
            val nextUrl = parsed.nextUrl ?: return null
            pageUrlMutex.withLock {
                pageUrlsByConnection.getOrPut(connectionId) { mutableMapOf() }[index + 1] = nextUrl
            }
            currentUrl = nextUrl
        }
        return currentUrl
    }

    private suspend fun fetchParsedPage(
        url: String,
        connectionId: String,
        depth: Int = 0,
        visited: Set<String> = emptySet(),
    ): Result<OpdsFeedParser.ParsedPage> {
        if (url in visited) {
            return Result.success(OpdsFeedParser.ParsedPage(emptyList(), null))
        }
        val response = api.fetchRawUrl(url)
        if (!response.isSuccessful) return Result.failure(Exception("OPDS HTTP ${response.code()}"))
        val text = response.body()?.string()
            ?: return Result.failure(Exception("OPDS empty body"))
        val responseUrl = response.raw().request.url.toString()
        val parsed = OpdsFeedParser.parse(text, baseUrl = responseUrl, connectionId = connectionId)
        if (parsed.items.isNotEmpty() || parsed.navigationLinks.isEmpty() || depth >= MAX_NAVIGATION_DEPTH) {
            return Result.success(parsed)
        }
        val next = bestNavigationLink(parsed.navigationLinks, visited + url)
            ?: return Result.success(parsed)
        return fetchParsedPage(next.href, connectionId, depth + 1, visited + url)
    }

    private fun bestNavigationLink(
        links: List<OpdsFeedParser.NavigationLink>,
        visited: Set<String>,
    ): OpdsFeedParser.NavigationLink? {
        val candidates = links.filterNot { it.href in visited }
        return candidates.firstOrNull { link ->
            val haystack = "${link.title} ${link.href}".lowercase()
            haystack.contains("all") || haystack.contains("/catalog")
        } ?: candidates.firstOrNull { link ->
            link.title.contains("book", ignoreCase = true)
        } ?: candidates.firstOrNull()
    }

    private suspend fun <T> withConnection(connectionId: String, block: suspend () -> Result<T>): Result<T> {
        val conn = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
            ?: return Result.failure(IllegalStateException("Connection $connectionId not found"))
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
        const val MAX_NAVIGATION_DEPTH = 4
    }
}
