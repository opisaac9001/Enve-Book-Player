package com.enve.app.data.repository

import com.enve.core.di.ApplicationScope
import kotlinx.coroutines.Job
import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import android.util.Log
import com.enve.core.data.model.*
import com.enve.core.data.model.BookSource
import com.enve.komga.KomgaRepository
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.jellyfin.jellyfinBody
import com.enve.app.data.kavita.KavitaBookRef
import com.enve.app.data.kavita.KavitaIssue
import com.enve.app.data.kavita.KavitaLegacyAliasStore
import com.enve.app.data.kavita.expandKavitaSeries
import com.enve.app.data.kavita.kavitaBookRef
import com.enve.app.data.kavita.kavitaLegacyChapterCandidate
import com.enve.app.data.kavita.kavitaSeriesComicMetadata
import com.enve.app.data.kavita.resolveKavitaIssue
import com.enve.app.data.repository.grimmory.*
import com.enve.app.data.remote.dto.*
import com.enve.core.data.provider.*
import com.enve.core.data.util.*
import com.enve.core.data.remote.dto.AuthResponse
import com.enve.core.data.remote.dto.AuthorSummaryDto
import com.enve.core.data.remote.dto.RefreshRequest
import com.enve.core.data.remote.dto.SeriesSummaryDto
import com.enve.core.data.local.PreferencesManager
import com.enve.core.auth.CredentialVault
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.core.data.sync.SyncSnapshot
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import com.enve.core.data.remote.ConnectionScope
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.round
import kotlin.math.roundToInt
import kotlin.math.roundToLong
import javax.inject.Inject
import javax.inject.Singleton

private val BookSource.requiresConfiguredServer: Boolean
    get() = when (this) {
        BookSource.GRIMMORY,
        BookSource.STORYTELLER,
        BookSource.AUDIOBOOKSHELF,
        BookSource.JELLYFIN,
        BookSource.PLEX,
        BookSource.EMBY,
        BookSource.KOMGA,
        BookSource.KAVITA,
        BookSource.BOOKORBIT,
        BookSource.SILO,
        BookSource.OPDS,
        BookSource.WEBDAV,
        BookSource.SMB -> true
        BookSource.TORBOX,
        BookSource.PREMIUMIZE,
        BookSource.REALDEBRID,
        BookSource.LOCAL -> false
    }

private val GRIMMORY_EBOOK_PROGRESS_TYPES = setOf("EPUB", "PDF", "CBX", "FB2", "MOBI", "AZW3")

private const val GRIMMORY_HOME_LANE_SIZE = 10

private const val KAVITA_PAGE_SIZE = 100

private const val KAVITA_VOLUME_CONCURRENCY = 4

internal fun kavitaReaderFormat(format: Int): String? = when (format) {
    KavitaMangaFormat.IMAGE -> "CBZ"
    KavitaMangaFormat.ARCHIVE -> "CBX"
    KavitaMangaFormat.EPUB -> "EPUB"
    KavitaMangaFormat.PDF -> "PDF"
    else -> null
}

internal fun kavitaPageNum(percentage: Float, pages: Int): Int =
    if (percentage >= FINISHED_PROGRESS_THRESHOLD) pages else (percentage.coerceIn(0f, 1f) * pages).roundToInt().coerceIn(0, pages)

internal fun Request.Builder.applyGrimmoryOidcHeaders(
    headers: Map<String, String>,
): Request.Builder = apply {
    headers.forEach { (key, value) -> header(key, value) }
}

internal fun grimmoryOidcScopes(configuredScopes: String?): String =
    configuredScopes?.takeIf { it.isNotBlank() } ?: "openid profile email groups"

@Serializable
private data class GrimmoryOidcUserDto(val username: String)

private val grimmoryOidcUserJson = Json { ignoreUnknownKeys = true }

internal fun grimmoryOidcUsername(responseBody: String): String =
    grimmoryOidcUserJson.decodeFromString<GrimmoryOidcUserDto>(responseBody).username

internal fun grimmoryEbookFileProgress(
    bookFileId: Long,
    totalProgression: Float,
    checkpointValue: String?,
    bookType: String? = null,
    page: Int? = null,
): GrimmoryFileProgressDto {
    val rawValue = checkpointValue?.trim()
    val normalizedBookType = bookType?.uppercase()
    val pagePosition = when (normalizedBookType) {
        "PDF", "CBX" -> {
            val locatorPage = Regex("""\"page\"\s*:\s*(\d+)""")
                .find(rawValue.orEmpty())
                ?.groupValues
                ?.getOrNull(1)
                ?.toIntOrNull()
                ?: rawValue?.substringAfter(':', "")?.toIntOrNull()
            (page ?: locatorPage)?.coerceAtLeast(1)?.toString()
        }
        else -> null
    }
    val checkpoint = EpubBridgeCheckpointCodec.decode(rawValue)
    val foliateCheckpoint = checkpoint?.takeIf { it.sourceEngine == ReaderEngineKind.FOLIATE }
    val canonicalCfi = foliateCheckpoint?.epubCfi
        ?.trim()
        ?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
    val readiumHref = checkpoint
        ?.takeIf { it.sourceEngine == ReaderEngineKind.READIUM && normalizedBookType != "PDF" && normalizedBookType != "CBX" }
        ?.href
        ?.trim()
        ?.takeIf(String::isNotBlank)
    val positionedCheckpoint = foliateCheckpoint?.takeIf { canonicalCfi != null }
        ?: checkpoint?.takeIf { readiumHref != null }
    val contentSourceProgressPercent = positionedCheckpoint
        ?.resourceProgression
        ?.takeIf { it.isFinite() }
        ?.coerceIn(0.0, 1.0)
        ?.times(100.0)

    return GrimmoryFileProgressDto(
        bookFileId = bookFileId,
        positionData = pagePosition ?: canonicalCfi,
        positionHref = canonicalCfi?.let {
            foliateCheckpoint.href?.trim()?.takeIf(String::isNotBlank)
        } ?: readiumHref,
        progressPercent = (totalProgression.toDouble() * 100.0).coerceIn(0.0, 100.0),
        ttsPositionCfi = null,
        contentSourceProgressPercent = contentSourceProgressPercent,
    )
}

@Singleton
class GrimmoryRepository @Inject constructor(
    private val api: GrimmoryApi,
    private val readingSessionUploader: com.enve.app.data.grimmory.GrimmoryReadingSessionUploader,
    private val komgaRepository: KomgaRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: com.enve.core.data.local.ConnectionRegistry,
    private val torBox: TorBoxCatalog,
    private val torBoxTransport: TorBoxTransport,
    private val kavitaAliases: KavitaLegacyAliasStore,
    private val kavitaCovers: com.enve.app.data.kavita.KavitaCoverRevisionStore,
    @ApplicationContext private val context: Context,
    @ApplicationScope parentScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore = com.enve.core.data.local.ProfileServerSyncStore(context, locations),
    private val catalogFetcher: GrimmoryCatalogFetcher = GrimmoryCatalogFetcher(api, Json { ignoreUnknownKeys = true; coerceInputValues = true }),
    private val catalogImports: CatalogImportStore = CatalogImportStore(locations),
) {

    suspend fun currentUserId(): Result<String> = runSuspendCatching {
        val response = api.getCurrentUser()
        if (!response.isSuccessful) error("Grimmory current user failed: HTTP ${response.code()}")
        response.body()?.id?.takeIf(String::isNotBlank) ?: error("Grimmory account has no stable ID")
    }

    private data class ScopedContext(
        val source: BookSource,
        val serverUrl: String,
        val token: String,
        val connectionId: String?,
        val username: String,
        val cloudRootPaths: List<String> = emptyList(),
    )

    private val ScopedContext.torBoxAccount: TorBoxAccount
        get() = TorBoxAccount(connectionId, serverUrl, token, cloudRootPaths)

    private fun resolveScopedContext(): ScopedContext {
        connectionRegistry.getScopedConnectionSync()?.let { connection ->
            val accessToken = vault.get(CredentialVault.accessTokenKey(connection.id))
            val token = if (connection.source == BookSource.EMBY || connection.source == BookSource.JELLYFIN) {
                accessToken.orEmpty()
            } else {
                accessToken ?: vault.get(CredentialVault.passwordKey(connection.id)) ?: prefs.getAccessTokenSync().orEmpty()
            }
            return ScopedContext(
                source = connection.source,
                serverUrl = connection.serverUrl,
                token = token,
                connectionId = connection.id,
                username = connection.username,
                cloudRootPaths = connection.cloudRootPaths,
            )
        }
        val activeConnectionId = prefs.getActiveConnectionIdSync()
        val activeConnection = activeConnectionId?.let { id ->
            connectionRegistry.getConnectionsSync().find { it.id == id }
        }
        check(ConnectionScope.getConnectionId() == null) { "Connection no longer available" }
        return ScopedContext(
            source = activeConnection?.source ?: prefs.getActiveBookSourceSync(),
            serverUrl = activeConnection?.serverUrl ?: prefs.getServerUrlSync() ?: "",
            token = if (activeConnection != null && (activeConnection.source == BookSource.EMBY || activeConnection.source == BookSource.JELLYFIN)) {
                vault.get(CredentialVault.accessTokenKey(activeConnection.id)).orEmpty()
            } else prefs.getAccessTokenSync().orEmpty(),
            connectionId = activeConnectionId,
            username = activeConnection?.username ?: prefs.getUsernameSync().orEmpty(),
            cloudRootPaths = activeConnection?.cloudRootPaths.orEmpty(),
        )
    }

    private data class CacheScope(
        val source: BookSource,
        val serverUrl: String,
        val connectionId: String?,
        val username: String,
    )

    private data class BookCacheKey(val scope: CacheScope, val bookId: String)

    private val ScopedContext.cacheScope: CacheScope
        get() = CacheScope(source, serverUrl, connectionId, username)

    private val titleOverrides = ConcurrentHashMap<CacheScope, MutableMap<String, String>>()
    private val durationOverrides = ConcurrentHashMap<CacheScope, MutableMap<String, Long>>()
    private val audiobookTitleOverrideCache: MutableMap<String, String>
        get() = titleOverrides.getOrPut(resolveScopedContext().cacheScope) { mutableMapOf() }
    private val audiobookDurationOverrideCache: MutableMap<String, Long>
        get() = durationOverrides.getOrPut(resolveScopedContext().cacheScope) { mutableMapOf() }

    private val detailedBookCache = androidx.collection.LruCache<BookCacheKey, Book>(200)
    private val audiobookInfoCache = androidx.collection.LruCache<BookCacheKey, AudiobookInfoDto>(200)
    @Volatile private var listCachesInvalidatedAt = 0L

    private val backgroundScope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)

    private data class CacheEntry<T>(val data: T, val timestamp: Long = System.currentTimeMillis())
    private val cacheTtlMs = 5 * 60 * 1000L
    private val BOOK_INDEX_MAX_AGE_MS = 30 * 60 * 1000L
    private val LIBRARIES_MAX_AGE_MS = 10 * 60 * 1000L

    private val jsonSerializer = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Serializable
    private data class BookIndexCachePayload(
        val source: String,
        val serverUrl: String,
        val savedAt: Long,
        val libraryId: String? = null,
        val summaries: List<BookSummaryDto> = emptyList(),
        val formatInventoryVersion: Int = 0,

        val titleOverrides: Map<String, String> = emptyMap(),

        val durationOverrides: Map<String, Long> = emptyMap(),
    )

    @Serializable
    private data class LibrariesCachePayload(
        val source: String,
        val serverUrl: String,
        val savedAt: Long,
        val libraries: List<LibraryDto> = emptyList(),
    )

    @Serializable
    private data class HomeLaneCachePayload(
        val source: String,
        val serverUrl: String,
        val lane: String,
        val savedAt: Long,
        val progressUnitsVersion: Int = 0,
        val summaries: List<BookSummaryDto> = emptyList(),
    )

    @Serializable
    private data class GenericBookCachePayload(
        val source: String,
        val serverUrl: String,
        val savedAt: Long,
        val libraryId: String? = null,
        val books: List<Book> = emptyList(),
    )

    private val booksCache = ConcurrentHashMap<CacheScope, CacheEntry<Pair<String?, List<Book>>>>()
    private val librariesCache = ConcurrentHashMap<CacheScope, CacheEntry<List<Library>>>()
    private val recentlyAddedCache = ConcurrentHashMap<CacheScope, CacheEntry<List<Book>>>()

    private val booksFetchMutexes = mutableMapOf<String, Mutex>()
    private fun mutexForBooksKey(key: String): Mutex = synchronized(booksFetchMutexes) {
        booksFetchMutexes.getOrPut(key) { Mutex() }
    }

    private fun <T> CacheEntry<T>.isValid() =
        (System.currentTimeMillis() - this.timestamp) < cacheTtlMs

    fun invalidateListCaches() {
        booksCache.clear()
        librariesCache.clear()
        recentlyAddedCache.clear()
        torBox.invalidate()
        clearTorBoxBookIndexCache()
        listCachesInvalidatedAt = System.currentTimeMillis()
    }

    private fun accountCacheKey(): String {
        val ctx = resolveScopedContext()
        val account = "${ctx.connectionId.orEmpty()}::${ctx.username}"
        return MessageDigest.getInstance("SHA-256").digest(account.toByteArray())
            .joinToString("") { "%02x".format(it) }
    }

    private fun cacheFileForBooks(source: BookSource, serverUrl: String, libraryId: String?): java.io.File {
        val cacheDir = java.io.File(locations.cacheDirectory, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val safeLibrary = (libraryId ?: "all").replace(Regex("[^a-zA-Z0-9._-]"), "_")
        val name = "books_${source.name.lowercase()}_${safeServer}_${accountCacheKey()}_${safeLibrary}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForLibraries(source: BookSource, serverUrl: String): java.io.File {
        val cacheDir = java.io.File(locations.cacheDirectory, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "libraries_scoped_${source.name.lowercase()}_${safeServer}_${accountCacheKey()}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForHomeLane(source: BookSource, serverUrl: String, lane: String): java.io.File {
        val cacheDir = java.io.File(locations.cacheDirectory, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val safeLane = lane.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "lane_${source.name.lowercase()}_${safeServer}_${accountCacheKey()}_${safeLane}.json"
        return java.io.File(cacheDir, name)
    }

    private fun clearTorBoxBookIndexCache() {
        runCatching {
            java.io.File(locations.cacheDirectory, "book-index-cache")
                .listFiles { file -> file.name.startsWith("books_torbox_") }
                ?.forEach { it.delete() }
        }
    }

    private suspend fun loadBooksIndexFromDisk(
        source: BookSource,
        serverUrl: String,
        libraryId: String?,
        notBefore: Long = 0L,
    ): List<BookSummaryDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForBooks(source, serverUrl, libraryId)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<BookIndexCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.libraryId != libraryId) {
                return@runCatching null
            }
            if (source == BookSource.GRIMMORY && payload.formatInventoryVersion != 2) return@runCatching null

            if (System.currentTimeMillis() - payload.savedAt > BOOK_INDEX_MAX_AGE_MS || payload.savedAt < notBefore) {
                return@runCatching null
            }

            if (payload.titleOverrides.isNotEmpty()) {
                synchronized(audiobookTitleOverrideCache) {
                    payload.titleOverrides.forEach { (id, title) ->
                        if (!audiobookTitleOverrideCache.containsKey(id) && title.isNotBlank()) {
                            audiobookTitleOverrideCache[id] = title
                        }
                    }
                }
            }
            if (payload.durationOverrides.isNotEmpty()) {
                synchronized(audiobookDurationOverrideCache) {
                    payload.durationOverrides.forEach { (id, durationSec) ->
                        if (!audiobookDurationOverrideCache.containsKey(id) && durationSec > 0L) {
                            audiobookDurationOverrideCache[id] = durationSec
                        }
                    }
                }
            }
            payload.summaries
        }.getOrNull()
    }

    private suspend fun saveBooksIndexToDisk(
        source: BookSource,
        serverUrl: String,
        libraryId: String?,
        summaries: List<BookSummaryDto>,
    ) = withContext(Dispatchers.IO) {
        runCatching {
            val titleSnapshot = synchronized(audiobookTitleOverrideCache) {
                audiobookTitleOverrideCache.toMap()
            }
            val durationSnapshot = synchronized(audiobookDurationOverrideCache) {
                audiobookDurationOverrideCache.toMap()
            }
            val payload = BookIndexCachePayload(
                source = source.name,
                serverUrl = serverUrl,
                libraryId = libraryId,
                savedAt = System.currentTimeMillis(),
                summaries = summaries,
                formatInventoryVersion = if (source == BookSource.GRIMMORY) 2 else 0,
                titleOverrides = titleSnapshot,
                durationOverrides = durationSnapshot,
            )
            cacheFileForBooks(source, serverUrl, libraryId).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun loadGenericBooksFromDisk(
        source: BookSource,
        serverUrl: String,
        libraryId: String?,
        notBefore: Long,
    ): List<Book>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForBooks(source, serverUrl, libraryId)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<GenericBookCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.libraryId != libraryId) {
                return@runCatching null
            }

            if (System.currentTimeMillis() - payload.savedAt > 3600_000 || payload.savedAt < notBefore) return@runCatching null
            payload.books
        }.getOrNull()
    }

    private suspend fun saveGenericBooksToDisk(
        source: BookSource,
        serverUrl: String,
        libraryId: String?,
        books: List<Book>,
    ) = withContext(Dispatchers.IO) {
        runCatching {
            val payload = GenericBookCachePayload(
                source = source.name,
                serverUrl = serverUrl,
                libraryId = libraryId,
                savedAt = System.currentTimeMillis(),
                books = books,
            )
            cacheFileForBooks(source, serverUrl, libraryId).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun loadLibrariesFromDisk(
        source: BookSource,
        serverUrl: String,
        notBefore: Long = 0L,
    ): List<LibraryDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForLibraries(source, serverUrl)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<LibrariesCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.savedAt < notBefore) return@runCatching null
            payload.libraries
        }.getOrNull()
    }

    private suspend fun saveLibrariesToDisk(
        source: BookSource,
        serverUrl: String,
        libraries: List<LibraryDto>,
    ) = withContext(Dispatchers.IO) {
        runCatching {
            val payload = LibrariesCachePayload(
                source = source.name,
                serverUrl = serverUrl,
                savedAt = System.currentTimeMillis(),
                libraries = libraries,
            )
            cacheFileForLibraries(source, serverUrl).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun loadHomeLaneFromDisk(
        source: BookSource,
        serverUrl: String,
        lane: String,
        notBefore: Long = 0L,
    ): List<BookSummaryDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForHomeLane(source, serverUrl, lane)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<HomeLaneCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.lane != lane || payload.savedAt < notBefore) return@runCatching null
            if (source == BookSource.GRIMMORY && payload.progressUnitsVersion != 1) return@runCatching null
            payload.summaries
        }.getOrNull()
    }

    private suspend fun saveHomeLaneToDisk(
        source: BookSource,
        serverUrl: String,
        lane: String,
        summaries: List<BookSummaryDto>,
    ) = withContext(Dispatchers.IO) {
        runCatching {
            val payload = HomeLaneCachePayload(
                source = source.name,
                serverUrl = serverUrl,
                lane = lane,
                savedAt = System.currentTimeMillis(),
                progressUnitsVersion = 1,
                summaries = summaries,
            )
            cacheFileForHomeLane(source, serverUrl, lane).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    suspend fun loginWithToken(
        source: BookSource,
        serverUrl: String,
        username: String,
        accessToken: String,
    ): Result<Unit> {
        return try {
            if (serverUrl.isBlank()) {
                return Result.failure(Exception("Server URL is required"))
            }
            if (accessToken.isBlank()) {
                return Result.failure(Exception("Access token is required"))
            }

            if (source == BookSource.TORBOX) torBoxTransport.verifyToken(serverUrl, accessToken)

            prefs.setActiveBookSource(source)
            prefs.saveServerInfo(
                url = serverUrl,
                username = username.ifBlank { "token-user" },
            )
            invalidateListCaches()
            prefs.saveAuth(accessToken = accessToken, refreshToken = null)
            Result.success(Unit)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun refreshAuth(): Result<Unit> {
        return try {
            val token = prefs.refreshToken.first() ?: return Result.failure(Exception("No refresh token"))
            val response = api.refreshToken(RefreshRequest(token))
            if (response.isSuccessful) {
                val auth = response.body()!!
                prefs.saveAuth(auth.accessToken, auth.refreshToken)
                Result.success(Unit)
            } else {
                Result.failure(Exception("Refresh failed"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun logout() {
        val serverUrl = prefs.getServerUrlSync()
        prefs.clearAuth()
        if (serverUrl != null) {
            vault.remove(CredentialVault.kosyncUsernameKey(serverUrl))
            vault.remove(CredentialVault.kosyncPasswordKey(serverUrl))
        }
        vault.remove(CredentialVault.KEY_PASSWORD)
        invalidateListCaches()
    }

    private suspend fun <T> withSourceContext(source: BookSource, block: suspend () -> Result<T>): Result<T> {
        if (ConnectionScope.getConnectionId() != null) {
            return block()
        }
        val previous = prefs.getActiveBookSourceSync()
        if (previous != source) {
            prefs.setActiveBookSource(source)
        }
        return try {
            block()
        } finally {
            if (previous != source) {
                prefs.setActiveBookSource(previous)
            }
        }
    }

    suspend fun getLibrariesForSource(source: BookSource): Result<List<Library>> = withSourceContext(source) {
        getLibraries()
    }

    suspend fun getBooksForSource(
        source: BookSource,
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc",
    ): Result<List<Book>> = withSourceContext(source) {
        getBooks(libraryId = libraryId, page = page, size = size, sort = sort, dir = dir)
    }

    suspend fun getContinueListeningForSource(source: BookSource): Result<List<Book>> = withSourceContext(source) {
        getContinueListening()
    }

    suspend fun getContinueReadingForSource(source: BookSource): Result<List<Book>> = withSourceContext(source) {
        getContinueReading()
    }

    suspend fun getRecentlyAddedForSource(source: BookSource): Result<List<Book>> = withSourceContext(source) {
        getRecentlyAdded()
    }

    suspend fun getLibraries(): Result<List<Library>> {
        val ctx = resolveScopedContext()
        librariesCache[ctx.cacheScope]?.takeIf { it.isValid() }?.let { return Result.success(it.data) }
        return try {
            val source = ctx.source
            val serverUrl = ctx.serverUrl
            if (source.requiresConfiguredServer && serverUrl.isBlank()) {
                return Result.success(emptyList())
            }

            if (source == BookSource.GRIMMORY) {
                val notBefore = maxOf(listCachesInvalidatedAt, System.currentTimeMillis() - LIBRARIES_MAX_AGE_MS)
                val cached = loadLibrariesFromDisk(source, serverUrl, notBefore)
                if (!cached.isNullOrEmpty()) {
                    val mapped = cached.map { it.toLibrary() }
                    librariesCache[ctx.cacheScope] = CacheEntry(mapped)
                    return Result.success(mapped)
                }
            }

            val libs = when (source) {
                BookSource.GRIMMORY -> {
                    val response = api.getCatalogLibraries().catalogResponse()
                    if (!response.isSuccessful) {
                        return Result.failure(Exception("Failed to fetch libraries (HTTP ${response.code()})"))
                    }
                    val dto = response.body().orEmpty()
                    saveLibrariesToDisk(source, serverUrl, dto)
                    dto.map { it.toLibrary() }
                }

                BookSource.JELLYFIN -> fetchJellyfinLibraries()
                BookSource.EMBY -> fetchEmbyLibraries()
                BookSource.KAVITA -> fetchKavitaLibraries()
                BookSource.OPDS -> listOf(Library(id = "opds-root", name = "OPDS Catalog", bookCount = 0))
                BookSource.WEBDAV -> listOf(Library(id = "webdav-root", name = "WebDAV Root", bookCount = 0))
                BookSource.TORBOX -> torBox.libraries(ctx.cloudRootPaths)
                BookSource.PREMIUMIZE -> listOf(Library(id = "premiumize-cloud", name = "Premiumize Cloud", bookCount = 0, source = BookSource.PREMIUMIZE))
                BookSource.REALDEBRID -> listOf(Library(id = "realdebrid-downloads", name = "Real-Debrid Downloads", bookCount = 0, source = BookSource.REALDEBRID))
                BookSource.SMB -> listOf(Library(id = "smb-root", name = "SMB Share", bookCount = 0))
                BookSource.LOCAL -> listOf(Library(id = "local-root", name = "Local Files", bookCount = 0))
                else -> emptyList()
            }
            librariesCache[ctx.cacheScope] = CacheEntry(libs)
            Result.success(libs)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            val source = ctx.source
            if (source == BookSource.GRIMMORY) {
                val serverUrl = ctx.serverUrl
                val cached = loadLibrariesFromDisk(source, serverUrl)
                if (!cached.isNullOrEmpty()) {
                    val mapped = cached.map { it.toLibrary() }
                    librariesCache[ctx.cacheScope] = CacheEntry(mapped)
                    return Result.success(mapped)
                }
            }
            Result.failure(e)
        }
    }

    suspend fun getBooks(
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc"
    ): Result<List<Book>> {
        val ctx = resolveScopedContext()
        if (ctx.source == BookSource.TORBOX) return runSuspendCatching { torBox.books(ctx.torBoxAccount, libraryId) }
        booksCache[ctx.cacheScope]?.takeIf { it.isValid() && it.data.first == libraryId && !catalogImports.hasIssue(ctx.connectionId, libraryId) }?.let { return Result.success(it.data.second) }
        val coalesceKey = "${ctx.source.name}|${ctx.serverUrl}|${accountCacheKey()}|${libraryId ?: ""}"
        return mutexForBooksKey(coalesceKey).withLock {
            booksCache[ctx.cacheScope]?.takeIf { it.isValid() && it.data.first == libraryId && !catalogImports.hasIssue(ctx.connectionId, libraryId) }?.let { return@withLock Result.success(it.data.second) }
            doFetchBooks(libraryId, page, size, sort, dir, ctx)
        }
    }

    private suspend fun doFetchBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
        ctx: ScopedContext,
    ): Result<List<Book>> {
        return try {
            val source = ctx.source
            val serverUrl = ctx.serverUrl
            val token = ctx.token
            if (source.requiresConfiguredServer && serverUrl.isBlank()) {
                return Result.success(emptyList())
            }

            if (source == BookSource.GRIMMORY) {
                val cachedSummaries = loadBooksIndexFromDisk(source, serverUrl, libraryId, listCachesInvalidatedAt)
                if (!cachedSummaries.isNullOrEmpty() && !catalogImports.hasIssue(ctx.connectionId, libraryId)) {
                    val cachedMapped = appendCompanionAudiobooks(cachedSummaries.toBooks(serverUrl, token), serverUrl, token)
                    val withOverrides = applyCachedTitleOverrides(cachedMapped)
                    booksCache[ctx.cacheScope] = CacheEntry(Pair(libraryId, withOverrides))
                    resolveAmbiguousAudiobookTitlesInBackground(
                        books = cachedMapped,
                        source = source,
                        serverUrl = serverUrl,
                        libraryId = libraryId,
                        cachedSummaries = cachedSummaries,
                    )
                    return Result.success(withOverrides)
                }
            } else if (source != BookSource.TORBOX) {
                val cached = loadGenericBooksFromDisk(source, serverUrl, libraryId, listCachesInvalidatedAt)
                if (!cached.isNullOrEmpty()) {
                    booksCache[ctx.cacheScope] = CacheEntry(Pair(libraryId, cached))
                    return Result.success(cached)
                }
            }

            val resolved = when (source) {
                BookSource.GRIMMORY -> {
                    val batch = catalogFetcher.fetch(libraryId, page, size, sort, dir)
                    var report = batch.report
                    val mapped = appendCompanionAudiobooks(batch.books.toBooks(serverUrl, token) {
                        report = report.rejecting(CatalogRejectionReason.INVALID_RECORD)
                    }, serverUrl, token)
                    val resolvedTitles = resolveAmbiguousAudiobookTitles(mapped, api, audiobookTitleOverrideCache, audiobookDurationOverrideCache)
                    if (!report.isComplete) {
                        return Result.failure(CatalogImportException(resolvedTitles, listOf(report.copy(acceptedCount = resolvedTitles.size))))
                    }
                    saveBooksIndexToDisk(source, serverUrl, libraryId, batch.books)
                    resolvedTitles
                }

                BookSource.JELLYFIN -> fetchJellyfinBooks(libraryId = libraryId, serverUrl = serverUrl)
                BookSource.EMBY -> fetchEmbyBooks(libraryId = libraryId, serverUrl = serverUrl)
                BookSource.KAVITA -> fetchKavitaBooks(libraryId = libraryId, ctx = ctx)
                BookSource.OPDS -> fetchOpdsBooks(serverUrl = serverUrl)
                BookSource.WEBDAV -> fetchWebDavBooks(serverUrl = serverUrl)
                BookSource.TORBOX -> torBox.books(ctx.torBoxAccount, libraryId)
                BookSource.PREMIUMIZE -> fetchPremiumizeBooks(ctx)
                BookSource.REALDEBRID -> fetchRealDebridBooks(ctx)
                else -> emptyList()
            }

            if (source != BookSource.GRIMMORY && source != BookSource.TORBOX) {
                saveGenericBooksToDisk(source, serverUrl, libraryId, resolved)
            }

            booksCache[ctx.cacheScope] = CacheEntry(Pair(libraryId, resolved))
            Result.success(resolved)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            if (e is CatalogImportException) return Result.failure(e)
            if (ctx.source == BookSource.GRIMMORY) {
                val failure = CatalogFailure(
                    if (e is java.io.IOException) CatalogFailureKind.NETWORK else CatalogFailureKind.INVALID_PAGE,
                    CatalogImportStage.BOOKS,
                )
                val cachedSummaries = loadBooksIndexFromDisk(ctx.source, ctx.serverUrl, libraryId)
                if (!cachedSummaries.isNullOrEmpty()) {
                    val cachedMapped = appendCompanionAudiobooks(cachedSummaries.toBooks(ctx.serverUrl, ctx.token), ctx.serverUrl, ctx.token)
                    val resolved = resolveAndEnrichAudiobooks(cachedMapped, ctx.serverUrl, ctx.token)
                    return Result.failure(CatalogImportException(resolved, listOf(CatalogImportReport(
                        acceptedCount = resolved.size,
                        failures = listOf(failure),
                    ))))
                }
                return Result.failure(CatalogImportException(emptyList(), listOf(CatalogImportReport(
                    failures = listOf(failure),
                ))))
            }
            Result.failure(e)
        }
    }

    suspend fun getBookDetail(bookId: String, forceRefresh: Boolean = false): Result<Book> {
        return try {
            val ctx = resolveScopedContext()
            val source = ctx.source
            val rawBookId = if (source == BookSource.GRIMMORY) bookId.grimmoryServerBookId() else bookId
            val cacheKey = BookCacheKey(ctx.cacheScope, bookId)
            if (!forceRefresh) {
                detailedBookCache.get(cacheKey)?.let { return Result.success(serverSync.catalogBook(it)) }
            }

            if (source != BookSource.GRIMMORY) {
                val fromList = getBooks().getOrNull()?.firstOrNull { it.id == bookId }
                if (fromList != null) {
                    detailedBookCache.put(cacheKey, fromList)
                    return Result.success(fromList)
                }
                return Result.failure(Exception("Book not found for ${source.displayName}"))
            }

            val response = api.getBook(rawBookId)
            if (response.isSuccessful) {
                val serverUrl = ctx.serverUrl
                val token = ctx.token
                val detail = response.body()!!.toBookDetailDto().withAudiobookProgress()
                val mapped = detail.toBook(serverUrl, token)
                val book = if (rawBookId != bookId || mapped.mediaType == AppMediaType.AUDIOBOOK) {
                    val base = if (rawBookId != bookId) mapped.companionAudiobook(serverUrl, token) ?: mapped else mapped
                    mergeListedAudiobook(base, detail, api.getAudiobookInfo(rawBookId).body(), serverUrl, token)
                } else {
                    mergeListedEbook(mapped, detail, serverUrl, token)
                }
                val sanitized = serverSync.catalogBook(book)
                detailedBookCache.put(cacheKey, sanitized)
                Result.success(sanitized)
            } else {
                Result.failure(Exception("Failed to fetch book detail"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun hydrateHomeShelfBooks(books: List<Book>): List<Book> = coroutineScope {
        if (books.isEmpty()) return@coroutineScope books
        val cacheScope = resolveScopedContext().cacheScope

        val candidates = books
            .filter { it.mediaType == AppMediaType.AUDIOBOOK }
            .filter {
                it.narrator.isNullOrBlank() ||
                    (it.progress > 0f && (it.currentTime <= 0L || it.duration <= 0L))
            }
            .distinctBy { it.id }
            .take(18)

        if (candidates.isEmpty()) return@coroutineScope books

        val semaphore = Semaphore(4)
        candidates.map { book ->
            async {
                semaphore.withPermit {
                    getBookDetail(book.id).getOrNull()
                }
            }
        }.awaitAll()

        books.map { book ->
            detailedBookCache.get(BookCacheKey(cacheScope, book.id)) ?: book
        }
    }

    suspend fun getContinueListening(): Result<List<Book>> {
        val ctx = resolveScopedContext()
        val source = ctx.source
        if (source != BookSource.GRIMMORY) {
            val all = getBooks().getOrElse { return Result.failure(it) }
            val lane = all
                .asSequence()
                .filter { it.mediaType == AppMediaType.AUDIOBOOK }
                .filter { it.progress in 0.01f..FINISHED_PROGRESS_THRESHOLD || it.lastReadTime > 0L }
                .sortedByDescending { it.lastReadTime }
                .take(20)
                .toList()
            return Result.success(lane)
        }

        return try {
            val serverUrl = ctx.serverUrl
            val token = ctx.token

            val summaries = fetchHomeLane(
                sort = "-lastReadTime",
                facets = GRIMMORY_READING_STATUSES.map { grimmoryFacet("read_status", it) } + grimmoryFacet("file_type", "AUDIOBOOK"),
            )
            if (summaries != null) {
                saveHomeLaneToDisk(source, serverUrl, "continue-listening", summaries)
                val books = summaries.toBooks(serverUrl, token)
                val resolved = resolveAndEnrichAudiobooks(books, serverUrl, token)
                val lane = resolved
                    .filter { it.mediaType == AppMediaType.AUDIOBOOK && it.isEligibleForGrimmoryContinue() }
                    .takeIf { it.isNotEmpty() }
                    ?: deriveContinueListeningFromLibrary()
                Result.success(lane)
            } else {
                val fallback = deriveContinueListeningFromLibrary()
                if (fallback.isNotEmpty()) {
                    Result.success(fallback)
                } else {
                    Result.failure(Exception("Failed to fetch continue listening"))
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            val serverUrl = ctx.serverUrl
            val token = ctx.token
            val diskFallback = loadHomeLaneFromDisk(source, serverUrl, "continue-listening")
                ?.toBooks(serverUrl, token)
                .orEmpty()
            if (diskFallback.isNotEmpty()) {
                val resolved = resolveAndEnrichAudiobooks(diskFallback, serverUrl, token)
                return Result.success(resolved.filter { it.mediaType == AppMediaType.AUDIOBOOK && it.isEligibleForGrimmoryContinue() })
            }
            val fallback = runSuspendCatching { deriveContinueListeningFromLibrary() }.getOrDefault(emptyList())
            if (fallback.isNotEmpty()) {
                Result.success(fallback)
            } else {
                Result.failure(e)
            }
        }
    }

    private suspend fun deriveContinueListeningFromLibrary(): List<Book> {
        val all = getBooks(size = 250).getOrDefault(emptyList())
        return all
            .asSequence()
            .filter { it.mediaType == AppMediaType.AUDIOBOOK }
            .filter { it.isEligibleForGrimmoryContinue() }
            .filter {
                val p = it.progress
                p in 0.01f..FINISHED_PROGRESS_THRESHOLD || it.currentTime > 0L || it.lastReadTime > 0L
            }
            .sortedByDescending { it.lastReadTime }
            .take(20)
            .toList()
    }

    suspend fun getContinueReading(): Result<List<Book>> {
        val ctx = resolveScopedContext()
        val source = ctx.source
        if (source != BookSource.GRIMMORY) {
            val all = getBooks().getOrElse { return Result.failure(it) }
            val lane = all
                .asSequence()
                .filter { it.mediaType == AppMediaType.EBOOK }
                .filter { it.readProgress in 0.01f..FINISHED_PROGRESS_THRESHOLD }
                .sortedByDescending { it.lastReadTime }
                .take(20)
                .toList()
            return Result.success(lane)
        }

        return try {
            val serverUrl = ctx.serverUrl
            val token = ctx.token

            val summaries = fetchHomeLane(
                sort = "-lastReadTime",
                facets = GRIMMORY_READING_STATUSES.map { grimmoryFacet("read_status", it) } +
                    GRIMMORY_EBOOK_FILE_TYPES.map { grimmoryFacet("file_type", it) },
            )
            if (summaries != null) {
                saveHomeLaneToDisk(source, serverUrl, "continue-reading", summaries)
                val books = summaries.toBooks(serverUrl, token)
                val resolved = resolveAndEnrichAudiobooks(books, serverUrl, token)
                val lane = resolved
                    .filter { it.mediaType == AppMediaType.EBOOK && it.isEligibleForGrimmoryContinue() }
                    .takeIf { it.isNotEmpty() }
                    ?: deriveContinueReadingFromLibrary()
                Result.success(lane)
            } else {
                val fallback = deriveContinueReadingFromLibrary()
                if (fallback.isNotEmpty()) {
                    Result.success(fallback)
                } else {
                    Result.failure(Exception("Failed to fetch continue reading"))
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            val serverUrl = ctx.serverUrl
            val token = ctx.token
            val diskFallback = loadHomeLaneFromDisk(source, serverUrl, "continue-reading")
                ?.toBooks(serverUrl, token)
                .orEmpty()
            if (diskFallback.isNotEmpty()) {
                val resolved = resolveAndEnrichAudiobooks(diskFallback, serverUrl, token)
                return Result.success(resolved.filter { it.mediaType == AppMediaType.EBOOK && it.isEligibleForGrimmoryContinue() })
            }
            val fallback = runSuspendCatching { deriveContinueReadingFromLibrary() }.getOrDefault(emptyList())
            if (fallback.isNotEmpty()) {
                Result.success(fallback)
            } else {
                Result.failure(e)
            }
        }
    }

    private suspend fun deriveContinueReadingFromLibrary(): List<Book> {
        val all = getBooks(size = 250).getOrDefault(emptyList())
        return all
            .asSequence()
            .filter { it.mediaType == AppMediaType.EBOOK }
            .filter { it.isEligibleForGrimmoryContinue() }
            .filter { (it.epubProgress ?: it.readProgress) in 0.01f..FINISHED_PROGRESS_THRESHOLD }
            .sortedByDescending { it.lastReadTime }
            .take(20)
            .toList()
    }

    private fun Book.isEligibleForGrimmoryContinue(): Boolean {
        if (isFinished || hideFromContinue) return false
        val status = serverReadStatus?.uppercase() ?: return true
        return status == "READING" || status == "RE_READING"
    }

    suspend fun getRecentlyAdded(): Result<List<Book>> {
        val ctx = resolveScopedContext()
        val source = ctx.source
        if (source != BookSource.GRIMMORY) {
            val all = getBooks().getOrElse { return Result.failure(it) }
            val lane = all
                .sortedByDescending { it.addedOn }
                .take(20)
            return Result.success(lane)
        }

        recentlyAddedCache[ctx.cacheScope]?.takeIf { it.isValid() }?.let { return Result.success(it.data) }
        return try {
            val serverUrl = ctx.serverUrl
            val token = ctx.token

            val cachedSummaries = loadHomeLaneFromDisk(source, serverUrl, "recently-added", listCachesInvalidatedAt)
            if (!cachedSummaries.isNullOrEmpty()) {
                val cached = resolveAndEnrichAudiobooks(cachedSummaries.toBooks(serverUrl, token), serverUrl, token)
                recentlyAddedCache[ctx.cacheScope] = CacheEntry(cached)
                return Result.success(cached)
            }

            val summaries = fetchHomeLane(sort = "-addedOn")
            if (summaries != null) {
                saveHomeLaneToDisk(source, serverUrl, "recently-added", summaries)
                val books = summaries.toBooks(serverUrl, token)
                val resolved = resolveAndEnrichAudiobooks(books, serverUrl, token)
                val lane = resolved.takeIf { it.isNotEmpty() } ?: deriveRecentlyAddedFromLibrary()
                recentlyAddedCache[ctx.cacheScope] = CacheEntry(lane)
                Result.success(lane)
            } else {
                val fallback = deriveRecentlyAddedFromLibrary()
                if (fallback.isNotEmpty()) {
                    recentlyAddedCache[ctx.cacheScope] = CacheEntry(fallback)
                    Result.success(fallback)
                } else {
                    Result.failure(Exception("Failed to fetch recently added"))
                }
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            val serverUrl = ctx.serverUrl
            val token = ctx.token
            val diskFallback = loadHomeLaneFromDisk(source, serverUrl, "recently-added")
                ?.toBooks(serverUrl, token)
                .orEmpty()
            if (diskFallback.isNotEmpty()) {
                val resolved = resolveAndEnrichAudiobooks(diskFallback, serverUrl, token)
                recentlyAddedCache[ctx.cacheScope] = CacheEntry(resolved)
                return Result.success(resolved)
            }
            val fallback = runSuspendCatching { deriveRecentlyAddedFromLibrary() }.getOrDefault(emptyList())
            if (fallback.isNotEmpty()) {
                recentlyAddedCache[ctx.cacheScope] = CacheEntry(fallback)
                Result.success(fallback)
            } else {
                Result.failure(e)
            }
        }
    }

    private suspend fun deriveRecentlyAddedFromLibrary(): List<Book> {
        val all = getBooks(size = 250).getOrDefault(emptyList())
        return all
            .asSequence()
            .sortedByDescending { it.addedOn }
            .take(20)
            .toList()
    }

    private suspend fun fetchHomeLane(sort: String, facets: List<String> = emptyList()): List<BookSummaryDto>? {
        val response = api.getBooksPage(facets = facets, sort = sort, size = GRIMMORY_HOME_LANE_SIZE)
        if (!response.isSuccessful) return null
        return response.body()?.content?.filter { sort != "-lastReadTime" || it.lastReadTime != null }
            ?.map { it.toCatalogSummary(fallbackLibraryId = null) }
    }

    private val plainOidcClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
            .writeTimeout(10, java.util.concurrent.TimeUnit.SECONDS)
            .build()
    }
    private val plainJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

    suspend fun getPublicSettings(
        serverUrl: String,
        headers: Map<String, String> = emptyMap(),
    ): Result<PublicSettingsDto> = runSuspendCatching {
        withContext(Dispatchers.IO) {
            val url = "${serverUrl.trimEnd('/')}/api/v1/public-settings"
            val req = Request.Builder().url(url).get()
                .header("Accept", "application/json")
                .applyGrimmoryOidcHeaders(headers)
                .build()
            plainOidcClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) error("Failed to fetch Grimmory public settings (HTTP ${resp.code})")
                plainJson.decodeFromString(PublicSettingsDto.serializer(), resp.body?.string().orEmpty())
            }
        }
    }

    suspend fun getOidcState(
        serverUrl: String,
        headers: Map<String, String> = emptyMap(),
    ): Result<OidcStateDto> = runSuspendCatching {
        withContext(Dispatchers.IO) {
            val url = "${serverUrl.trimEnd('/')}/api/v1/auth/oidc/state"
            val req = Request.Builder().url(url).get()
                .header("Accept", "application/json")
                .applyGrimmoryOidcHeaders(headers)
                .build()
            plainOidcClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) error("OIDC state fetch failed (HTTP ${resp.code})")
                plainJson.decodeFromString(OidcStateDto.serializer(), resp.body?.string().orEmpty())
            }
        }
    }

    suspend fun oidcCallback(
        serverUrl: String,
        code: String,
        state: String,
        codeVerifier: String? = null,
        redirectUri: String? = null,
        nonce: String? = null,
        headers: Map<String, String> = emptyMap(),
    ): Result<String?> = runSuspendCatching {
        withContext(Dispatchers.IO) {

            val url = "${serverUrl.trimEnd('/')}/api/v1/auth/oidc/callback"

            val payload = plainJson.encodeToString(
                OidcCallbackRequest.serializer(),
                OidcCallbackRequest(
                    code = code,
                    state = state,
                    codeVerifier = codeVerifier,
                    redirectUri = redirectUri,
                    nonce = nonce,
                ),
            )

            val req = Request.Builder()
                .url(url)
                .header("Accept", "application/json")
                .post(payload.toRequestBody("application/json".toMediaType()))
                .applyGrimmoryOidcHeaders(headers)
                .build()
            plainOidcClient.newCall(req).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    error("OIDC callback failed: HTTP ${resp.code}" + if (body.isNotBlank()) ": ${body.take(200)}" else "")
                }
                val auth = plainJson.decodeFromString(AuthResponse.serializer(), body)
                prefs.saveAuth(auth.accessToken, auth.refreshToken)
                fetchGrimmoryOidcUsername(serverUrl, auth.accessToken, headers)
            }
        }
    }

    private fun fetchGrimmoryOidcUsername(
        serverUrl: String,
        accessToken: String,
        headers: Map<String, String>,
    ): String? {
        val request = Request.Builder()
            .url("${serverUrl.trimEnd('/')}/api/v1/users/me")
            .header("Accept", "application/json")
            .header("Authorization", "Bearer $accessToken")
            .applyGrimmoryOidcHeaders(headers)
            .build()
        return plainOidcClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return@use null
            grimmoryOidcUsername(response.body?.string().orEmpty())
        }
    }

    suspend fun buildGrimmoryOidcAuthorizationUrl(
        serverUrl: String,
        redirectUri: String,
        codeChallenge: String,
        state: String,
        nonce: String,
        headers: Map<String, String> = emptyMap(),
    ): Result<String> = runSuspendCatching {
        val body = getPublicSettings(serverUrl, headers).getOrThrow()
        if (body.oidcEnabled != true) error("OIDC is not enabled on this Grimmory server")
        val provider = body.oidcProviderDetails
            ?: error("Grimmory server is missing oidcProviderDetails (issuerUri/clientId). Update the server.")
        val issuer = provider.issuerUri?.trimEnd('/').orEmpty()
        val clientId = provider.clientId.orEmpty()
        if (issuer.isBlank() || clientId.isBlank()) error("Grimmory OIDC provider is missing issuerUri or clientId")

        val discoveryUrl = "$issuer/.well-known/openid-configuration"
        val authorizationEndpoint = withContext(Dispatchers.IO) {
            val req = okhttp3.Request.Builder().url(discoveryUrl).get().build()

            val client = OkHttpClient.Builder().build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) error("OIDC discovery failed: HTTP ${resp.code}")
                val text = resp.body?.string().orEmpty()
                jsonSerializer.decodeFromString(OidcDiscoveryDto.serializer(), text)
                    .authorizationEndpoint
                    ?: error("OIDC discovery response missing authorization_endpoint")
            }
        }

        val scopes = grimmoryOidcScopes(provider.scopes)
        val authUrl = authorizationEndpoint.toHttpUrlOrNull()?.newBuilder()
            ?: error("Invalid authorization endpoint URL: $authorizationEndpoint")
        authUrl
            .addQueryParameter("response_type", "code")
            .addQueryParameter("client_id", clientId)
            .addQueryParameter("redirect_uri", redirectUri)
            .addQueryParameter("scope", scopes)
            .addQueryParameter("code_challenge", codeChallenge)
            .addQueryParameter("code_challenge_method", "S256")
            .addQueryParameter("state", state)
            .addQueryParameter("nonce", nonce)
        authUrl.build().toString()
    }

    suspend fun getUserStats(): Result<UserStatsDto> {
        val source = resolveScopedContext().source
        if (source != BookSource.GRIMMORY) return Result.success(UserStatsDto())

        return try {

            val streak = api.getReadingStreak().body()
            val listening = api.getListeningCompletion().body()

            val dto = UserStatsDto(
                booksFinished = listening?.completed,
                booksInProgress = listening?.inProgressCount,
                currentStreak = streak?.currentStreak,
                longestStreak = streak?.longestStreak,
                totalReadingDays = streak?.totalReadingDays,
            )
            Result.success(dto)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            Result.success(UserStatsDto())
        }
    }

    suspend fun getSeries(): Result<List<SeriesSummaryDto>> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) {
                val books = getBooks(size = 500).getOrDefault(emptyList())
                val series = books.asSequence()
                    .filter { !it.seriesName.isNullOrBlank() }
                    .groupBy { it.seriesName!!.trim() }
                    .map { (name, grouped) ->
                        SeriesSummaryDto(
                            name = name,
                            bookCount = grouped.size,
                            bookIds = grouped.map { it.id },
                        )
                    }
                    .sortedBy { it.name.lowercase() }
                    .toList()
                return Result.success(series)
            }

            Result.success(fetchAllSeries())
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private suspend fun fetchAllSeries(): List<SeriesSummaryDto> {
        val series = mutableListOf<SeriesSummaryDto>()
        var page = 0
        do {
            val response = api.getSeriesFacet(page = page)
            if (!response.isSuccessful) error("getSeries HTTP ${response.code()}")
            val body = response.body() ?: break
            body.facets.flatMap { it.links }.forEach { facetValue ->
                val name = facetValue.value?.takeIf(String::isNotBlank) ?: return@forEach
                series += SeriesSummaryDto(name = name, bookCount = facetValue.properties?.numberOfItems?.toInt())
            }
            page++
        } while (body.hasNext)
        return series
    }

    private fun com.enve.app.data.remote.dto.AuthorSummaryDto.toCore() =
        AuthorSummaryDto(id = id, name = name, bookCount = bookCount)

    suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> {
        if (!serverSync.isEnabled) return Result.success(Unit)
        return try {
            val serverId = bookId.grimmoryServerBookId().toLongOrNull()
                ?: return Result.failure(Exception("Unrecognized Grimmory book id"))
            val response = api.updateReadStatus(ReadStatusUpdateRequest(bookIds = listOf(serverId), status = status))
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Failed to update book status"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateBookRating(bookId: String, rating: Int): Result<Unit> {
        return try {
            val serverId = bookId.grimmoryServerBookId().toLongOrNull()
                ?: return Result.failure(Exception("Unrecognized Grimmory book id"))

            val response = api.updateBookRating(UpdateRatingRequest(ids = listOf(serverId), rating = rating.coerceIn(1, 5) * 2))
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(com.enve.core.data.provider.ProviderMutationException(response.code(), "Failed to update book rating"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getAuthors(search: String? = null): Result<List<AuthorSummaryDto>> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) {
                val query = search?.trim()?.lowercase().orEmpty()
                val authors = getBooks(size = 500)
                    .getOrDefault(emptyList())
                    .asSequence()
                    .mapNotNull { it.author }
                    .flatMap { author -> author.split(",").map { it.trim() } }
                    .filter { it.isNotBlank() }
                    .groupBy { it }
                    .map { (name, grouped) ->
                        AuthorSummaryDto(
                            id = name.lowercase().replace(" ", "-"),
                            name = name,
                            bookCount = grouped.size,
                        )
                    }
                    .filter { query.isBlank() || it.name.lowercase().contains(query) }
                    .sortedBy { it.name.lowercase() }
                    .toList()
                return Result.success(authors)
            }

            Result.success(fetchAllAuthors(search))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private suspend fun fetchAllAuthors(search: String?): List<AuthorSummaryDto> = coroutineScope {
        val query = search?.takeIf(String::isNotBlank)
        val first = api.getAuthors(query = query)
        if (!first.isSuccessful) error("getAuthors HTTP ${first.code()}")
        val firstBody = first.body() ?: return@coroutineScope emptyList()
        val totalPages = firstBody.page.totalPages
        if (totalPages <= 1 || firstBody.content.isEmpty()) return@coroutineScope firstBody.content.map { it.toCore() }

        val semaphore = Semaphore(8)
        val rest = (1 until totalPages).map { p ->
            async {
                semaphore.withPermit {
                    api.getAuthors(query = query, page = p).body()?.content.orEmpty().map { it.toCore() }
                }
            }
        }.awaitAll().flatten()
        firstBody.content.map { it.toCore() } + rest
    }

    suspend fun getAudiobookInfo(bookId: String): Result<AudiobookInfoDto> {
        return try {
            val response = api.getAudiobookInfo(bookId.grimmoryServerBookId())
            if (response.isSuccessful) {
                Result.success(response.body()!!)
            } else {
                Result.failure(Exception("Failed to fetch audiobook info"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private suspend fun resolveAudiobookInfo(bookId: String): AudiobookInfoDto? {
        val key = BookCacheKey(resolveScopedContext().cacheScope, bookId)
        return audiobookInfoCache.get(key)
            ?: getAudiobookInfo(bookId).getOrNull()?.also { audiobookInfoCache.put(key, it) }
    }

    suspend fun getStreamUrl(bookId: String): String {
        val ctx = resolveScopedContext()
        return "${ctx.serverUrl}/api/v1/audiobooks/${bookId.grimmoryServerBookId()}/stream?token=${ctx.token}"
    }

    suspend fun getTrackStreamUrl(bookId: String, trackIndex: Int): String {
        val ctx = resolveScopedContext()
        return "${ctx.serverUrl}/api/v1/audiobooks/${bookId.grimmoryServerBookId()}/track/$trackIndex/stream?token=${ctx.token}"
    }

    suspend fun getCoverUrl(bookId: String, isAudiobook: Boolean = true): String {
        val ctx = resolveScopedContext()
        val rawBookId = bookId.grimmoryServerBookId()
        val path = if (isAudiobook) "api/v1/audiobooks/$rawBookId/cover" else "api/v1/media/book/$rawBookId/thumbnail"
        return "${ctx.serverUrl}/$path?token=${ctx.token}"
    }

    suspend fun getEbookDownloadUrl(bookId: String): String {
        val ctx = resolveScopedContext()
        return when (ctx.source) {
            BookSource.AUDIOBOOKSHELF -> "${ctx.serverUrl.trimEnd('/')}/api/items/$bookId/ebook"
            BookSource.KOMGA -> komgaRepository.getEbookDownloadUrl(bookId)
                ?: "${ctx.serverUrl.trimEnd('/')}/api/v1/books/$bookId/file"
            BookSource.OPDS -> if (bookId.startsWith("http://", ignoreCase = true) || bookId.startsWith("https://", ignoreCase = true)) {
                bookId
            } else {
                resolveAgainst(ctx.serverUrl, bookId)
            }

            BookSource.GRIMMORY -> getEbookResource(bookId).url
            else -> grimmoryBookContentUrl(ctx.serverUrl, bookId.grimmoryServerBookId())
        }
    }

    suspend fun getEbookResource(bookId: String): ProviderEbookResource {
        val ctx = resolveScopedContext()
        if (ctx.source != BookSource.GRIMMORY) {
            return ProviderEbookResource(getEbookDownloadUrl(bookId))
        }
        val rawBookId = bookId.grimmoryServerBookId()
        val detail = api.getBook(rawBookId, withDescription = false).body()?.toBookDetailDto()
        val ebookFile = detail?.progressFile(locator = null)
        val bookType = ebookFile?.resolvedProgressType() ?: "EPUB"
        return ProviderEbookResource(
            url = grimmoryBookContentUrl(ctx.serverUrl, rawBookId, bookType = bookType),
            providerFileId = ebookFile?.id,
            format = bookType,
        )
    }

    suspend fun getShelves(): Result<List<Shelf>> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) {
                val libraries = getLibraries().getOrDefault(emptyList())
                return Result.success(libraries.map { Shelf(id = it.id, name = it.name, bookCount = it.bookCount) })
            }

            val response = api.getShelves()
            if (response.isSuccessful) {
                val shelves = response.body()?.map { Shelf(it.id, it.name, it.bookCount ?: 0) } ?: emptyList()
                Result.success(shelves)
            } else {
                Result.failure(Exception("Failed to fetch shelves"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getShelfBooks(shelfId: String): Result<List<Book>> {
        return try {
            val ctx = resolveScopedContext()
            if (ctx.source != BookSource.GRIMMORY) {
                return getBooks(libraryId = shelfId)
            }

            val response = api.getShelfBooks(shelfId)
            if (response.isSuccessful) {
                val books = response.body().orEmpty().map { it.toBookSummaryDto(fallbackLibraryId = null) }.toBooks(ctx.serverUrl, ctx.token)
                Result.success(resolveAmbiguousAudiobookTitles(books, api, audiobookTitleOverrideCache))
            } else {
                Result.failure(Exception("Failed to fetch shelf books"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun savedShelfBookIds(name: String): Result<Set<String>> = runSuspendCatching {
        val shelf = getShelves().getOrThrow().firstOrNull { it.name.equals(name, ignoreCase = true) }
            ?: return@runSuspendCatching emptySet()
        val books = getShelfBooks(shelf.id).getOrThrow()
        if (books.size < shelf.bookCount) error("Saved shelf response is incomplete")
        books.mapTo(mutableSetOf()) { it.id.grimmoryServerBookId() }
    }

    suspend fun setSavedShelfBook(book: Book, name: String, saved: Boolean): Result<Unit> = runSuspendCatching {
        val shelf = getShelves().getOrThrow().firstOrNull { it.name.equals(name, ignoreCase = true) }
        val shelfId = if (shelf != null) shelf.id.toLongOrNull() ?: error("Shelf ID is invalid")
        else if (saved) {
            val icon = if (name == "Favorites") "heart" else "bookmark"
            val response = api.createShelf(GrimmoryCreateShelfRequest(name, icon))
            if (!response.isSuccessful) error("Create shelf failed: HTTP ${response.code()}")
            response.body()?.id?.toLongOrNull() ?: error("Create shelf returned no ID")
        } else return@runSuspendCatching
        val bookId = book.id.grimmoryServerBookId().toLongOrNull() ?: error("Book ID is invalid")
        val response = api.assignShelf(
            GrimmoryShelfAssignmentRequest(
                bookIds = listOf(bookId),
                shelvesToAssign = if (saved) listOf(shelfId) else emptyList(),
                shelvesToUnassign = if (saved) emptyList() else listOf(shelfId),
            ),
        )
        if (!response.isSuccessful) error("Update shelf failed: HTTP ${response.code()}")
    }

    suspend fun fetchAudiobookProgress(book: com.enve.core.data.model.Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        if (!serverSync.isEnabled) return Result.success(null)
        return try {
            val response = api.getAppBookProgress(book.id.grimmoryServerBookId())
            val body = response.body() ?: return Result.success(null)
            val snapshot = grimmoryAudiobookProgressSnapshot(
                body = body,
                updatedAtMs = parseIsoToEpochMs(body.audiobookProgress?.updatedAt),
            ) ?: return Result.success(null)
            val ab = body.audiobookProgress
            val trackStarts = if ((ab?.trackIndex ?: 0) > 0) {
                resolveAudiobookInfo(book.id)?.trackStartsByIndex()
            } else null
            Result.success(snapshot.copy(positionMs = grimmoryGlobalAudiobookPositionMs(ab, trackStarts)))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchEbookProgress(book: com.enve.core.data.model.Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        if (!serverSync.isEnabled) return Result.success(null)
        return try {
            val rawBookId = book.id.grimmoryServerBookId()
            val response = api.getBook(rawBookId, withDescription = false)
            if (!response.isSuccessful) {
                error("Grimmory ebook progress failed: HTTP ${response.code()}")
            }
            val detail = response.body()?.toBookDetailDto()
                ?: error("Grimmory ebook progress returned an empty response.")
            val body = detail.toProgressDto()
            val snapshot = grimmoryEbookProgressSnapshot(
                body = body,
                updatedAtMs = parseIsoToEpochMs(body.lastReadTime),
                audioProgressPresent = body.audiobookProgress != null || detail.hasAudioFormat(),
            )
            val epubProgress = body.epubProgress
            if (snapshot == null || snapshot.epubCfi != null || epubProgress == null) {
                return Result.success(snapshot)
            }
            Result.success(grimmoryPositionedEbookSnapshot(snapshot, epubProgress.href, epubProgress))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun parseIsoToEpochMs(iso: String?): Long? {
        if (iso.isNullOrBlank()) return null
        return runCatching { java.time.OffsetDateTime.parse(iso).toInstant().toEpochMilli() }
            .recoverCatching { java.time.Instant.parse(iso).toEpochMilli() }
            .recoverCatching { java.time.LocalDateTime.parse(iso).toInstant(java.time.ZoneOffset.UTC).toEpochMilli() }
            .getOrNull()
    }

    suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return Result.success(Unit)
        return try {
            if (resolveScopedContext().source != BookSource.GRIMMORY) return Result.success(Unit)
            val numericBookId = book.id.grimmoryServerBookId().toLongOrNull()
                ?: return Result.failure(Exception("Grimmory book id is not numeric: ${book.id}"))

            val info = resolveAudiobookInfo(book.id)
            val bookFileId = info?.bookFileId?.toLongOrNull()?.takeIf { it > 0 }
            if (bookFileId == null) {
                Log.w("GrimmoryRepository", "No bookFileId for '${book.title}' - skipping audiobook position push")
                return Result.success(Unit)
            }

            val tracks = info.tracks.orEmpty()
            val multiFile = (info.folderBased == true || tracks.size > 1) && tracks.isNotEmpty()
            val wire = grimmoryEncodeAudiobookPosition(
                globalMs = currentTimeSec * 1000L,
                multiFile = multiFile,
                trackStartsByIndex = info.trackStartsByIndex(),
            )

            if (!serverSync.accepts(syncStartedAt)) return Result.success(Unit)
            val response = api.postBookProgress(
                GrimmoryProgressRequest(
                    bookId = numericBookId,
                    fileProgress = GrimmoryFileProgressDto(
                        bookFileId = bookFileId,
                        positionData = wire.positionData,
                        positionHref = wire.positionHref,
                        progressPercent = (progressFraction.toDouble() * 100.0).coerceIn(0.0, 100.0),
                    ),
                )
            )
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Audiobook progress sync failed: HTTP ${response.code()}"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun createReadingSession(
        bookId: String,
        startTime: Instant,
        endTime: Instant,
        durationMs: Long,
        mediaType: AppMediaType,
        startProgress: Float? = null,
        endProgress: Float? = null,
        endLocation: String? = null,
        fileType: String? = null,
    ): Result<Unit> {
        if (!serverSync.accepts(startTime.toEpochMilli())) return Result.success(Unit)
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) return Result.success(Unit)
            val numericBookId = bookId.grimmoryServerBookId().toLongOrNull()
                ?: return Result.failure(IllegalArgumentException("Invalid Grimmory book ID: $bookId"))
            val durationSeconds = (durationMs / 1_000.0)
                .roundToLong()
                .coerceIn(0, Int.MAX_VALUE.toLong())
                .toInt()
            val startPercent = startProgress?.coerceIn(0f, 1f)?.let { round(it * 1_000f) / 10f }
            val endPercent = endProgress?.coerceIn(0f, 1f)?.let { round(it * 1_000f) / 10f }
            val endLocationNumber = endLocation?.toIntOrNull()
            val startLocation = if (endLocationNumber != null && startPercent != null && endPercent != null && endPercent > 0f) {
                (endLocationNumber * (startPercent / endPercent)).roundToInt().coerceAtLeast(1).toString()
            } else {
                null
            }
            readingSessionUploader.upload(
                ReadingSessionRequest(
                    bookId = numericBookId,
                    bookType = if (mediaType == AppMediaType.AUDIOBOOK) "AUDIOBOOK" else grimmoryBookType(fileType),
                    startTime = startTime.toString(),
                    endTime = endTime.toString(),
                    durationSeconds = durationSeconds,
                    durationFormatted = formatReadingSessionDuration(durationSeconds),
                    startProgress = startPercent,
                    endProgress = endPercent,
                    progressDelta = if (startPercent != null && endPercent != null) endPercent - startPercent else null,
                    startLocation = startLocation,
                    endLocation = endLocation,
                )
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun formatReadingSessionDuration(durationSeconds: Int): String {
        val hours = durationSeconds / 3_600
        val minutes = durationSeconds % 3_600 / 60
        val seconds = durationSeconds % 60
        return buildList {
            if (hours > 0) add("${hours}h")
            if (minutes > 0 || hours > 0) add("${minutes}m")
            add("${seconds}s")
        }.joinToString(" ")
    }

    suspend fun getReadingSessions(bookId: String, page: Int = 0, size: Int = 20): Result<List<ReadingSessionResponseDto>> {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return Result.success(emptyList())
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) return Result.success(emptyList())
            val response = api.getReadingSessionsForBook(bookId = bookId.grimmoryServerBookId(), page = page, size = size)
            if (!serverSync.accepts(syncStartedAt)) return Result.success(emptyList())
            if (response.isSuccessful) Result.success(response.body()?.content.orEmpty())
            else Result.failure(Exception("Failed to fetch reading sessions: HTTP ${response.code()}"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getRemoteBookmarks(bookId: String): Result<List<GrimmoryBookmarkDto>> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) return Result.success(emptyList())
            val response = api.getBookmarksForBook(bookId.grimmoryServerBookId())
            if (response.isSuccessful) Result.success(response.body().orEmpty())
            else Result.failure(Exception("Failed to fetch bookmarks: HTTP ${response.code()}"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun createRemoteBookmark(book: Book, bookmark: AudiobookBookmark): Result<GrimmoryBookmarkDto> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) return Result.failure(Exception("Remote bookmarks are unavailable for ${source.displayName}"))
            val numericBookId = book.id.grimmoryServerBookId().toIntOrNull()
                ?: return Result.failure(Exception("Remote bookmarks require a numeric Grimmory book id"))
            val response = api.createBookmark(
                GrimmoryBookmarkCreateRequest(
                    bookId = numericBookId,
                    title = bookmark.title,
                    notes = bookmark.note,
                    cfi = bookmark.locator,
                    positionMs = (bookmark.position * 1000L).coerceAtMost(Int.MAX_VALUE.toLong()).toInt(),
                    trackIndex = 0,
                )
            )
            if (response.isSuccessful) Result.success(response.body()!!)
            else Result.failure(Exception("Bookmark create failed: HTTP ${response.code()}"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun deleteRemoteBookmark(bookmarkId: Int): Result<Unit> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) return Result.success(Unit)
            val response = api.deleteBookmark(bookmarkId.toLong())
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Bookmark delete failed: HTTP ${response.code()}"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        page: Int? = null,
    ): Result<Unit> {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return Result.success(Unit)
        return try {
            val source = resolveScopedContext().source
            when (source) {
                BookSource.GRIMMORY -> {
                    val rawBookId = bookId.grimmoryServerBookId()
                    val numericBookId = rawBookId.toLongOrNull()
                        ?: return Result.failure(Exception("Grimmory book id is not numeric: $bookId"))
                    val detail = api.getBook(rawBookId, withDescription = false).body()?.toBookDetailDto()
                        ?: return Result.failure(Exception("Grimmory book detail was unavailable: $bookId"))
                    val progressFile = detail.progressFile(locator)
                        ?: return Result.failure(Exception("Grimmory ebook file id was unavailable: $bookId"))
                    val bookFileId = progressFile.id?.toLongOrNull()
                        ?: return Result.failure(Exception("Grimmory ebook file id was invalid: $bookId"))
                    if (!serverSync.accepts(syncStartedAt)) return Result.success(Unit)
                    val response = api.postBookProgress(
                        GrimmoryProgressRequest(
                            bookId = numericBookId,
                            fileProgress = grimmoryEbookFileProgress(
                                bookFileId = bookFileId,
                                totalProgression = percentage,
                                checkpointValue = locator,
                                bookType = progressFile.resolvedProgressType(),
                                page = page,
                            ),
                        )
                    )
                    if (response.isSuccessful) Result.success(Unit)
                    else Result.failure(Exception("Ebook progress sync failed: HTTP ${response.code()}"))
                }
                else -> Result.success(Unit)
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun BookDetailDto.progressFile(locator: String?): BookFileDto? {
        val candidates = buildList {
            primaryFile?.let(::add)
            addAll(files.orEmpty())
        }.distinctBy { it.id }
        val expectedType = when {
            Regex("""\"page\"\s*:\s*\d+""").containsMatchIn(locator.orEmpty()) -> "PDF"
            Regex("""^(cbz|cbx|cbr)-page:""", RegexOption.IGNORE_CASE).containsMatchIn(locator.orEmpty()) -> "CBX"
            else -> primaryFile?.resolvedProgressType()
        }
        if (expectedType != null && expectedType != "AUDIOBOOK") {
            candidates.firstOrNull { it.resolvedProgressType() == expectedType }?.let { return it }
        }
        return candidates.firstOrNull { it.resolvedProgressType() in GRIMMORY_EBOOK_PROGRESS_TYPES }
    }

    private fun BookFileDto.resolvedProgressType(): String? {
        val values = listOf(
            bookType,
            fileExtension,
            fileName?.substringAfterLast('.', ""),
            filePath?.substringAfterLast('.', ""),
        )
        return values.firstNotNullOfOrNull { value ->
            when (value?.trim()?.uppercase()) {
                "CBX", "CBZ", "CBR", "CB7" -> "CBX"
                "AZW" -> "AZW3"
                "EPUB" -> "EPUB"
                "PDF" -> "PDF"
                "FB2" -> "FB2"
                "MOBI" -> "MOBI"
                "AZW3" -> "AZW3"
                "AUDIOBOOK" -> "AUDIOBOOK"
                else -> null
            }
        }
    }

    private fun List<BookSummaryDto>.toBooks(serverUrl: String, token: String, onRejected: (() -> Unit)? = null): List<Book> {
        return mapNotNull { summary ->
            try {
                summary.toBook(serverUrl, token, grimmoryPercentFraction(summary.readProgress) ?: 0f)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                if (onRejected == null) throw e
                onRejected()
                null
            }
        }
    }

    private fun appendCompanionAudiobooks(books: List<Book>, serverUrl: String, token: String? = null): List<Book> {
        if (books.none { it.source == BookSource.GRIMMORY && it.mediaType == AppMediaType.EBOOK && it.hasAudio }) return books
        return buildList(books.size) {
            books.forEach { book ->
                add(book)
                book.companionAudiobook(serverUrl, token)?.let { add(it) }
            }
        }
    }

    private suspend fun resolveAndEnrichAudiobooks(books: List<Book>, serverUrl: String, token: String? = null): List<Book> {
        val withCompanions = appendCompanionAudiobooks(books, serverUrl, token)
        val resolved = resolveAmbiguousAudiobookTitles(withCompanions, api, audiobookTitleOverrideCache, audiobookDurationOverrideCache)
        return runSuspendCatching { enrichFetchedBooks(resolved, serverUrl, token) }.getOrDefault(resolved)
    }

    private fun applyCachedTitleOverrides(books: List<Book>): List<Book> {
        val titleSnapshot = synchronized(audiobookTitleOverrideCache) { audiobookTitleOverrideCache.toMap() }
        val durationSnapshot = synchronized(audiobookDurationOverrideCache) { audiobookDurationOverrideCache.toMap() }
        if (titleSnapshot.isEmpty() && durationSnapshot.isEmpty()) return books
        return books.map { book ->
            val newTitle = titleSnapshot[book.id]?.takeIf { it.isNotBlank() }
            val newDuration = durationSnapshot[book.id]?.takeIf { it > 0L }
            when {
                newTitle != null && newDuration != null -> book.copy(title = newTitle, duration = newDuration)
                newTitle != null -> book.copy(title = newTitle)
                newDuration != null -> book.copy(duration = newDuration)
                else -> book
            }
        }
    }

    private fun resolveAmbiguousAudiobookTitlesInBackground(
        books: List<Book>,
        source: BookSource,
        serverUrl: String,
        libraryId: String?,
        cachedSummaries: List<BookSummaryDto>,
    ) {
        val needsResolve = books.any { book ->
            if (book.mediaType != AppMediaType.AUDIOBOOK) return@any false
            val titleMissing = synchronized(audiobookTitleOverrideCache) {
                !audiobookTitleOverrideCache.containsKey(book.id)
            }
            val durationMissing = book.duration <= 0L && synchronized(audiobookDurationOverrideCache) {
                (audiobookDurationOverrideCache[book.id] ?: 0L) <= 0L
            }
            titleMissing || durationMissing
        }
        if (!needsResolve) return

        val connectionId = resolveScopedContext().connectionId
        backgroundScope.launch(ConnectionScope.asContextElement(connectionId)) {
            try {
                val titleSizeBefore = synchronized(audiobookTitleOverrideCache) { audiobookTitleOverrideCache.size }
                val durationSizeBefore = synchronized(audiobookDurationOverrideCache) { audiobookDurationOverrideCache.size }
                resolveAmbiguousAudiobookTitles(books, api, audiobookTitleOverrideCache, audiobookDurationOverrideCache)
                val titleSizeAfter = synchronized(audiobookTitleOverrideCache) { audiobookTitleOverrideCache.size }
                val durationSizeAfter = synchronized(audiobookDurationOverrideCache) { audiobookDurationOverrideCache.size }
                if (titleSizeAfter > titleSizeBefore || durationSizeAfter > durationSizeBefore) {
                    saveBooksIndexToDisk(source, serverUrl, libraryId, cachedSummaries)
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                android.util.Log.w("GrimmoryRepository", "Background audiobook resolve failed", e)
            }
        }
    }

    private suspend fun enrichFetchedBooks(books: List<Book>, serverUrl: String, token: String? = null): List<Book> = coroutineScope {
        val semaphore = Semaphore(4)
        books.map { book ->
            async {
                when {
                    book.mediaType == AppMediaType.AUDIOBOOK ->
                        semaphore.withPermit { enrichListedAudiobook(book, serverUrl, token) }
                    book.mediaType == AppMediaType.EBOOK && (book.epubProgress ?: book.readProgress) > 0f ->
                        semaphore.withPermit { enrichListedEbook(book, serverUrl, token) }
                    else -> book
                }
            }
        }.awaitAll()
    }

    private suspend fun enrichListedAudiobook(book: Book, serverUrl: String, token: String? = null): Book {
        val rawBookId = book.id.grimmoryServerBookId()
        val detail = api.getBook(rawBookId).body()?.toBookDetailDto()?.withAudiobookProgress()
        val info = api.getAudiobookInfo(rawBookId).body()
        return mergeListedAudiobook(book, detail?.copyWithResolvedMediaType(), info, serverUrl, token)
    }

    private suspend fun BookDetailDto.withAudiobookProgress(): BookDetailDto {
        if (!hasAudioFormat()) return this
        val progress = api.getAppBookProgress(id)
        if (!progress.isSuccessful) error("Grimmory audiobook progress failed: HTTP ${progress.code()}")
        val body = progress.body() ?: error("Grimmory audiobook progress returned an empty response")
        return copy(audiobookProgress = body.audiobookProgress)
    }

    private suspend fun enrichListedEbook(book: Book, serverUrl: String, token: String? = null): Book {
        val detail = api.getBook(book.id.grimmoryServerBookId()).body()?.toBookDetailDto()?.copyWithResolvedMediaType() ?: return book
        return mergeListedEbook(book, detail, serverUrl, token)
    }

    private suspend fun fetchJellyfinLibraries(): List<Library> {
        val userId = api.jellyfinMe().jellyfinBody("user lookup").Id
        check(userId.isNotBlank()) { "Jellyfin user lookup returned no user ID" }
        return api.jellyfinViews(userId).jellyfinBody("library discovery").items
            .mapNotNull { it.toBookLibraryOrNull() }
    }

    private suspend fun fetchJellyfinBooks(libraryId: String?, serverUrl: String): List<Book> {
        val userId = api.jellyfinMe().jellyfinBody("user lookup").Id
        check(userId.isNotBlank()) { "Jellyfin user lookup returned no user ID" }
        val parentId = libraryId ?: fetchJellyfinLibraries().firstOrNull()?.id ?: return emptyList()
        return mediaBrowserPages { start ->
            api.jellyfinItems(userId = userId, parentId = parentId, startIndex = start).jellyfinBody("item loading")
        }.mapNotNull { it.toJellyfinBook(serverUrl, parentId) }
    }

    private suspend fun fetchEmbyLibraries(): List<Library> {
        val userId = fetchEmbyUserId() ?: error("Emby user unavailable")
        val viewsResponse = api.embyViews(userId)
        if (!viewsResponse.isSuccessful) throw retrofit2.HttpException(viewsResponse)
        return requireNotNull(viewsResponse.body()).items.mapNotNull { it.toBookLibraryOrNull() }
    }

    private suspend fun fetchEmbyBooks(libraryId: String?, serverUrl: String): List<Book> {
        val userId = fetchEmbyUserId() ?: error("Emby user unavailable")

        val parentId = libraryId ?: fetchEmbyLibraries().firstOrNull()?.id ?: return emptyList()
        return mediaBrowserPages { start ->
            val response = api.embyItems(userId = userId, parentId = parentId, startIndex = start)
            if (!response.isSuccessful) throw retrofit2.HttpException(response)
            requireNotNull(response.body())
        }.mapNotNull { it.toEmbyBook(serverUrl, parentId) }
    }

    private suspend fun fetchEmbyUserId(): String? {
        val username = resolveScopedContext().username
        if (username.isBlank()) return null
        val response = api.embyUsers()
        if (!response.isSuccessful) return null
        return response.body()
            ?.firstOrNull { it.Name.equals(username, ignoreCase = true) }
            ?.Id
    }

    private suspend fun fetchKavitaLibraries(): List<Library> {
        val response = api.kavitaLibraries()
        if (!response.isSuccessful) error("Kavita libraries failed (HTTP ${response.code()})")
        return response.body().orEmpty().map { Library(id = it.id.toString(), name = it.name) }
    }

    private suspend fun fetchKavitaBooks(libraryId: String?, ctx: ScopedContext): List<Book> {
        val filter = KavitaSeriesFilterDto.forLibrary(libraryId)
        val series = mutableListOf<KavitaSeriesDto>()
        var pageNumber = 1
        do {
            val response = api.kavitaSeries(pageNumber = pageNumber, pageSize = KAVITA_PAGE_SIZE, filter = filter)
            if (!response.isSuccessful) error("Kavita series failed (HTTP ${response.code()})")
            val page = response.body().orEmpty()
            series += page
            pageNumber++
        } while (page.size == KAVITA_PAGE_SIZE)

        val permits = Semaphore(KAVITA_VOLUME_CONCURRENCY)
        val volumesBySeries = coroutineScope {
            series.map { item ->
                async {
                    permits.withPermit { item.id to kavitaVolumes(item.id) }
                }
            }.awaitAll().toMap()
        }
        val pins = kavitaAliases.pin(
            ctx.kavitaAliasKey,
            volumesBySeries.mapValues { (_, volumes) -> kavitaLegacyChapterCandidate(volumes) },
        )
        val libraryTypes = api.kavitaLibraries().takeIf { it.isSuccessful }?.body().orEmpty().associate { it.id to it.type }
        val base = ctx.serverUrl.trimEnd('/')
        return series.flatMap { item ->
            val libraryType = (item.libraryId ?: libraryId?.toIntOrNull())?.let(libraryTypes::get)
            volumesBySeries[item.id]
                ?.let { expandKavitaSeries(item, it, pins[item.id], ctx.serverUrl, libraryId, libraryType, kavitaCovers.revision) }
                ?.takeIf { it.isNotEmpty() }
                ?: listOf(kavitaSeriesBook(item, base, libraryId, libraryType))
        }
    }

    private fun kavitaSeriesBook(item: KavitaSeriesDto, base: String, libraryId: String?, libraryType: Int?): Book = Book(
        id = item.id.toString(),
        title = item.name.orEmpty(),
        coverUrl = "$base/api/image/series-cover?seriesId=${item.id}&enveCoverRevision=series:${item.id}:${kavitaCovers.revision}",
        source = BookSource.KAVITA,
        mediaType = AppMediaType.EBOOK,
        primaryFileType = kavitaReaderFormat(item.format),
        libraryId = item.libraryId?.toString() ?: libraryId,
        pageCount = item.pages.takeIf { it > 0 },
        readProgress = if (item.pages > 0) (item.pagesRead.toFloat() / item.pages).coerceIn(0f, 1f) else 0f,
        addedOn = parseIsoToEpochMs(item.created) ?: 0L,
        lastReadTime = parseIsoToEpochMs(item.latestReadDate)?.takeIf { item.pagesRead > 0 } ?: 0L,
        comic = kavitaSeriesComicMetadata(item, libraryType),
    )

    private val ScopedContext.kavitaAliasKey: String
        get() = connectionId ?: "${serverUrl.trimEnd('/')}|$username"

    suspend fun getKavitaEbookDownloadUrl(bookId: String): String? = withSourceContext(BookSource.KAVITA) {
        runSuspendCatching {
            val issue = kavitaIssue(bookId)
            "${resolveScopedContext().serverUrl.trimEnd('/')}/api/Download/chapter?chapterId=${issue.chapter.id}"
        }
    }.getOrThrow()

    suspend fun syncKavitaEbookProgress(bookId: String, percentage: Float): Result<Unit> =
        withSourceContext(BookSource.KAVITA) {
            runSuspendCatching {
                val issue = kavitaIssue(bookId)
                val libraryId = api.kavitaSeriesDetail(issue.seriesId).body()?.libraryId
                    ?: error("Kavita series ${issue.seriesId} has no library")
                val response = api.kavitaSaveProgress(
                    KavitaSaveProgressDto(
                        seriesId = issue.seriesId,
                        libraryId = libraryId,
                        volumeId = issue.volume.id,
                        chapterId = issue.chapter.id,
                        pageNum = kavitaPageNum(percentage, issue.chapter.pages),
                    ),
                )
                if (!response.isSuccessful) error("Kavita progress sync failed (HTTP ${response.code()})")
            }
        }

    suspend fun fetchKavitaEbookProgress(bookId: String): Result<SyncSnapshot?> =
        withSourceContext(BookSource.KAVITA) {
            runSuspendCatching {
                val chapter = kavitaIssue(bookId).chapter
                val response = api.kavitaProgress(chapter.id)
                if (!response.isSuccessful) error("Kavita progress fetch failed (HTTP ${response.code()})")
                val pageNum = response.body()?.pageNum ?: 0
                if (pageNum <= 0 || chapter.pages <= 0) return@runSuspendCatching null
                SyncSnapshot(
                    percentage = (pageNum.toFloat() / chapter.pages).coerceIn(0f, 1f),
                    source = BookSource.KAVITA.displayName,
                    updatedAt = parseIsoToEpochMs(response.body()?.lastModifiedUtc),
                    finished = pageNum >= chapter.pages,
                )
            }
        }

    private suspend fun kavitaIssue(bookId: String): KavitaIssue {
        val ref = kavitaBookRef(bookId) ?: error("Unrecognized Kavita book id")
        val volumes = kavitaVolumes(ref.seriesId)
        val legacyChapterId = (ref as? KavitaBookRef.Legacy)?.let {
            kavitaAliases.pin(
                resolveScopedContext().kavitaAliasKey,
                mapOf(it.seriesId to kavitaLegacyChapterCandidate(volumes)),
            )[it.seriesId]
        }
        return resolveKavitaIssue(ref, volumes, legacyChapterId)
    }

    private suspend fun kavitaVolumes(seriesId: Int): List<KavitaVolumeDto> {
        val response = api.kavitaVolumes(seriesId)
        if (!response.isSuccessful) error("Kavita volumes failed (HTTP ${response.code()})")
        return response.body().orEmpty()
    }

    private suspend fun fetchOpdsBooks(serverUrl: String): List<Book> {
        val baseCandidates = listOf(
            serverUrl.trimEnd('/'),
            "${serverUrl.trimEnd('/')}/opds",
            "${serverUrl.trimEnd('/')}/opds/",
        ).distinct().filter { it.isNotBlank() }

        var opdsText: String? = null
        for (url in baseCandidates) {
            val text = runSuspendCatching {
                val response = api.fetchRawUrl(url)
                if (!response.isSuccessful) return@runSuspendCatching null
                response.body()?.string()
            }.getOrNull()
            if (!text.isNullOrBlank()) {
                opdsText = text
                break
            }
        }
        val resolvedOpdsText = opdsText ?: return emptyList()

        val entryRegex = Regex("<entry\\b[\\s\\S]*?</entry>", RegexOption.IGNORE_CASE)
        val linkRegex = Regex("<link\\b[^>]*>", RegexOption.IGNORE_CASE)

        return entryRegex.findAll(resolvedOpdsText).mapNotNull { match ->
            val entry = match.value
            val title = extractXmlTag(entry, "title") ?: return@mapNotNull null
            val summary = extractXmlTag(entry, "summary") ?: extractXmlTag(entry, "content")
            val authorBlock = Regex("<author\\b[\\s\\S]*?</author>", RegexOption.IGNORE_CASE)
                .find(entry)
                ?.value
            val author = authorBlock?.let { extractXmlTag(it, "name") }

            val links = linkRegex.findAll(entry).map { it.value }.toList()
            val acquisitionHref = links.firstNotNullOfOrNull { linkTag ->
                val type = extractHtmlAttr(linkTag, "type")?.lowercase().orEmpty()
                val rel = extractHtmlAttr(linkTag, "rel")?.lowercase().orEmpty()
                val href = extractHtmlAttr(linkTag, "href")
                val isAcq = rel.contains("acquisition") ||
                    type.contains("epub") ||
                    type.contains("pdf") ||
                    type.contains("cbz") ||
                    type.contains("audio")
                if (isAcq) href else null
            } ?: links.firstNotNullOfOrNull { extractHtmlAttr(it, "href") }

            val coverHref = links.firstNotNullOfOrNull { linkTag ->
                val rel = extractHtmlAttr(linkTag, "rel")?.lowercase().orEmpty()
                if (rel.contains("image")) extractHtmlAttr(linkTag, "href") else null
            }

            val resolvedItemUrl = acquisitionHref?.let { resolveAgainst(serverUrl, it) }
            val id = resolvedItemUrl
                ?: extractXmlTag(entry, "id")
                ?: title

            val mediaType = inferMediaTypeFromPath(resolvedItemUrl ?: "")

            Book(
                id = id,
                title = decodeXmlEntities(title),
                author = author?.let { decodeXmlEntities(it) },
                description = summary?.let { decodeXmlEntities(stripXmlTags(it)) },
                coverUrl = coverHref?.let { resolveAgainst(serverUrl, it) },
                source = BookSource.OPDS,
                mediaType = mediaType,
                libraryId = "opds-root",
            )
        }.toList()
    }

    private suspend fun fetchWebDavBooks(serverUrl: String): List<Book> {
        val base = serverUrl.trimEnd('/')
        if (base.isBlank()) return emptyList()

        suspend fun listingFor(url: String): String? {
            val propfind = runSuspendCatching {
                val response = api.propfindRawUrl(url, body = webDavPropfindBody())
                check(response.isSuccessful)
                response.body()?.string()
            }
            if (propfind.isSuccess) return propfind.getOrNull()
            return runSuspendCatching {
                val response = api.fetchRawUrl(url)
                if (!response.isSuccessful) return@runSuspendCatching null
                response.body()?.string()
            }.getOrNull()
        }

        val supportedExtensions = setOf("epub", "kepub", "pdf", "cbz", "cbr", "cbx", "mobi", "azw3", "mp3", "m4b", "aac", "flac", "ogg")
        val pendingDirs = ArrayDeque<String>().apply { add("$base/") }
        val visitedDirs = mutableSetOf<String>()
        val candidateFiles = linkedSetOf<String>()

        while (pendingDirs.isNotEmpty() && visitedDirs.size < 200 && candidateFiles.size < 5_000) {
            val dir = pendingDirs.removeFirst().trimEnd('/') + "/"
            if (!visitedDirs.add(dir)) continue
            val listing = listingFor(dir) ?: continue
            hrefsFromListing(dir, listing).forEach { href ->
                val clean = href.substringBefore('#').substringBefore('?')
                if (clean.trimEnd('/') == dir.trimEnd('/')) return@forEach
                if (clean.endsWith("/")) {
                    if (clean !in visitedDirs && pendingDirs.size < 500) pendingDirs.add(clean)
                    return@forEach
                }
                val ext = clean.substringAfterLast('.', "").lowercase()
                if (ext in supportedExtensions) candidateFiles += clean
            }
        }

        return candidateFiles.mapNotNull { path ->
            val clean = path.substringBefore('#').substringBefore('?')
            if (clean.endsWith("/")) return@mapNotNull null
            val fileName = clean.substringAfterLast('/').takeIf { it.isNotBlank() } ?: return@mapNotNull null

            val mediaType = inferMediaTypeFromPath(clean)
            Book(
                id = clean,
                title = fileName.substringBeforeLast('.').replace('_', ' '),
                source = BookSource.WEBDAV,
                mediaType = mediaType,
                libraryId = "webdav-root",
            )
        }
    }

    private suspend fun fetchPremiumizeBooks(ctx: ScopedContext): List<Book> {
        val files = fetchPremiumizeAudioFiles(normalizedPremiumizeBase(ctx.serverUrl))
        return groupCloudAudioFiles(files)
            .map {
                it.toCloudBook(
                    source = BookSource.PREMIUMIZE,
                    libraryId = "premiumize-cloud",
                    libraryName = "Premiumize Cloud",
                    idPrefix = "premiumize",
                    stableScope = ctx.connectionId ?: ctx.serverUrl,
                )
            }
            .sortedBy { it.title.lowercase() }
    }

    private suspend fun fetchRealDebridBooks(ctx: ScopedContext): List<Book> {
        val base = normalizedRealDebridBase(ctx.serverUrl)
        val files = fetchRealDebridTorrentAudioFiles(base) + fetchRealDebridDownloadAudioFiles(base)
        return groupCloudAudioFiles(files)
            .map {
                it.toCloudBook(
                    source = BookSource.REALDEBRID,
                    libraryId = "realdebrid-downloads",
                    libraryName = "Real-Debrid Downloads",
                    idPrefix = "realdebrid",
                    stableScope = ctx.connectionId ?: ctx.serverUrl,
                )
            }
            .sortedBy { it.title.lowercase() }
    }

    suspend fun getTorBoxRootCandidates(connectionId: String): Result<List<String>> = runSuspendCatching {
        withContext(ConnectionScope.asContextElement(connectionId)) {
            torBox.rootCandidates(resolveScopedContext().torBoxAccount)
        }
    }

    private suspend fun fetchPremiumizeAudioFiles(baseUrl: String): List<CloudAudioFile> {
        if (baseUrl.isBlank()) return emptyList()
        val pendingFolders = ArrayDeque<Pair<String?, String?>>().apply { add(null to null) }
        val visitedFolderIds = mutableSetOf<String>()
        val files = mutableListOf<CloudAudioFile>()

        while (pendingFolders.isNotEmpty() && visitedFolderIds.size < 500 && files.size < 5_000) {
            val (folderId, folderName) = pendingFolders.removeFirst()
            if (folderId != null && !visitedFolderIds.add(folderId)) continue

            fetchPremiumizeFolder(baseUrl, folderId).forEach { entry ->
                val name = entry.optNonBlankString("name") ?: return@forEach
                val id = entry.optNonBlankString("id") ?: entry.optNonBlankString("file_id") ?: cloudStableId(name)
                val link = entry.optNonBlankString("link").orEmpty()
                val type = entry.optNonBlankString("type").orEmpty()
                val isFolder = type.contains("folder", ignoreCase = true) || link.isBlank()

                if (isFolder) {
                    if (id.isNotBlank() && id !in visitedFolderIds && pendingFolders.size < 1_000) {
                        pendingFolders.add(id to name)
                    }
                    return@forEach
                }

                if (!isCloudAudioFile(name) || link.isBlank()) return@forEach
                files += CloudAudioFile(
                    id = id,
                    name = name,
                    path = entry.optNonBlankString("path") ?: folderName?.let { "$it/$name" } ?: name,
                    parentFolder = folderName,
                    link = link,
                    size = entry.optLong("size"),
                )
            }
        }

        return files
    }

    private suspend fun fetchPremiumizeFolder(baseUrl: String, folderId: String?): List<JsonObject> {
        val url = baseUrl.toHttpUrlOrNull()
            ?.newBuilder()
            ?.addPathSegments("folder/list")
            ?.apply {
                if (!folderId.isNullOrBlank()) addQueryParameter("id", folderId)
            }
            ?.build()
            ?.toString()
            ?: return emptyList()

        return fetchJsonObject(url)
            ?.get("content")
            ?.asArrayOrNull()
            ?.mapNotNull { it.asObjectOrNull() }
            .orEmpty()
    }

    private suspend fun fetchRealDebridTorrentAudioFiles(baseUrl: String): List<CloudAudioFile> {
        val torrentsUrl = buildProviderUrl(baseUrl, "torrents") ?: return emptyList()
        val torrents = fetchJsonArray(torrentsUrl)
        val files = mutableListOf<CloudAudioFile>()

        for (torrent in torrents.take(250)) {
            val torrentId = torrent.optNonBlankString("id") ?: continue
            val torrentName = torrent.optNonBlankString("filename") ?: torrentId
            val infoUrl = buildProviderUrl(baseUrl, "torrents", "info", torrentId) ?: continue
            val info = fetchJsonObject(infoUrl) ?: continue
            val selectedAudioFiles = info["files"]
                ?.asArrayOrNull()
                ?.mapNotNull { it.asObjectOrNull() }
                ?.filter { it.optInt("selected") == 1 }
                ?.filter { file -> isCloudAudioFile(file.optNonBlankString("path")?.substringAfterLast('/') ?: "") }
                .orEmpty()
            if (selectedAudioFiles.isEmpty()) continue

            val directLinks = mutableMapOf<String, String>()
            info["links"]
                ?.asArrayOrNull()
                ?.mapNotNull { it.jsonPrimitive.contentOrNull }
                .orEmpty()
                .forEach { restrictedLink ->
                    val unrestricted = unrestrictRealDebridLink(baseUrl, restrictedLink) ?: return@forEach
                    val filename = unrestricted.optNonBlankString("filename") ?: return@forEach
                    val download = unrestricted.optNonBlankString("download") ?: return@forEach
                    if (isCloudAudioFile(filename)) {
                        directLinks[filename.lowercase()] = download
                    }
                }

            selectedAudioFiles.forEach { file ->
                val path = file.optNonBlankString("path") ?: return@forEach
                val name = path.substringAfterLast('/')
                val link = directLinks[name.lowercase()] ?: return@forEach
                files += CloudAudioFile(
                    id = "rd-$torrentId-${file.optInt("id") ?: cloudStableId(path)}",
                    name = name,
                    path = "/torrents/$torrentId/$path",
                    parentFolder = groupingFolderName(path) ?: torrentName,
                    link = link,
                    size = file.optLong("bytes"),
                )
            }
        }

        return files
    }

    private suspend fun fetchRealDebridDownloadAudioFiles(baseUrl: String): List<CloudAudioFile> {
        val downloadsUrl = buildProviderUrl(baseUrl, "downloads") ?: return emptyList()
        return fetchJsonArray(downloadsUrl)
            .mapNotNull { item ->
                val name = item.optNonBlankString("filename") ?: return@mapNotNull null
                val link = item.optNonBlankString("download") ?: return@mapNotNull null
                if (!isCloudAudioFile(name) || link.isBlank()) return@mapNotNull null
                CloudAudioFile(
                    id = "rd-dl-${item.optNonBlankString("id") ?: cloudStableId(link)}",
                    name = name,
                    path = "/downloads/$name",
                    parentFolder = null,
                    link = link,
                    size = item.optLong("filesize") ?: item.optLong("bytes"),
                )
            }
    }

    private suspend fun unrestrictRealDebridLink(baseUrl: String, restrictedLink: String): JsonObject? {
        val url = buildProviderUrl(baseUrl, "unrestrict", "link") ?: return null
        return runSuspendCatching {
            val response = api.postFormRawUrl(url, restrictedLink)
            if (!response.isSuccessful) return@runSuspendCatching null
            response.body()?.string()?.takeIf { it.isNotBlank() }?.let {
                jsonSerializer.parseToJsonElement(it).asObjectOrNull()
            }
        }.getOrNull()
    }

    private suspend fun fetchJsonObject(url: String): JsonObject? = runSuspendCatching {
        val response = api.fetchRawUrl(url)
        if (!response.isSuccessful) return@runSuspendCatching null
        response.body()?.string()?.takeIf { it.isNotBlank() }?.let {
            jsonSerializer.parseToJsonElement(it).asObjectOrNull()
        }
    }.getOrNull()

    private suspend fun fetchJsonArray(url: String): List<JsonObject> = runSuspendCatching {
        val response = api.fetchRawUrl(url)
        if (!response.isSuccessful) return@runSuspendCatching emptyList()
        response.body()?.string()?.takeIf { it.isNotBlank() }
            ?.let { jsonSerializer.parseToJsonElement(it).asArrayOrNull() }
            ?.mapNotNull { it.asObjectOrNull() }
            .orEmpty()
    }.getOrDefault(emptyList())

    private fun normalizedPremiumizeBase(serverUrl: String): String =
        serverUrl.ifBlank { "https://www.premiumize.me/api" }.trimEnd('/')

    private fun normalizedRealDebridBase(serverUrl: String): String =
        serverUrl.ifBlank { "https://api.real-debrid.com/rest/1.0" }.trimEnd('/')

    private fun groupingFolderName(path: String): String? {
        val trimmed = path.trim('/').substringBeforeLast('/', missingDelimiterValue = "")
        return trimmed.substringAfterLast('/').takeIf { it.isNotBlank() }
    }

}

private fun grimmoryBookType(fileType: String?): String = when (fileType?.lowercase()?.removePrefix(".")) {
    "pdf" -> "PDF"
    "cbz", "cbr", "cb7", "cbt", "cbx", "comic" -> "CBX"
    "fb2" -> "FB2"
    "mobi" -> "MOBI"
    "azw", "azw3", "kfx" -> "AZW3"
    else -> "EPUB"
}

internal suspend fun mediaBrowserPages(fetch: suspend (Int) -> MediaBrowserItemsDto): List<MediaBrowserItemDto> = buildList {
    do {
        val page = fetch(size)
        addAll(page.items)
        check(page.items.isNotEmpty() || size >= page.totalRecordCount) { "Incomplete media library page" }
    } while (size < page.totalRecordCount)
}
