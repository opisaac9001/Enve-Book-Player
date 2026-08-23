package com.enve.app.data.repository

import android.content.Context
import android.util.Log
import com.enve.core.data.model.*
import com.enve.core.data.model.BookSource
import com.enve.komga.KomgaRepository
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.repository.grimmory.*
import com.enve.app.data.remote.dto.*
import com.enve.app.data.remote.dto.grimmoryapp.LanguageOptionDto
import com.enve.app.data.remote.dto.grimmoryapp.NamedCountDto
import com.enve.core.data.util.*
import com.enve.core.data.remote.dto.AuthResponse
import com.enve.core.data.remote.dto.AuthorSummaryDto
import com.enve.core.data.remote.dto.LoginRequest
import com.enve.core.data.remote.dto.RefreshRequest
import com.enve.core.data.remote.dto.SeriesSummaryDto
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.importing.AudiobookFileGrouping
import com.enve.core.auth.CredentialVault
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import com.enve.core.data.sync.CfiLocatorConverter
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
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.net.URLDecoder
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.net.URI
import java.util.concurrent.TimeUnit
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

internal fun Request.Builder.applyGrimmoryOidcHeaders(
    headers: Map<String, String>,
): Request.Builder = apply {
    headers.forEach { (key, value) -> header(key, value) }
}

internal fun grimmoryOidcScopes(configuredScopes: String?): String =
    configuredScopes?.takeIf { it.isNotBlank() } ?: "openid profile email groups"

internal fun grimmoryOidcUsername(responseBody: String): String? =
    Json.parseToJsonElement(responseBody)
        .jsonObject["username"]
        ?.jsonPrimitive
        ?.contentOrNull

internal fun grimmoryEbookFileProgress(
    bookFileId: Long,
    totalProgression: Float,
    checkpointValue: String?,
): GrimmoryFileProgressDto {
    val rawValue = checkpointValue?.trim()
    val checkpoint = EpubBridgeCheckpointCodec.decode(rawValue)
    val foliateCheckpoint = checkpoint?.takeIf { it.sourceEngine == ReaderEngineKind.FOLIATE }
    val canonicalCfi = foliateCheckpoint?.epubCfi
        ?.trim()
        ?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
    val contentSourceProgressPercent = foliateCheckpoint
        ?.takeIf { canonicalCfi != null }
        ?.resourceProgression
        ?.takeIf { it.isFinite() }
        ?.coerceIn(0.0, 1.0)
        ?.times(100.0)

    return GrimmoryFileProgressDto(
        bookFileId = bookFileId,
        positionData = canonicalCfi,
        positionHref = canonicalCfi?.let {
            foliateCheckpoint.href?.trim()?.takeIf(String::isNotBlank)
        },
        progressPercent = (totalProgression.toDouble() * 100.0).coerceIn(0.0, 100.0),
        ttsPositionCfi = null,
        contentSourceProgressPercent = contentSourceProgressPercent,
    )
}

@Singleton
class GrimmoryRepository @Inject constructor(
    private val api: GrimmoryApi,
    private val komgaRepository: KomgaRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: com.enve.core.data.local.ConnectionRegistry,
    @ApplicationContext private val context: Context,
) {

    private data class ScopedContext(
        val source: BookSource,
        val serverUrl: String,
        val token: String,
        val connectionId: String?,
        val username: String,
        val cloudRootPaths: List<String> = emptyList(),
    )
    private data class CloudAudioFile(
        val id: String,
        val name: String,
        val path: String,
        val parentFolder: String?,
        val link: String,
        val size: Long?,
        val coverUrl: String? = null,
    )
    private data class CloudCoverFile(
        val path: String,
        val parentFolder: String,
        val link: String,
        val rank: Int,
    )

    private data class CloudBookGroup(
        val key: String,
        val title: String,
        val folderPath: String?,
        val files: List<CloudAudioFile>,
        val coverUrl: String? = null,
    )
    private data class CloudTitleAuthor(
        val title: String,
        val author: String?,
    )

    private fun resolveScopedContext(): ScopedContext {
        connectionRegistry.getScopedConnectionSync()?.let { connection ->
            val token = vault.get(CredentialVault.accessTokenKey(connection.id))
                ?: vault.get(CredentialVault.passwordKey(connection.id))
                ?: prefs.getAccessTokenSync()
                ?: ""
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
        return ScopedContext(
            source = activeConnection?.source ?: prefs.getActiveBookSourceSync(),
            serverUrl = activeConnection?.serverUrl ?: prefs.getServerUrlSync() ?: "",
            token = prefs.getAccessTokenSync() ?: "",
            connectionId = activeConnectionId,
            username = activeConnection?.username ?: prefs.getUsernameSync().orEmpty(),
            cloudRootPaths = activeConnection?.cloudRootPaths.orEmpty(),
        )
    }

    private val audiobookTitleOverrideCache = mutableMapOf<String, String>()

    private val audiobookDurationOverrideCache = mutableMapOf<String, Long>()

    private val detailedBookCache = androidx.collection.LruCache<String, Book>(200)

    private val audiobookInfoCache = androidx.collection.LruCache<String, AudiobookInfoDto>(200)
    private var skipPersistentBookCacheNextFetch = false

    private val backgroundScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private data class CacheEntry<T>(val data: T, val timestamp: Long = System.currentTimeMillis())
    private val cacheTtlMs = 5 * 60 * 1000L
    private val BOOK_INDEX_MAX_AGE_MS = 30 * 60 * 1000L

    private val jsonSerializer = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }
    private val torBoxWebDavClient: OkHttpClient by lazy {
        OkHttpClient.Builder().build()
    }

    @Serializable
    private data class BookIndexCachePayload(
        val source: String,
        val serverUrl: String,
        val savedAt: Long,
        val libraryId: String? = null,
        val summaries: List<BookSummaryDto> = emptyList(),

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

    private var booksCache: CacheEntry<Pair<String?, List<Book>>>? = null
    private var librariesCache: CacheEntry<List<Library>>? = null
    private var continueListeningCache: CacheEntry<List<Book>>? = null
    private var continueReadingCache: CacheEntry<List<Book>>? = null
    private var recentlyAddedCache: CacheEntry<List<Book>>? = null

    private var cacheSource: String? = null

    private val booksFetchMutexes = mutableMapOf<String, Mutex>()
    private fun mutexForBooksKey(key: String): Mutex = synchronized(booksFetchMutexes) {
        booksFetchMutexes.getOrPut(key) { Mutex() }
    }

    private fun <T> CacheEntry<T>.isValid() =
        (System.currentTimeMillis() - this.timestamp) < cacheTtlMs

    fun invalidateListCaches() {
        booksCache = null
        librariesCache = null
        continueListeningCache = null
        continueReadingCache = null
        recentlyAddedCache = null
        cacheSource = null
        clearTorBoxBookIndexCache()

        skipPersistentBookCacheNextFetch = true
    }

    private fun cacheFileForBooks(source: BookSource, serverUrl: String, libraryId: String?): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val safeLibrary = (libraryId ?: "all").replace(Regex("[^a-zA-Z0-9._-]"), "_")
        val name = "books_${source.name.lowercase()}_${safeServer}_${safeLibrary}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForLibraries(source: BookSource, serverUrl: String): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "libraries_${source.name.lowercase()}_${safeServer}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForHomeLane(source: BookSource, serverUrl: String, lane: String): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val safeLane = lane.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "lane_${source.name.lowercase()}_${safeServer}_${safeLane}.json"
        return java.io.File(cacheDir, name)
    }

    private fun clearTorBoxBookIndexCache() {
        runCatching {
            java.io.File(context.cacheDir, "book-index-cache")
                .listFiles { file -> file.name.startsWith("books_torbox_") }
                ?.forEach { it.delete() }
        }
    }

    private suspend fun loadBooksIndexFromDisk(
        source: BookSource,
        serverUrl: String,
        libraryId: String?,
    ): List<BookSummaryDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForBooks(source, serverUrl, libraryId)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<BookIndexCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.libraryId != libraryId) {
                return@runCatching null
            }

            if (System.currentTimeMillis() - payload.savedAt > BOOK_INDEX_MAX_AGE_MS) {
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
    ): List<Book>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForBooks(source, serverUrl, libraryId)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<GenericBookCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.libraryId != libraryId) {
                return@runCatching null
            }

            if (System.currentTimeMillis() - payload.savedAt > 3600_000) return@runCatching null
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
    ): List<LibraryDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForLibraries(source, serverUrl)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<LibrariesCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl) return@runCatching null
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
    ): List<BookSummaryDto>? = withContext(Dispatchers.IO) {
        runCatching {
            val file = cacheFileForHomeLane(source, serverUrl, lane)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<HomeLaneCachePayload>(file.readText())
            if (payload.source != source.name || payload.serverUrl != serverUrl || payload.lane != lane) return@runCatching null
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
                summaries = summaries,
            )
            cacheFileForHomeLane(source, serverUrl, lane).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun ensureCacheSource() {
        val ctx = resolveScopedContext()

        val key = "${ctx.source.name}::${ctx.serverUrl}"
        if (cacheSource != key) {
            booksCache = null
            librariesCache = null
            continueListeningCache = null
            continueReadingCache = null
            recentlyAddedCache = null
            cacheSource = key
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
        ensureCacheSource()
        librariesCache?.takeIf { it.isValid() }?.let { return Result.success(it.data) }
        return try {
            val ctx = resolveScopedContext()
            val source = ctx.source
            val serverUrl = ctx.serverUrl
            if (source.requiresConfiguredServer && serverUrl.isBlank()) {
                return Result.success(emptyList())
            }

            if (source == BookSource.GRIMMORY && !skipPersistentBookCacheNextFetch) {
                val cached = loadLibrariesFromDisk(source, serverUrl)
                if (!cached.isNullOrEmpty()) {
                    val mapped = cached.map { it.toLibrary() }
                    librariesCache = CacheEntry(mapped)
                    return Result.success(mapped)
                }
            }

            val libs = when (source) {
                BookSource.GRIMMORY -> {
                    val response = api.getLibraries()
                    val appLibraries = response.body()
                    val dto: List<LibraryDto> = if (
                        shouldUseLegacyGrimmoryCatalog(response.code(), appLibraries?.size)
                    ) {
                        android.util.Log.i(
                            "GrimmoryRepository",
                            "/app/libraries HTTP ${response.code()} with ${appLibraries?.size ?: 0} libraries; falling back to legacy /api/v1/libraries",
                        )
                        val legacy = api.getLibrariesLegacy()
                        if (!legacy.isSuccessful) {
                            return Result.failure(Exception("Failed to fetch libraries (legacy HTTP ${legacy.code()})"))
                        }
                        legacy.body().orEmpty()
                    } else {
                        appLibraries.orEmpty()
                    }
                    saveLibrariesToDisk(source, serverUrl, dto)
                    dto.map { it.toLibrary() }
                }

                BookSource.JELLYFIN -> fetchJellyfinLibraries()
                BookSource.EMBY -> fetchEmbyLibraries()
                BookSource.KAVITA -> fetchKavitaLibraries()
                BookSource.OPDS -> listOf(Library(id = "opds-root", name = "OPDS Catalog", bookCount = 0))
                BookSource.WEBDAV -> listOf(Library(id = "webdav-root", name = "WebDAV Root", bookCount = 0))
                BookSource.TORBOX -> fetchTorBoxRootLibraries(ctx)
                BookSource.PREMIUMIZE -> listOf(Library(id = "premiumize-cloud", name = "Premiumize Cloud", bookCount = 0, source = BookSource.PREMIUMIZE))
                BookSource.REALDEBRID -> listOf(Library(id = "realdebrid-downloads", name = "Real-Debrid Downloads", bookCount = 0, source = BookSource.REALDEBRID))
                BookSource.SMB -> listOf(Library(id = "smb-root", name = "SMB Share", bookCount = 0))
                BookSource.LOCAL -> listOf(Library(id = "local-root", name = "Local Files", bookCount = 0))
                else -> emptyList()
            }
            skipPersistentBookCacheNextFetch = false
            librariesCache = CacheEntry(libs)
            Result.success(libs)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            skipPersistentBookCacheNextFetch = false
            val ctx = resolveScopedContext()
            val source = ctx.source
            if (source == BookSource.GRIMMORY) {
                val serverUrl = ctx.serverUrl
                val cached = loadLibrariesFromDisk(source, serverUrl)
                if (!cached.isNullOrEmpty()) {
                    val mapped = cached.map { it.toLibrary() }
                    librariesCache = CacheEntry(mapped)
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
        ensureCacheSource()
        booksCache?.takeIf { it.isValid() && it.data.first == libraryId }?.let { return Result.success(it.data.second) }
        val ctx = resolveScopedContext()
        val coalesceKey = "${ctx.source.name}|${ctx.serverUrl}|${libraryId ?: ""}"
        return mutexForBooksKey(coalesceKey).withLock {
            booksCache?.takeIf { it.isValid() && it.data.first == libraryId }?.let { return@withLock Result.success(it.data.second) }
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

            if (source == BookSource.GRIMMORY && !skipPersistentBookCacheNextFetch) {
                val cachedSummaries = loadBooksIndexFromDisk(source, serverUrl, libraryId)
                if (!cachedSummaries.isNullOrEmpty()) {
                    val cachedMapped = appendCompanionAudiobooks(cachedSummaries.map { it.toBook(serverUrl, token) }, serverUrl, token)
                    val withOverrides = applyCachedTitleOverrides(cachedMapped)
                    booksCache = CacheEntry(Pair(libraryId, withOverrides))
                    resolveAmbiguousAudiobookTitlesInBackground(
                        books = cachedMapped,
                        source = source,
                        serverUrl = serverUrl,
                        libraryId = libraryId,
                        cachedSummaries = cachedSummaries,
                    )
                    return Result.success(withOverrides)
                }
            } else if (source != BookSource.GRIMMORY && source != BookSource.TORBOX && !skipPersistentBookCacheNextFetch) {
                val cached = loadGenericBooksFromDisk(source, serverUrl, libraryId)
                if (!cached.isNullOrEmpty()) {
                    booksCache = CacheEntry(Pair(libraryId, cached))
                    return Result.success(cached)
                }
            }

            val resolved = when (source) {
                BookSource.GRIMMORY -> {
                    val summaries = fetchAllBooks(libraryId = libraryId, page = page, size = size, sort = sort, dir = dir)
                    val mapped = appendCompanionAudiobooks(summaries.map { it.toBook(serverUrl, token) }, serverUrl, token)

                    val resolvedTitles = resolveAmbiguousAudiobookTitles(mapped, api, audiobookTitleOverrideCache, audiobookDurationOverrideCache)
                    saveBooksIndexToDisk(source, serverUrl, libraryId, summaries)
                    resolvedTitles
                }

                BookSource.JELLYFIN -> fetchJellyfinBooks(libraryId = libraryId, serverUrl = serverUrl)
                BookSource.EMBY -> fetchEmbyBooks(libraryId = libraryId, serverUrl = serverUrl)
                BookSource.KAVITA -> fetchKavitaBooks(libraryId = libraryId, serverUrl = serverUrl)
                BookSource.OPDS -> fetchOpdsBooks(serverUrl = serverUrl)
                BookSource.WEBDAV -> fetchWebDavBooks(serverUrl = serverUrl)
                BookSource.TORBOX -> fetchTorBoxBooks(ctx, libraryId)
                BookSource.PREMIUMIZE -> fetchPremiumizeBooks(ctx)
                BookSource.REALDEBRID -> fetchRealDebridBooks(ctx)
                else -> emptyList()
            }

            if (source != BookSource.GRIMMORY && source != BookSource.TORBOX) {
                saveGenericBooksToDisk(source, serverUrl, libraryId, resolved)
            }

            skipPersistentBookCacheNextFetch = false
            booksCache = CacheEntry(Pair(libraryId, resolved))
            Result.success(resolved)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            skipPersistentBookCacheNextFetch = false
            if (ctx.source == BookSource.GRIMMORY) {
                val cachedSummaries = loadBooksIndexFromDisk(ctx.source, ctx.serverUrl, libraryId)
                if (!cachedSummaries.isNullOrEmpty()) {
                    val cachedMapped = appendCompanionAudiobooks(cachedSummaries.map { it.toBook(ctx.serverUrl, ctx.token) }, ctx.serverUrl, ctx.token)
                    val resolved = resolveAndEnrichAudiobooks(cachedMapped, ctx.serverUrl, ctx.token)
                    booksCache = CacheEntry(Pair(libraryId, resolved))
                    return Result.success(resolved)
                }
            }
            Result.failure(e)
        }
    }

    suspend fun getBookDetail(bookId: String, forceRefresh: Boolean = false): Result<Book> {
        return try {
            val ctx = resolveScopedContext()
            val source = ctx.source
            val rawBookId = if (source == BookSource.GRIMMORY) bookId.grimmoryServerBookId() else bookId
            if (!forceRefresh) {
                detailedBookCache.get(bookId)?.let { return Result.success(it) }
            }

            if (source != BookSource.GRIMMORY) {
                val fromList = getBooks().getOrNull()?.firstOrNull { it.id == bookId }
                if (fromList != null) {
                    detailedBookCache.put(bookId, fromList)
                    return Result.success(fromList)
                }
                return Result.failure(Exception("Book not found for ${source.displayName}"))
            }

            val response = api.getBookDetail(rawBookId)
            if (response.isSuccessful) {
                val serverUrl = ctx.serverUrl
                val token = ctx.token
                val detail = response.body()!!
                val mapped = detail.toBook(serverUrl, token)
                val book = if (rawBookId != bookId || mapped.mediaType == AppMediaType.AUDIOBOOK) {
                    val base = if (rawBookId != bookId) mapped.companionAudiobook(serverUrl, token) ?: mapped else mapped
                    mergeListedAudiobook(base, detail, api.getAudiobookInfo(rawBookId).body(), serverUrl, token)
                } else {
                    mergeListedEbook(mapped, detail, serverUrl, token)
                }
                detailedBookCache.put(bookId, book)
                Result.success(book)
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
            detailedBookCache.get(book.id) ?: book
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
                .filter { it.progress in 0.01f..0.98f || it.lastReadTime > 0L }
                .sortedByDescending { it.lastReadTime }
                .take(20)
                .toList()
            return Result.success(lane)
        }

        return try {
            val serverUrl = ctx.serverUrl
            val token = ctx.token

            val response = api.getContinueListening()
            if (response.isSuccessful) {
                val summaries = response.body().orEmpty()
                saveHomeLaneToDisk(source, serverUrl, "continue-listening", summaries)
                val books = summaries.map { it.toBook(serverUrl, token) }
                val resolved = resolveAndEnrichAudiobooks(books, serverUrl, token)
                val lane = resolved
                    .filter { it.mediaType == AppMediaType.AUDIOBOOK && it.isEligibleForGrimmoryContinue() }
                    .takeIf { it.isNotEmpty() }
                    ?: deriveContinueListeningFromLibrary()
                skipPersistentBookCacheNextFetch = false
                continueListeningCache = CacheEntry(lane)
                Result.success(lane)
            } else {
                val fallback = deriveContinueListeningFromLibrary()
                if (fallback.isNotEmpty()) {
                    skipPersistentBookCacheNextFetch = false
                    continueListeningCache = CacheEntry(fallback)
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
                ?.map { it.toBook(serverUrl, token) }
                .orEmpty()
            if (diskFallback.isNotEmpty()) {
                val resolved = resolveAndEnrichAudiobooks(diskFallback, serverUrl, token)
                continueListeningCache = CacheEntry(resolved)
                skipPersistentBookCacheNextFetch = false
                return Result.success(resolved.filter { it.mediaType == AppMediaType.AUDIOBOOK && it.isEligibleForGrimmoryContinue() })
            }
            val fallback = runSuspendCatching { deriveContinueListeningFromLibrary() }.getOrDefault(emptyList())
            if (fallback.isNotEmpty()) {
                skipPersistentBookCacheNextFetch = false
                continueListeningCache = CacheEntry(fallback)
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
                p in 0.01f..0.98f || it.currentTime > 0L || it.lastReadTime > 0L
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
                .filter { it.readProgress in 0.01f..0.98f }
                .sortedByDescending { it.lastReadTime }
                .take(20)
                .toList()
            return Result.success(lane)
        }

        return try {
            val serverUrl = ctx.serverUrl
            val token = ctx.token

            val response = api.getContinueReading()
            if (response.isSuccessful) {
                val summaries = response.body().orEmpty()
                saveHomeLaneToDisk(source, serverUrl, "continue-reading", summaries)
                val books = summaries.map { it.toBook(serverUrl, token) }
                val resolved = resolveAndEnrichAudiobooks(books, serverUrl, token)
                val lane = resolved
                    .filter { it.mediaType == AppMediaType.EBOOK && it.isEligibleForGrimmoryContinue() }
                    .takeIf { it.isNotEmpty() }
                    ?: deriveContinueReadingFromLibrary()
                skipPersistentBookCacheNextFetch = false
                continueReadingCache = CacheEntry(lane)
                Result.success(lane)
            } else {
                val fallback = deriveContinueReadingFromLibrary()
                if (fallback.isNotEmpty()) {
                    skipPersistentBookCacheNextFetch = false
                    continueReadingCache = CacheEntry(fallback)
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
                ?.map { it.toBook(serverUrl, token) }
                .orEmpty()
            if (diskFallback.isNotEmpty()) {
                val resolved = resolveAndEnrichAudiobooks(diskFallback, serverUrl, token)
                continueReadingCache = CacheEntry(resolved)
                skipPersistentBookCacheNextFetch = false
                return Result.success(resolved.filter { it.mediaType == AppMediaType.EBOOK && it.isEligibleForGrimmoryContinue() })
            }
            val fallback = runSuspendCatching { deriveContinueReadingFromLibrary() }.getOrDefault(emptyList())
            if (fallback.isNotEmpty()) {
                skipPersistentBookCacheNextFetch = false
                continueReadingCache = CacheEntry(fallback)
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
            .filter { (it.epubProgress ?: it.readProgress) in 0.01f..0.98f }
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

        recentlyAddedCache?.takeIf { it.isValid() }?.let { return Result.success(it.data) }
        return try {
            val serverUrl = ctx.serverUrl
            val token = ctx.token

            if (!skipPersistentBookCacheNextFetch) {
                val cachedSummaries = loadHomeLaneFromDisk(source, serverUrl, "recently-added")
                if (!cachedSummaries.isNullOrEmpty()) {
                    val cached = resolveAndEnrichAudiobooks(cachedSummaries.map { it.toBook(serverUrl, token) }, serverUrl, token)
                    recentlyAddedCache = CacheEntry(cached)
                    return Result.success(cached)
                }
            }

            val response = api.getRecentlyAdded()
            if (response.isSuccessful) {
                val summaries = response.body().orEmpty()
                saveHomeLaneToDisk(source, serverUrl, "recently-added", summaries)
                val books = summaries.map { it.toBook(serverUrl, token) }
                val resolved = resolveAndEnrichAudiobooks(books, serverUrl, token)
                val lane = resolved.takeIf { it.isNotEmpty() } ?: deriveRecentlyAddedFromLibrary()
                skipPersistentBookCacheNextFetch = false
                recentlyAddedCache = CacheEntry(lane)
                Result.success(lane)
            } else {
                val fallback = deriveRecentlyAddedFromLibrary()
                if (fallback.isNotEmpty()) {
                    skipPersistentBookCacheNextFetch = false
                    recentlyAddedCache = CacheEntry(fallback)
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
                ?.map { it.toBook(serverUrl, token) }
                .orEmpty()
            if (diskFallback.isNotEmpty()) {
                val resolved = resolveAndEnrichAudiobooks(diskFallback, serverUrl, token)
                recentlyAddedCache = CacheEntry(resolved)
                skipPersistentBookCacheNextFetch = false
                return Result.success(resolved)
            }
            val fallback = runSuspendCatching { deriveRecentlyAddedFromLibrary() }.getOrDefault(emptyList())
            if (fallback.isNotEmpty()) {
                skipPersistentBookCacheNextFetch = false
                recentlyAddedCache = CacheEntry(fallback)
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

    suspend fun searchBooks(query: String): Result<List<Book>> {
        return try {
            val response = api.searchBooks(query)
            if (response.isSuccessful) {
                val ctx = resolveScopedContext()
                val books = response.body()?.content.orEmpty().map { it.toBook(ctx.serverUrl, ctx.token) }
                Result.success(resolveAmbiguousAudiobookTitles(books, api, audiobookTitleOverrideCache))
            } else {
                Result.failure(Exception("Search failed"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getRecentlyScanned(): Result<List<Book>> {
        return try {
            val response = api.getRecentlyScanned()
            if (response.isSuccessful) {
                val ctx = resolveScopedContext()
                val books = response.body().orEmpty().map { it.toBook(ctx.serverUrl, ctx.token) }
                Result.success(resolveAmbiguousAudiobookTitles(books, api, audiobookTitleOverrideCache))
            } else {
                Result.failure(Exception("Failed to fetch recently scanned"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getRandomBooks(libraryId: String? = null): Result<List<Book>> {
        return try {
            val response = api.getRandomBooks(libraryId = libraryId)
            if (response.isSuccessful) {
                val ctx = resolveScopedContext()
                val books = response.body()?.content.orEmpty().map { it.toBook(ctx.serverUrl, ctx.token) }
                Result.success(resolveAmbiguousAudiobookTitles(books, api, audiobookTitleOverrideCache))
            } else {
                Result.failure(Exception("Failed to fetch random books"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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

    suspend fun getFilters(): Result<FilterOptionsDto> {
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) {
                val books = getBooks(size = 500).getOrDefault(emptyList())
                fun counted(values: List<String>): List<NamedCountDto> = values
                    .groupingBy { it }.eachCount()
                    .map { (name, count) -> NamedCountDto(name, count) }
                    .sortedBy { it.name.lowercase() }
                val filters = FilterOptionsDto(
                    authors = counted(books.mapNotNull { it.author }),
                    narrators = counted(books.mapNotNull { it.narrator }),
                    languages = counted(books.mapNotNull { it.language }).map { LanguageOptionDto(it.name, it.name, it.count) },
                    categories = counted(books.flatMap { it.categories }),
                    fileTypes = counted(books.mapNotNull { it.primaryFileType }),
                    publishers = counted(books.mapNotNull { it.publisher }),
                )
                return Result.success(filters)
            }

            val response = api.getFilters()
            if (response.isSuccessful) Result.success(response.body()!!)
            else Result.failure(Exception("Failed to fetch filters"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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

            val ctx = resolveScopedContext()

            val withCovers = fetchAllSeries().map { dto ->
                val coverBookId = dto.bookIds?.firstOrNull()
                if (coverBookId != null) {
                    dto.copy(coverUrl = "${ctx.serverUrl.trimEnd('/')}/api/v1/media/book/$coverBookId/cover")
                } else {
                    dto
                }
            }
            Result.success(withCovers)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private suspend fun fetchAllSeries(): List<SeriesSummaryDto> = coroutineScope {

        val pageSize = 500
        val first = api.getSeries(page = 0, size = pageSize)
        if (!first.isSuccessful) error("getSeries HTTP ${first.code()}")
        val firstBody = first.body() ?: return@coroutineScope emptyList()
        val totalPages = firstBody.totalPages ?: 1
        if (totalPages <= 1 || firstBody.content.isEmpty()) return@coroutineScope firstBody.content.map { it.toCore() }

        val semaphore = Semaphore(8)
        val rest = (1 until totalPages).map { p ->
            async {
                semaphore.withPermit {
                    api.getSeries(page = p, size = pageSize).body()?.content.orEmpty().map { it.toCore() }
                }
            }
        }.awaitAll().flatten()
        firstBody.content.map { it.toCore() } + rest
    }

    private fun com.enve.app.data.remote.dto.SeriesSummaryDto.toCore() =
        SeriesSummaryDto(name = name, bookCount = bookCount, bookIds = bookIds, id = id, coverUrl = coverUrl)

    private fun com.enve.app.data.remote.dto.AuthorSummaryDto.toCore() =
        AuthorSummaryDto(id = id.orEmpty(), name = name, photoUrl = photoUrl, bookCount = bookCount)

    suspend fun getSeriesBooks(seriesName: String): Result<List<Book>> {
        return try {
            val ctx = resolveScopedContext()
            if (ctx.source != BookSource.GRIMMORY) {
                val books = getBooks(size = 500).getOrDefault(emptyList())
                val seriesBooks = books.filter { it.seriesName?.equals(seriesName, ignoreCase = true) == true }
                return Result.success(seriesBooks)
            }

            val response = api.getSeriesBooks(seriesName)
            if (response.isSuccessful) {
                val books = response.body()?.content.orEmpty().map { it.toBook(ctx.serverUrl, ctx.token) }
                Result.success(resolveAmbiguousAudiobookTitles(books, api, audiobookTitleOverrideCache))
            } else {
                Result.failure(Exception("Failed to fetch series books"))
            }
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> {
        return try {
            val response = api.updateBookStatus(bookId.grimmoryServerBookId(), UpdateStatusRequest(status))
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
            else Result.failure(Exception("Failed to update book rating"))
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
        val pageSize = 500
        val first = api.getAuthors(page = 0, size = pageSize, search = search)
        if (!first.isSuccessful) error("getAuthors HTTP ${first.code()}")
        val firstBody = first.body() ?: return@coroutineScope emptyList()
        val totalPages = firstBody.totalPages ?: 1
        if (totalPages <= 1 || firstBody.content.isEmpty()) return@coroutineScope firstBody.content.map { it.toCore() }

        val semaphore = Semaphore(8)
        val rest = (1 until totalPages).map { p ->
            async {
                semaphore.withPermit {
                    api.getAuthors(page = p, size = pageSize, search = search).body()?.content.orEmpty().map { it.toCore() }
                }
            }
        }.awaitAll().flatten()
        firstBody.content.map { it.toCore() } + rest
    }

    suspend fun getAuthorDetail(authorId: String): Result<AuthorDetailDto> {
        return try {
            val response = api.getAuthorDetail(authorId)
            if (response.isSuccessful) Result.success(response.body()!!)
            else Result.failure(Exception("Failed to fetch author detail"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getMagicShelves(): Result<List<MagicShelfDto>> {
        return try {
            val response = api.getMagicShelves()
            if (response.isSuccessful) Result.success(response.body().orEmpty())
            else Result.failure(Exception("Failed to fetch magic shelves"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getNotebookBooks(): Result<List<NotebookBookSummaryDto>> {
        return try {
            val response = api.getNotebookBooks()
            if (response.isSuccessful) Result.success(response.body()?.content.orEmpty())
            else Result.failure(Exception("Failed to fetch notebook books"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getNotebookEntries(bookId: String): Result<List<NotebookEntryDto>> {
        return try {
            val response = api.getNotebookEntries(bookId)
            if (response.isSuccessful) Result.success(response.body()?.content.orEmpty())
            else Result.failure(Exception("Failed to fetch notebook entries"))
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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

    private suspend fun resolveAudiobookInfo(bookId: String): AudiobookInfoDto? =
        audiobookInfoCache.get(bookId)
            ?: getAudiobookInfo(bookId).getOrNull()?.also { audiobookInfoCache.put(bookId, it) }

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

            else -> "${ctx.serverUrl}/api/v1/books/${bookId.grimmoryServerBookId()}/content?bookType=EPUB"
        }
    }

    suspend fun getEbookResource(bookId: String): ProviderEbookResource {
        val ctx = resolveScopedContext()
        if (ctx.source != BookSource.GRIMMORY) {
            return ProviderEbookResource(getEbookDownloadUrl(bookId))
        }
        val rawBookId = bookId.grimmoryServerBookId()
        val detail = api.getBookDetail(rawBookId).body()
        val epubFile = detail?.epubFile()
        return ProviderEbookResource(

            url = "${ctx.serverUrl}/api/v1/books/$rawBookId/content?bookType=EPUB",
            providerFileId = epubFile?.id,
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
                val legacyResponse = api.getLegacyShelves()
                if (legacyResponse.isSuccessful) {
                    val shelves = legacyResponse.body()?.map { Shelf(it.id, it.name, it.bookCount ?: 0) } ?: emptyList()
                    Result.success(shelves)
                } else {
                    Result.failure(Exception("Failed to fetch shelves"))
                }
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
                val books = response.body().orEmpty().map { it.toBookSummaryDto(fallbackLibraryId = null).toBook(ctx.serverUrl, ctx.token) }
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

    suspend fun fetchAudiobookProgress(book: com.enve.core.data.model.Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        return try {
            val response = api.getAppBookProgress(book.id.grimmoryServerBookId())
            val body = response.body() ?: return Result.success(null)
            val finished = body.readStatus.equals("READ", ignoreCase = true)
            val rawPct = body.audiobookProgress?.percentage?.let { normalizeFraction(it) }
                ?: body.readProgress?.let { normalizeFraction(it) }
            val pct = rawPct ?: if (finished) 1f else return Result.success(null)
            if (pct <= 0f && !finished) return Result.success(null)
            val ab = body.audiobookProgress

            val trackStarts = if ((ab?.trackIndex ?: 0) > 0) {
                resolveAudiobookInfo(book.id)?.trackStartsByIndex()
            } else null
            val positionMs = grimmoryGlobalAudiobookPositionMs(ab, trackStarts)
            Result.success(
                com.enve.core.data.sync.SyncSnapshot(
                    percentage = if (finished) maxOf(pct, 1f) else pct,
                    positionMs = positionMs,
                    source = "Grimmory",
                    updatedAt = parseIsoToEpochMs(body.audiobookProgress?.updatedAt),
                    finished = finished,
                )
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchEbookProgress(book: com.enve.core.data.model.Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        return try {
            val rawBookId = book.id.grimmoryServerBookId()
            val response = api.getAppBookProgress(rawBookId)
            if (!response.isSuccessful) {
                error("Grimmory ebook progress failed: HTTP ${response.code()}")
            }
            val body = response.body()
                ?: error("Grimmory ebook progress returned an empty response.")
            val finished = body.readStatus.equals("READ", ignoreCase = true)
            val epubProgress = body.epubProgress
            val rawPct = epubProgress?.percentage?.let { normalizeFraction(it) }
                ?: body.koreaderProgress?.percentage?.coerceIn(0f, 1f)
                ?: body.readProgress?.let { normalizeFraction(it) }
            val pct = rawPct ?: if (finished) 1f else return Result.success(null)
            if (pct <= 0f && !finished) return Result.success(null)
            val exactCfi = epubProgress?.cfi
                ?.trim()
                ?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
            Result.success(
                com.enve.core.data.sync.SyncSnapshot(
                    percentage = if (finished) maxOf(pct, 1f) else pct,
                    epubCfi = exactCfi,
                    href = exactCfi?.let {
                        epubProgress.href?.trim()?.takeIf(String::isNotBlank)
                    },
                    source = "Grimmory",
                    updatedAt = parseIsoToEpochMs(epubProgress?.updatedAt),
                    finished = finished,
                )
            )
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

            val response = api.postBookProgress(
                GrimmoryProgressRequest(
                    bookId = numericBookId,
                    fileProgress = GrimmoryProgressFileProgress(
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
    ): Result<Unit> {
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
            val response = api.createReadingSession(
                ReadingSessionRequest(
                    bookId = numericBookId,
                    bookType = if (mediaType == AppMediaType.AUDIOBOOK) "AUDIOBOOK" else "EPUB",
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
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Reading session create failed: HTTP ${response.code()}"))
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
        return try {
            val source = resolveScopedContext().source
            if (source != BookSource.GRIMMORY) return Result.success(emptyList())
            val response = api.getReadingSessionsForBook(bookId = bookId.grimmoryServerBookId(), page = page, size = size)
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

    suspend fun syncEbookProgress(bookId: String, percentage: Float, cfi: String?): Result<Unit> {
        return try {
            val source = resolveScopedContext().source
            when (source) {
                BookSource.GRIMMORY -> {
                    val rawBookId = bookId.grimmoryServerBookId()
                    rawBookId.toLongOrNull()
                        ?: return Result.failure(Exception("Grimmory book id is not numeric: $bookId"))
                    val detail = api.getBookDetail(rawBookId).body()
                        ?: return Result.failure(Exception("Grimmory book detail was unavailable: $bookId"))
                    val bookFileId = detail.epubFile()?.id?.toLongOrNull()
                        ?: return Result.failure(Exception("Grimmory EPUB file id was unavailable: $bookId"))
                    val response = api.putAppBookProgress(
                        bookId = rawBookId,
                        request = GrimmoryUpdateProgressRequest(
                            fileProgress = grimmoryEbookFileProgress(
                                bookFileId = bookFileId,
                                totalProgression = percentage,
                                checkpointValue = cfi,
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

    private fun BookDetailDto.epubFile(): BookFileDto? {
        val candidates = buildList {
            primaryFile?.let(::add)
            addAll(files.orEmpty())
        }.distinctBy { it.id }
        return candidates.firstOrNull { file ->
            file.bookType.equals("EPUB", ignoreCase = true) ||
                file.fileExtension.equals("EPUB", ignoreCase = true) ||
                file.fileName?.endsWith(".epub", ignoreCase = true) == true
        }
    }

    private suspend fun fetchAllBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): List<BookSummaryDto> = coroutineScope {

        val effectiveSize = size.coerceAtMost(500).coerceAtLeast(1)
        val firstResponse = api.getBooks(libraryId = libraryId, page = page, size = effectiveSize, sort = sort, dir = dir)
        val firstPage = firstResponse.body()
        if (
            page > 0 ||
            !shouldUseLegacyGrimmoryCatalog(firstResponse.code(), firstPage?.content?.size)
        ) {
            if (firstPage == null) {
                throw Exception("Failed to decode Grimmory books response")
            }
            val totalPages = firstPage.totalPages ?: 1
            val serverPageSize = firstPage.size?.takeIf { it > 0 } ?: effectiveSize
            if (totalPages <= page + 1 || firstPage.content.isEmpty()) {
                return@coroutineScope firstPage.content
            }

            val semaphore = Semaphore(8)
            val rest = ((page + 1) until totalPages).map { p ->
                async {
                    semaphore.withPermit {
                        val resp = api.getBooks(libraryId = libraryId, page = p, size = serverPageSize, sort = sort, dir = dir)
                        resp.body()?.content.orEmpty()
                    }
                }
            }.awaitAll().flatten()

            return@coroutineScope firstPage.content + rest
        }

        android.util.Log.i(
            "GrimmoryRepository",
            "/app/books HTTP ${firstResponse.code()} with ${firstPage?.content?.size ?: 0} books for lib=$libraryId; falling back to legacy /libraries/{id}/book",
        )
        fetchAllBooksLegacy(libraryId)
    }

    private suspend fun fetchAllBooksLegacy(libraryId: String?): List<BookSummaryDto> {
        val targetLibraryIds: List<String> = if (libraryId != null) {
            listOf(libraryId)
        } else {
            val resp = runSuspendCatching { api.getLibrariesLegacy() }.getOrNull()
            if (resp == null || !resp.isSuccessful) {
                throw Exception("Grimmory legacy libraries request failed (HTTP ${resp?.code() ?: "network"})")
            }
            resp.body().orEmpty().mapNotNull { it.id.takeIf { id -> id.isNotBlank() } }
        }
        val merged = mutableListOf<BookSummaryDto>()
        for (libId in targetLibraryIds) {

            val pageSize = 500
            var page = 0
            var libraryTotal = 0
            while (page < 200) {
                val resp = runSuspendCatching { api.getBooksLegacy(libId, page, pageSize) }.getOrNull()
                if (resp == null || !resp.isSuccessful) {
                    throw Exception("Grimmory legacy books request failed for library $libId (HTTP ${resp?.code() ?: "network"})")
                }
                val list = resp.body().orEmpty()
                if (list.isEmpty()) break
                list.forEach { merged += it.toBookSummaryDto(libId) }
                libraryTotal += list.size
                if (list.size < pageSize) break
                page++
            }
            android.util.Log.i("GrimmoryRepository", "Legacy /libraries/$libId/book yielded $libraryTotal books across ${page + 1} pages")
        }
        return merged
    }

    private fun com.enve.app.data.remote.dto.LegacyBookloreBookDto.toBookSummaryDto(
        fallbackLibraryId: String?,
    ): BookSummaryDto {
        return BookSummaryDto(
            id = id,
            title = listOfNotNull(title, metadata?.title, name)
                .firstOrNull { it.isNotBlank() } ?: "Untitled",
            authors = metadata?.authors,
            thumbnailUrl = metadata?.thumbnailUrl,
            readStatus = readStatus,
            personalRating = null,
            seriesName = metadata?.seriesName,
            seriesNumber = metadata?.seriesNumber,
            libraryId = libraryId ?: fallbackLibraryId,
            libraryName = null,
            addedOn = addedOn,
            lastReadTime = lastReadTime,
            readProgress = readProgress,
            primaryFileType = primaryFile?.bookType,
            coverUpdatedOn = metadata?.coverUpdatedOn,
            audiobookCoverUpdatedOn = metadata?.audiobookCoverUpdatedOn,
            primaryFile = primaryFile,
            alternativeFormats = alternativeFormats,
        )
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

        val connectionId = prefs.getActiveConnectionIdSync()
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
        val detail = api.getBookDetail(rawBookId).body()
        val info = api.getAudiobookInfo(rawBookId).body()
        return mergeListedAudiobook(book, detail?.copyWithResolvedMediaType(), info, serverUrl, token)
    }

    private suspend fun enrichListedEbook(book: Book, serverUrl: String, token: String? = null): Book {
        val detail = api.getBookDetail(book.id.grimmoryServerBookId()).body()?.copyWithResolvedMediaType() ?: return book
        return mergeListedEbook(book, detail, serverUrl, token)
    }

    private suspend fun fetchJellyfinLibraries(): List<Library> {
        val meResponse = api.jellyfinMe()
        if (!meResponse.isSuccessful) return emptyList()
        val userId = meResponse.body()?.optString("Id") ?: return emptyList()

        val viewsResponse = api.jellyfinViews(userId)
        if (!viewsResponse.isSuccessful) return emptyList()
        val views = viewsResponse.body()?.optArray("Items") ?: JsonArray(emptyList())

        return views.mapNotNull { element ->
            val obj = element.asObjectOrNull() ?: return@mapNotNull null
            val collectionType = obj.optString("CollectionType")?.lowercase()
            if (collectionType != "books" && collectionType != "audiobooks") return@mapNotNull null
            val id = obj.optString("Id") ?: return@mapNotNull null
            val name = obj.optString("Name") ?: return@mapNotNull null
            Library(
                id = id,
                name = name,
                bookCount = obj.optInt("ChildCount") ?: 0,
            )
        }
    }

    private suspend fun fetchJellyfinBooks(libraryId: String?, serverUrl: String): List<Book> {
        val meResponse = api.jellyfinMe()
        if (!meResponse.isSuccessful) return emptyList()
        val userId = meResponse.body()?.optString("Id") ?: return emptyList()

        val parentId = libraryId ?: fetchJellyfinLibraries().firstOrNull()?.id ?: return emptyList()
        val itemsResponse = api.jellyfinItems(userId = userId, parentId = parentId)
        if (!itemsResponse.isSuccessful) return emptyList()

        val items = itemsResponse.body()?.optArray("Items") ?: JsonArray(emptyList())
        return items.mapNotNull { element ->
            val obj = element.asObjectOrNull() ?: return@mapNotNull null
            val id = obj.optString("Id") ?: return@mapNotNull null
            val title = obj.optString("Name") ?: return@mapNotNull null

            val runtimeTicks = obj.optLong("RunTimeTicks") ?: 0L
            val durationSec = if (runtimeTicks > 0L) runtimeTicks / 10_000_000L else 0L

            val userData = obj.optObject("UserData")
            val playbackTicks = userData?.optLong("PlaybackPositionTicks") ?: 0L
            val positionSec = if (playbackTicks > 0L) playbackTicks / 10_000_000L else 0L
            val progress = normalizeFraction(userData?.optFloat("PlayedPercentage"))

            val people = obj.optArray("People")
            val author = people?.firstOrNull { it.asObjectOrNull()?.optString("Type") == "Author" }
                ?.asObjectOrNull()?.optString("Name")

            val narrator = people?.firstOrNull { it.asObjectOrNull()?.optString("Type") == "Narrator" }
                ?.asObjectOrNull()?.optString("Name")

            val itemType = obj.optString("Type")?.uppercase()
            val mediaType = when (itemType) {
                "BOOK" -> AppMediaType.EBOOK
                "AUDIOBOOK" -> AppMediaType.AUDIOBOOK
                else -> AppMediaType.AUDIOBOOK
            }

            val imageTags = obj.optObject("ImageTags")
            val primaryTag = imageTags?.optString("Primary")
            val coverUrl = if (primaryTag != null) {
                "${serverUrl.trimEnd('/')}/Items/$id/Images/Primary?tag=$primaryTag"
            } else {
                "${serverUrl.trimEnd('/')}/Items/$id/Images/Primary"
            }

            Book(
                id = id,
                title = title,
                author = author,
                narrator = narrator,
                description = obj.optString("Overview"),
                coverUrl = coverUrl,
                duration = durationSec,
                currentTime = positionSec,
                readProgress = progress,
                source = BookSource.JELLYFIN,
                mediaType = mediaType,
                libraryId = parentId,
                isFinished = progress >= 0.99f,
            )
        }
    }

    private suspend fun fetchEmbyLibraries(): List<Library> {
        val userId = fetchEmbyUserId() ?: return emptyList()
        val viewsResponse = api.embyViews(userId)
        if (!viewsResponse.isSuccessful) return emptyList()
        val views = viewsResponse.body()?.optArray("Items") ?: JsonArray(emptyList())

        return views.mapNotNull { element ->
            val obj = element.asObjectOrNull() ?: return@mapNotNull null
            val collectionType = obj.optString("CollectionType")?.lowercase()
            if (collectionType != "books" && collectionType != "audiobooks") return@mapNotNull null
            val id = obj.optString("Id") ?: return@mapNotNull null
            val name = obj.optString("Name") ?: return@mapNotNull null
            Library(
                id = id,
                name = name,
                bookCount = obj.optInt("ChildCount") ?: 0,
            )
        }
    }

    private suspend fun fetchEmbyBooks(libraryId: String?, serverUrl: String): List<Book> {
        val userId = fetchEmbyUserId() ?: return emptyList()

        val parentId = libraryId ?: fetchEmbyLibraries().firstOrNull()?.id ?: return emptyList()
        val itemsResponse = api.embyItems(userId = userId, parentId = parentId)
        if (!itemsResponse.isSuccessful) return emptyList()

        val items = itemsResponse.body()?.optArray("Items") ?: JsonArray(emptyList())
        return items.mapNotNull { element ->
            val obj = element.asObjectOrNull() ?: return@mapNotNull null
            val id = obj.optString("Id") ?: return@mapNotNull null
            val title = obj.optString("Name") ?: return@mapNotNull null

            val runtimeTicks = obj.optLong("RunTimeTicks") ?: 0L
            val durationSec = if (runtimeTicks > 0L) runtimeTicks / 10_000_000L else 0L

            val userData = obj.optObject("UserData")
            val playbackTicks = userData?.optLong("PlaybackPositionTicks") ?: 0L
            val positionSec = if (playbackTicks > 0L) playbackTicks / 10_000_000L else 0L
            val progress = normalizeFraction(userData?.optFloat("PlayedPercentage"))

            val people = obj.optArray("People")
            val author = people?.firstOrNull { it.asObjectOrNull()?.optString("Type") == "Author" }
                ?.asObjectOrNull()?.optString("Name")

            val itemType = obj.optString("Type")?.uppercase()
            val mediaType = when (itemType) {
                "BOOK" -> AppMediaType.EBOOK
                "AUDIOBOOK" -> AppMediaType.AUDIOBOOK
                else -> AppMediaType.AUDIOBOOK
            }
            val ownImageTag = obj.optObject("ImageTags")?.optString("Primary")
            val primaryImageItemId = obj.optString("PrimaryImageItemId")
            val primaryImageTag = obj.optString("PrimaryImageTag")
            val parentImageItemId = obj.optString("ParentPrimaryImageItemId")
            val parentImageTag = obj.optString("ParentPrimaryImageTag")
            val albumId = obj.optString("AlbumId")
            val albumImageTag = obj.optString("AlbumPrimaryImageTag")
            val imageReference = when {
                ownImageTag != null -> id to ownImageTag
                primaryImageItemId != null && primaryImageTag != null -> primaryImageItemId to primaryImageTag
                parentImageItemId != null && parentImageTag != null -> parentImageItemId to parentImageTag
                albumId != null && albumImageTag != null -> albumId to albumImageTag
                else -> null
            }
            val coverUrl = imageReference?.let { (coverItemId, imageTag) ->
                "${serverUrl.trimEnd('/')}/Items/$coverItemId/Images/Primary?tag=$imageTag"
            }

            Book(
                id = id,
                title = title,
                author = author,
                description = obj.optString("Overview"),
                coverUrl = coverUrl,
                duration = durationSec,
                currentTime = positionSec,
                readProgress = progress,
                source = BookSource.EMBY,
                mediaType = mediaType,
                libraryId = parentId,
                isFinished = progress >= 0.99f,
            )
        }
    }

    private suspend fun fetchEmbyUserId(): String? {
        val username = resolveScopedContext().username
        if (username.isBlank()) return null
        val response = api.embyUsers()
        if (!response.isSuccessful) return null
        return response.body()
            ?.mapNotNull { it.asObjectOrNull() }
            ?.firstOrNull { it.optString("Name").equals(username, ignoreCase = true) }
            ?.optString("Id")
    }

    private suspend fun fetchKavitaLibraries(): List<Library> {
        val response = api.kavitaLibraries()
        if (!response.isSuccessful) return emptyList()
        val body = response.body() ?: return emptyList()
        val libs = body.optArray("data")
            ?: body.optArray("libraries")
            ?: body.optArray("items")
            ?: JsonArray(emptyList())

        return libs.mapNotNull { element ->
            val obj = element.asObjectOrNull() ?: return@mapNotNull null
            val id = obj.optString("id") ?: obj.optString("libraryId") ?: return@mapNotNull null
            val name = obj.optString("name") ?: obj.optString("title") ?: return@mapNotNull null
            Library(
                id = id,
                name = name,
                bookCount = obj.optInt("bookCount") ?: obj.optInt("itemCount") ?: 0,
            )
        }
    }

    private suspend fun fetchKavitaBooks(libraryId: String?, serverUrl: String): List<Book> {
        val targetLibrary = libraryId ?: fetchKavitaLibraries().firstOrNull()?.id ?: return emptyList()
        val response = api.kavitaLibraryBooks(libraryId = targetLibrary)
        if (!response.isSuccessful) return emptyList()
        val body = response.body() ?: return emptyList()
        val items = body.optArray("data")
            ?: body.optArray("items")
            ?: body.optArray("content")
            ?: JsonArray(emptyList())

        return items.mapNotNull { element ->
            val obj = element.asObjectOrNull() ?: return@mapNotNull null
            val id = obj.optString("id") ?: return@mapNotNull null
            val title = obj.optString("title") ?: obj.optString("name") ?: return@mapNotNull null

            val author = obj.optString("author")
                ?: obj.optArray("authors")?.mapNotNull { it.jsonPrimitive.contentOrNull }?.joinToString(", ")

            val format = obj.optString("format")?.lowercase().orEmpty()
            val mediaType = if (format.contains("audio")) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK

            val coverPath = obj.optString("coverImage") ?: obj.optString("coverUrl")
            val coverUrl = when {
                coverPath.isNullOrBlank() -> null
                coverPath.startsWith("http") -> coverPath
                else -> "${serverUrl.trimEnd('/')}/${coverPath.trimStart('/')}"
            }

            Book(
                id = id,
                title = title,
                author = author,
                description = obj.optString("summary") ?: obj.optString("description"),
                coverUrl = coverUrl,
                source = BookSource.KAVITA,
                mediaType = mediaType,
                libraryId = targetLibrary,
                readProgress = normalizeFraction(obj.optFloat("readProgress") ?: obj.optFloat("progress")),
                addedOn = parseServerDate(obj.optString("created") ?: obj.optString("createdUtc")),
                lastReadTime = parseServerDate(obj.optString("lastRead") ?: obj.optString("lastReadUtc")),
            )
        }
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
            val propfindBody = """
                <?xml version="1.0" encoding="utf-8" ?>
                <d:propfind xmlns:d="DAV:">
                  <d:prop>
                    <d:resourcetype />
                    <d:getcontentlength />
                    <d:getlastmodified />
                  </d:prop>
                </d:propfind>
            """.trimIndent().toRequestBody("application/xml; charset=utf-8".toMediaType())
            val propfind = runSuspendCatching {
                val response = api.propfindRawUrl(url, body = propfindBody)
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

        fun hrefsFromListing(url: String, listingText: String): List<String> {
            val hrefsFromXml = Regex("<(?:[a-z]+:)?href>(.*?)</(?:[a-z]+:)?href>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
                .findAll(listingText)
                .mapNotNull { it.groupValues.getOrNull(1)?.trim() }
                .toList()

            val hrefsFromHtml = Regex("<a\\b[^>]*href=[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
                .findAll(listingText)
                .mapNotNull { it.groupValues.getOrNull(1)?.trim() }
                .toList()

            return (hrefsFromXml + hrefsFromHtml)
                .map { decodeXmlEntities(it) }
                .map { resolveAgainst(url, it) }
                .filter { it.isNotBlank() }
                .distinct()
        }

        val supportedExtensions = setOf("epub", "pdf", "cbz", "cbr", "cbx", "mobi", "azw3", "mp3", "m4b", "aac", "flac", "ogg")
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
            val ctx = resolveScopedContext()
            torBoxRootCandidates(fetchTorBoxAudioFiles(ctx, rootPaths = emptyList()))
        }
    }

    private suspend fun fetchTorBoxRootLibraries(ctx: ScopedContext): List<Library> {
        val selectedRoots = torBoxEffectiveRootPaths(ctx.cloudRootPaths)
        if (selectedRoots.isEmpty()) {
            return listOf(Library(id = "torbox-cloud", name = "TorBox Cloud", bookCount = 0, source = BookSource.TORBOX))
        }
        return selectedRoots.map { root ->
            Library(
                id = torBoxLibraryId(root),
                name = root.substringAfterLast('/'),
                bookCount = 0,
                source = BookSource.TORBOX,
            )
        }
    }

    private suspend fun fetchTorBoxBooks(ctx: ScopedContext, libraryId: String?): List<Book> {
        val rootPaths = libraryId
            ?.takeIf { it.startsWith(TORBOX_LIBRARY_PREFIX) }
            ?.let { listOf(torBoxRootFromLibraryId(it)) }
            ?: torBoxEffectiveRootPaths(ctx.cloudRootPaths)
        val files = fetchTorBoxAudioFiles(ctx, rootPaths)
        val groups = groupCloudAudioFiles(files)
        Log.i("GrimmoryRepository", "TorBox books: roots=${rootPaths.size} files=${files.size} groups=${groups.size} library=$libraryId")
        val effectiveLibraryId = libraryId ?: "torbox-cloud"
        return groups
            .map {
                it.toCloudBook(
                    source = BookSource.TORBOX,
                    libraryId = effectiveLibraryId,
                    libraryName = if (libraryId != null && libraryId.startsWith(TORBOX_LIBRARY_PREFIX)) {
                        torBoxRootFromLibraryId(libraryId).substringAfterLast('/')
                    } else {
                        "TorBox Cloud"
                    },
                    idPrefix = "torbox",
                    stableScope = ctx.connectionId ?: ctx.serverUrl,
                )
            }
            .sortedBy { it.title.lowercase() }
    }

    private suspend fun fetchTorBoxAudioFiles(
        ctx: ScopedContext,
        rootPaths: List<String>,
    ): List<CloudAudioFile> {
        val baseUrl = normalizedTorBoxBase(ctx.serverUrl)
        val token = ctx.token.takeIf { it.isNotBlank() } ?: return emptyList()
        val apiFiles = buildList {
            addAll(fetchTorBoxDownloadTypeAudioFiles(baseUrl, token, "torrents", "torrent_id", "tb-torrent"))
            addAll(fetchTorBoxDownloadTypeAudioFiles(baseUrl, token, "usenet", "usenet_id", "tb-usenet"))
            addAll(fetchTorBoxDownloadTypeAudioFiles(baseUrl, token, "webdl", "web_id", "tb-webdl"))
        }
        val webDavFiles = fetchTorBoxWebDavAudioFiles(token)
        val files = mergeTorBoxFiles(apiFiles, webDavFiles)
        val filtered = filterCloudFilesByRoots(files, rootPaths)
        Log.i("GrimmoryRepository", "TorBox files: api=${apiFiles.size} webdav=${webDavFiles.size} total=${files.size} filtered=${filtered.size} roots=${rootPaths.size}")
        return filtered
    }

    private fun mergeTorBoxFiles(apiFiles: List<CloudAudioFile>, webDavFiles: List<CloudAudioFile>): List<CloudAudioFile> {
        val merged = LinkedHashMap<String, CloudAudioFile>()
        apiFiles.forEach { file ->
            merged[file.path.trim('/').lowercase()] = file
        }
        webDavFiles.forEach { file ->
            val key = file.path.trim('/').lowercase()
            val api = merged[key]
            merged[key] = if (api == null) {
                file
            } else {
                api.copy(
                    name = file.name,
                    path = file.path,
                    parentFolder = file.parentFolder,
                    link = file.link,
                    size = api.size ?: file.size,
                    coverUrl = file.coverUrl ?: api.coverUrl,
                )
            }
        }
        return merged.values.toList()
    }

    private suspend fun fetchTorBoxDownloadTypeAudioFiles(
        baseUrl: String,
        token: String,
        typePath: String,
        idParameter: String,
        idPrefix: String,
    ): List<CloudAudioFile> {
        val files = mutableListOf<CloudAudioFile>()
        val covers = mutableListOf<CloudCoverFile>()
        var offset = 0
        val limit = 1000
        val seenItemIds = mutableSetOf<String>()

        while (offset < TORBOX_MAX_LIST_ITEMS && files.size < TORBOX_MAX_AUDIO_FILES) {
            val url = buildProviderUrl(baseUrl, typePath, "mylist")
                ?.toHttpUrlOrNull()
                ?.newBuilder()
                ?.addQueryParameter("limit", limit.toString())
                ?.addQueryParameter("offset", offset.toString())
                ?.addQueryParameter("bypass_cache", "true")
                ?.build()
                ?.toString()
                ?: return files
            val items = fetchWrappedJsonArray(url, "data")
            if (items.isEmpty()) break
            val newItems = items.filter { item ->
                val itemId = item.string("id") ?: item.string("id_")
                itemId != null && seenItemIds.add(itemId)
            }
            if (newItems.isEmpty()) break

            newItems.forEach { item ->
                val hasAvailabilityFlag = item.containsKey("cached") ||
                    item.containsKey("download_present") ||
                    item.containsKey("download_finished")
                if (hasAvailabilityFlag && !item.bool("cached") && !item.bool("download_present") && !item.bool("download_finished")) {
                    return@forEach
                }
                val itemId = item.string("id") ?: item.string("id_") ?: return@forEach
                val itemName = (item.string("name") ?: item.string("filename") ?: item.string("hash") ?: itemId)
                    .let(::decodeUrlPath)
                item["files"]
                    ?.jsonArrayOrNull()
                    ?.mapNotNull { it.jsonObjectOrNull() }
                    .orEmpty()
                    .forEach { file ->
                        val fileId = file.string("id") ?: file.string("id_") ?: return@forEach
                        val fullPath = torBoxDisplayPath(file, itemName)?.let(::decodeUrlPath) ?: return@forEach
                        val name = (file.string("short_name") ?: fullPath.substringAfterLast('/'))
                            .let(::decodeUrlPathSegment)
                        val link = buildTorBoxRequestDownloadUrl(baseUrl, token, typePath, idParameter, itemId, fileId)
                            ?: return@forEach
                        val parentPath = fullPath.trim('/').substringBeforeLast('/', missingDelimiterValue = "")
                            .takeIf { it.isNotBlank() }
                            ?: itemName
                        if (isCloudCoverFile(name)) {
                            covers += CloudCoverFile(
                                path = fullPath,
                                parentFolder = parentPath,
                                link = link,
                                rank = cloudCoverRank(name),
                            )
                            return@forEach
                        }
                        if (!isCloudAudioFile(name)) return@forEach
                        files += CloudAudioFile(
                            id = "$idPrefix-$itemId-$fileId",
                            name = name,
                            path = fullPath,
                            parentFolder = parentPath,
                            link = link,
                            size = file.long("size"),
                        )
                    }
            }

            offset += items.size
        }

        Log.i("GrimmoryRepository", "TorBox $typePath scan: items=${seenItemIds.size} audio=${files.size} covers=${covers.size}")
        return attachCloudCovers(files, covers)
    }

    private suspend fun fetchTorBoxWebDavAudioFiles(token: String): List<CloudAudioFile> = withContext(Dispatchers.IO) {
        val base = "https://webdav.torbox.app/"
        val pendingDirs = ArrayDeque<String>().apply { add(base) }
        val visitedDirs = mutableSetOf<String>()
        val audioFiles = mutableListOf<CloudAudioFile>()
        val coverFiles = mutableListOf<CloudCoverFile>()

        while (pendingDirs.isNotEmpty() && visitedDirs.size < TORBOX_WEBDAV_MAX_DIRS && audioFiles.size < TORBOX_MAX_AUDIO_FILES) {
            val dir = pendingDirs.removeFirst().trimEnd('/') + "/"
            if (!visitedDirs.add(dir)) continue
            val listing = torBoxWebDavListing(dir, token) ?: continue
            torBoxHrefsFromListing(dir, listing).forEach { href ->
                val clean = href.substringBefore('#').substringBefore('?')
                if (clean.trimEnd('/') == dir.trimEnd('/')) return@forEach
                if (clean.endsWith("/")) {
                    if (clean !in visitedDirs && pendingDirs.size < TORBOX_WEBDAV_MAX_DIRS) pendingDirs.add(clean)
                    return@forEach
                }
                val name = decodeUrlPathSegment(clean.substringAfterLast('/')).takeIf { it.isNotBlank() } ?: return@forEach
                val relativePath = torBoxWebDavRelativePath(base, clean)?.let(::decodeUrlPath) ?: return@forEach
                val parent = relativePath.substringBeforeLast('/', missingDelimiterValue = "")
                    .takeIf { it.isNotBlank() }
                    ?: "TorBox WebDAV"
                val link = torBoxWebDavCredentialUrl(clean, token) ?: clean
                if (isCloudCoverFile(name)) {
                    coverFiles += CloudCoverFile(
                        path = relativePath,
                        parentFolder = parent,
                        link = link,
                        rank = cloudCoverRank(name),
                    )
                    return@forEach
                }
                if (!isCloudAudioFile(name)) return@forEach
                audioFiles += CloudAudioFile(
                    id = "tb-webdav-${stableId(relativePath)}",
                    name = name,
                    path = relativePath,
                    parentFolder = parent,
                    link = link,
                    size = null,
                )
            }
        }

        Log.i("GrimmoryRepository", "TorBox WebDAV scan: dirs=${visitedDirs.size} audio=${audioFiles.size} covers=${coverFiles.size}")
        attachCloudCovers(audioFiles, coverFiles)
    }

    private fun torBoxWebDavListing(url: String, token: String): String? = try {
        val propfindBody = """
            <?xml version="1.0" encoding="utf-8" ?>
            <d:propfind xmlns:d="DAV:">
              <d:prop>
                <d:resourcetype />
                <d:getcontentlength />
                <d:getlastmodified />
              </d:prop>
            </d:propfind>
        """.trimIndent().toRequestBody("application/xml; charset=utf-8".toMediaType())
        val request = Request.Builder()
            .url(url)
            .method("PROPFIND", propfindBody)
            .header("Depth", "1")
            .header("Authorization", Credentials.basic("torbox", token))
            .build()
        torBoxWebDavClient.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return@use null
            response.body?.string()
        }
    } catch (e: kotlinx.coroutines.CancellationException) {
        throw e
    } catch (e: Exception) {
        null
    }

    private fun torBoxHrefsFromListing(url: String, listingText: String): List<String> {
        return Regex("<(?:[a-z]+:)?href>(.*?)</(?:[a-z]+:)?href>", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
            .findAll(listingText)
            .mapNotNull { it.groupValues.getOrNull(1)?.trim() }
            .map { decodeXmlEntities(it) }
            .map { resolveAgainst(url, it) }
            .filter { it.isNotBlank() }
            .distinct()
            .toList()
    }

    private fun torBoxWebDavRelativePath(base: String, url: String): String? {
        val basePath = base.trimEnd('/') + "/"
        val resolved = url.substringBefore('#').substringBefore('?')
        return resolved.removePrefix(basePath)
            .trim('/')
            .takeIf { it.isNotBlank() && it != resolved }
    }

    private fun decodeUrlPath(path: String): String =
        path.split('/').joinToString("/") { decodeUrlPathSegment(it) }

    private fun decodeUrlPathSegment(segment: String): String =
        runCatching { URLDecoder.decode(segment.replace("+", "%2B"), Charsets.UTF_8.name()) }
            .getOrElse { segment }

    private fun torBoxWebDavCredentialUrl(url: String, token: String): String? {
        val parsed = url.toHttpUrlOrNull() ?: return null
        return parsed.newBuilder()
            .username("torbox")
            .password(token)
            .build()
            .toString()
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
                val name = entry.string("name") ?: return@forEach
                val id = entry.string("id") ?: entry.string("file_id") ?: stableId(name)
                val link = entry.string("link").orEmpty()
                val type = entry.string("type").orEmpty()
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
                    path = entry.string("path") ?: folderName?.let { "$it/$name" } ?: name,
                    parentFolder = folderName,
                    link = link,
                    size = entry.long("size"),
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
            ?.jsonArrayOrNull()
            ?.mapNotNull { it.jsonObjectOrNull() }
            .orEmpty()
    }

    private suspend fun fetchRealDebridTorrentAudioFiles(baseUrl: String): List<CloudAudioFile> {
        val torrentsUrl = buildProviderUrl(baseUrl, "torrents") ?: return emptyList()
        val torrents = fetchJsonArray(torrentsUrl)
        val files = mutableListOf<CloudAudioFile>()

        for (torrent in torrents.take(250)) {
            val torrentId = torrent.string("id") ?: continue
            val torrentName = torrent.string("filename") ?: torrentId
            val infoUrl = buildProviderUrl(baseUrl, "torrents", "info", torrentId) ?: continue
            val info = fetchJsonObject(infoUrl) ?: continue
            val selectedAudioFiles = info["files"]
                ?.jsonArrayOrNull()
                ?.mapNotNull { it.jsonObjectOrNull() }
                ?.filter { it.int("selected") == 1 }
                ?.filter { file -> isCloudAudioFile(file.string("path")?.substringAfterLast('/') ?: "") }
                .orEmpty()
            if (selectedAudioFiles.isEmpty()) continue

            val directLinks = mutableMapOf<String, String>()
            info["links"]
                ?.jsonArrayOrNull()
                ?.mapNotNull { it.jsonPrimitive.contentOrNull }
                .orEmpty()
                .forEach { restrictedLink ->
                    val unrestricted = unrestrictRealDebridLink(baseUrl, restrictedLink) ?: return@forEach
                    val filename = unrestricted.string("filename") ?: return@forEach
                    val download = unrestricted.string("download") ?: return@forEach
                    if (isCloudAudioFile(filename)) {
                        directLinks[filename.lowercase()] = download
                    }
                }

            selectedAudioFiles.forEach { file ->
                val path = file.string("path") ?: return@forEach
                val name = path.substringAfterLast('/')
                val link = directLinks[name.lowercase()] ?: return@forEach
                files += CloudAudioFile(
                    id = "rd-$torrentId-${file.int("id") ?: stableId(path)}",
                    name = name,
                    path = "/torrents/$torrentId/$path",
                    parentFolder = groupingFolderName(path) ?: torrentName,
                    link = link,
                    size = file.long("bytes"),
                )
            }
        }

        return files
    }

    private suspend fun fetchRealDebridDownloadAudioFiles(baseUrl: String): List<CloudAudioFile> {
        val downloadsUrl = buildProviderUrl(baseUrl, "downloads") ?: return emptyList()
        return fetchJsonArray(downloadsUrl)
            .mapNotNull { item ->
                val name = item.string("filename") ?: return@mapNotNull null
                val link = item.string("download") ?: return@mapNotNull null
                if (!isCloudAudioFile(name) || link.isBlank()) return@mapNotNull null
                CloudAudioFile(
                    id = "rd-dl-${item.string("id") ?: stableId(link)}",
                    name = name,
                    path = "/downloads/$name",
                    parentFolder = null,
                    link = link,
                    size = item.long("filesize") ?: item.long("bytes"),
                )
            }
    }

    private suspend fun unrestrictRealDebridLink(baseUrl: String, restrictedLink: String): JsonObject? {
        val url = buildProviderUrl(baseUrl, "unrestrict", "link") ?: return null
        return runSuspendCatching {
            val response = api.postFormRawUrl(url, restrictedLink)
            if (!response.isSuccessful) return@runSuspendCatching null
            response.body()?.string()?.takeIf { it.isNotBlank() }?.let {
                jsonSerializer.parseToJsonElement(it).jsonObjectOrNull()
            }
        }.getOrNull()
    }

    private suspend fun fetchJsonObject(url: String): JsonObject? = runSuspendCatching {
        val response = api.fetchRawUrl(url)
        if (!response.isSuccessful) return@runSuspendCatching null
        response.body()?.string()?.takeIf { it.isNotBlank() }?.let {
            jsonSerializer.parseToJsonElement(it).jsonObjectOrNull()
        }
    }.getOrNull()

    private suspend fun fetchJsonArray(url: String): List<JsonObject> = runSuspendCatching {
        val response = api.fetchRawUrl(url)
        if (!response.isSuccessful) return@runSuspendCatching emptyList()
        response.body()?.string()?.takeIf { it.isNotBlank() }
            ?.let { jsonSerializer.parseToJsonElement(it).jsonArrayOrNull() }
            ?.mapNotNull { it.jsonObjectOrNull() }
            .orEmpty()
    }.getOrDefault(emptyList())

    private suspend fun fetchWrappedJsonArray(url: String, key: String): List<JsonObject> = runSuspendCatching {
        val response = api.fetchRawUrl(url)
        if (!response.isSuccessful) return@runSuspendCatching emptyList()
        response.body()?.string()?.takeIf { it.isNotBlank() }
            ?.let { jsonSerializer.parseToJsonElement(it).jsonObjectOrNull() }
            ?.get(key)
            ?.jsonArrayOrNull()
            ?.mapNotNull { it.jsonObjectOrNull() }
            .orEmpty()
    }.getOrDefault(emptyList())

    private fun groupCloudAudioFiles(files: List<CloudAudioFile>): List<CloudBookGroup> {
        return files
            .groupBy { file ->
                file.parentFolder?.takeIf { it.isNotBlank() }?.let { "folder:${it.lowercase()}" }
                    ?: "file:${file.name.substringBeforeLast('.').lowercase()}"
            }
            .flatMap { (folderKey, folderFiles) ->
                val groups = AudiobookFileGrouping.groups(
                    files = folderFiles,
                    name = CloudAudioFile::name,
                    sizeBytes = { it.size ?: 0L },
                )
                val isCollectionFolder = groups.size > 1
                groups.map { groupedFiles ->
                    val sorted = AudiobookFileGrouping.sorted(groupedFiles, CloudAudioFile::name)
                    val first = sorted.first()
                    val title = if (isCollectionFolder) {
                        AudiobookFileGrouping.inferredTitle(first.name)
                    } else {
                        first.parentFolder?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                            ?: first.name.substringBeforeLast('.').replace('_', ' ')
                    }
                    CloudBookGroup(
                        key = if (isCollectionFolder) "file:${first.path.lowercase()}" else folderKey,
                        title = title,
                        folderPath = first.parentFolder,
                        files = sorted,
                        coverUrl = if (isCollectionFolder) null else sorted.firstNotNullOfOrNull { it.coverUrl },
                    )
                }
            }
    }

    private fun CloudBookGroup.toCloudBook(
        source: BookSource,
        libraryId: String,
        libraryName: String,
        idPrefix: String,
        stableScope: String,
    ): Book {
        val derived = derivedCloudTitleAuthor()
        val tracks = files.mapIndexed { index, file ->
            AudioTrack(
                index = index,
                fileName = file.name,
                title = file.name.substringBeforeLast('.').cleanCloudDisplayName(),
                durationMs = 0L,
                fileSizeBytes = file.size ?: 0L,
                cumulativeStartMs = 0L,
                fileId = file.id,
                contentUrl = file.link,
            )
        }
        val id = "$idPrefix-${stableId("$stableScope|$key")}"
        val durationMs = when {
            tracks.size == 1 -> tracks.firstOrNull()?.durationMs ?: 0L
            tracks.isNotEmpty() && tracks.all { it.durationMs > 0L } -> tracks.sumOf { it.durationMs }
            else -> 0L
        }
        return Book(
            id = id,
            title = derived.title,
            author = derived.author,
            narrator = null,
            coverUrl = coverUrl,
            duration = durationMs / 1000L,
            source = source,
            mediaType = AppMediaType.AUDIOBOOK,
            libraryId = libraryId,
            libraryName = libraryName,
            audioTracks = tracks,
            hasAudio = tracks.isNotEmpty(),
        )
    }

    private fun CloudBookGroup.derivedCloudTitleAuthor(): CloudTitleAuthor {
        val cleanTitle = title.cleanCloudDisplayName()
        val currentSplit = splitAuthorTitle(cleanTitle)
        if (currentSplit != null) return currentSplit
        val author = folderPath
            ?.split('/')
            .orEmpty()
            .firstNotNullOfOrNull { splitAuthorTitle(it.cleanCloudDisplayName())?.author }
        return CloudTitleAuthor(title = cleanTitle, author = author)
    }

    private fun splitAuthorTitle(value: String): CloudTitleAuthor? {
        val parts = value.split(" - ", limit = 2)
        val author = parts.getOrNull(0)?.trim().orEmpty()
        val title = parts.getOrNull(1)?.trim().orEmpty()
        if (author.isBlank() || title.isBlank()) return null
        if (author.any { it.isDigit() } && author.length <= 5) return null
        return CloudTitleAuthor(title = title, author = author)
    }

    private fun String.cleanCloudDisplayName(): String =
        decodeUrlPath(this)
            .replace('_', ' ')
            .replace(Regex("\\s+"), " ")
            .trim()

    private fun normalizedPremiumizeBase(serverUrl: String): String =
        serverUrl.ifBlank { "https://www.premiumize.me/api" }.trimEnd('/')

    private fun normalizedRealDebridBase(serverUrl: String): String =
        serverUrl.ifBlank { "https://api.real-debrid.com/rest/1.0" }.trimEnd('/')

    private fun normalizedTorBoxBase(serverUrl: String): String =
        serverUrl.ifBlank { "https://api.torbox.app/v1/api" }.trimEnd('/')

    private fun buildProviderUrl(baseUrl: String, vararg pathSegments: String): String? {
        val builder = baseUrl.toHttpUrlOrNull()?.newBuilder() ?: return null
        pathSegments.forEach { builder.addPathSegment(it) }
        return builder.build().toString()
    }

    private fun buildTorBoxRequestDownloadUrl(
        baseUrl: String,
        token: String,
        typePath: String,
        idParameter: String,
        itemId: String,
        fileId: String,
    ): String? {
        return buildProviderUrl(baseUrl, typePath, "requestdl")
            ?.toHttpUrlOrNull()
            ?.newBuilder()
            ?.addQueryParameter("token", token)
            ?.addQueryParameter(idParameter, itemId)
            ?.addQueryParameter("file_id", fileId)
            ?.addQueryParameter("redirect", "true")
            ?.build()
            ?.toString()
    }

    private fun isCloudAudioFile(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in setOf("mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav")
    }

    private fun isCloudCoverFile(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in setOf("jpg", "jpeg", "png", "webp")
    }

    private fun cloudCoverRank(name: String): Int {
        val stem = name.substringAfterLast('/').substringBeforeLast('.').lowercase()
        return when {
            stem in setOf("cover", "folder", "front", "album", "artwork") -> 0
            "cover" in stem || "folder" in stem || "front" in stem -> 1
            else -> 10
        }
    }

    private fun attachCloudCovers(audioFiles: List<CloudAudioFile>, coverFiles: List<CloudCoverFile>): List<CloudAudioFile> {
        if (audioFiles.isEmpty() || coverFiles.isEmpty()) return audioFiles
        val coversByFolder = coverFiles
            .groupBy { it.parentFolder.trim('/') }
            .mapValues { (_, covers) ->
                covers.sortedWith(compareBy<CloudCoverFile> { it.rank }.thenBy { it.path.lowercase() }).first()
            }
        return audioFiles.map { file ->
            val parent = file.parentFolder?.trim('/').orEmpty()
            val cover = folderAndAncestors(parent).firstNotNullOfOrNull { coversByFolder[it] }
            if (cover == null) file else file.copy(coverUrl = cover.link)
        }
    }

    private fun folderAndAncestors(path: String): List<String> {
        val parts = path.split('/').filter { it.isNotBlank() }
        if (parts.isEmpty()) return emptyList()
        return parts.indices.reversed().map { index -> parts.take(index + 1).joinToString("/") }
    }

    private fun groupingFolderName(path: String): String? {
        val trimmed = path.trim('/').substringBeforeLast('/', missingDelimiterValue = "")
        return trimmed.substringAfterLast('/').takeIf { it.isNotBlank() }
    }

    private fun torBoxRootCandidates(files: List<CloudAudioFile>): List<String> {
        return files
            .flatMap { file ->
                val parent = file.parentFolder?.trim('/') ?: file.path.trim('/').substringBeforeLast('/', "")
                val parts = parent.split('/').filter { it.isNotBlank() }
                parts.indices.map { index -> parts.take(index + 1).joinToString("/") }
            }
            .distinct()
            .sortedWith(compareBy<String> { it.count { ch -> ch == '/' } }.thenBy { it.lowercase() })
            .take(TORBOX_MAX_ROOT_CANDIDATES)
    }

    private fun filterCloudFilesByRoots(files: List<CloudAudioFile>, rootPaths: List<String>): List<CloudAudioFile> {
        val roots = normalizeCloudRootPaths(rootPaths)
        if (roots.isEmpty()) return files
        return files.filter { file ->
            val path = file.path.trim('/')
            val parent = file.parentFolder?.trim('/').orEmpty()
            roots.any { root ->
                path == root || path.startsWith("$root/") || parent == root || parent.startsWith("$root/")
            }
        }
    }

    private fun normalizeCloudRootPaths(paths: List<String>): List<String> =
        paths.map { it.trim().trim('/') }
            .filter { it.isNotBlank() }
            .distinct()

    private fun torBoxEffectiveRootPaths(paths: List<String>): List<String> {
        val roots = normalizeCloudRootPaths(paths)
        if (roots.isEmpty()) return emptyList()
        val collapsed = roots
            .sortedBy { it.count { ch -> ch == '/' } }
            .filter { candidate ->
                roots.none { parent -> parent != candidate && candidate.startsWith("$parent/") }
            }
        val hadRedundantDescendants = collapsed.size != roots.size
        return if (hadRedundantDescendants && roots.size >= TORBOX_DEFAULT_SELECTION_ROOT_THRESHOLD) {
            emptyList()
        } else {
            collapsed
        }
    }

    private fun torBoxLibraryId(root: String): String = "$TORBOX_LIBRARY_PREFIX${root.trim('/')}"

    private fun torBoxRootFromLibraryId(libraryId: String): String =
        libraryId.removePrefix(TORBOX_LIBRARY_PREFIX).trim('/')

    private fun torBoxDisplayPath(file: JsonObject, itemName: String): String? {
        val name = file.string("name")
        val shortName = file.string("short_name")
        val explicitPath = file.string("path")
        val s3Path = file.string("s3_path")
        return listOfNotNull(
            explicitPath,
            name?.takeIf { '/' in it },
            shortName?.let { leaf ->
                name?.takeIf { it.isNotBlank() && it != leaf }?.let { "$it/$leaf" }
            },
            shortName?.let { "$itemName/$it" },
            name,
            s3Path,
        ).firstOrNull { it.isNotBlank() }?.trim('/')
    }

    private fun JsonObject.string(key: String): String? =
        this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }

    private fun JsonObject.long(key: String): Long? =
        this[key]?.jsonPrimitive?.let { primitive ->
            primitive.longOrNull ?: primitive.doubleOrNull?.toLong()
        }

    private fun JsonObject.int(key: String): Int? =
        this[key]?.jsonPrimitive?.intOrNull

    private fun JsonObject.bool(key: String): Boolean =
        this[key]?.jsonPrimitive?.booleanOrNull == true

    private fun JsonElement.jsonObjectOrNull(): JsonObject? =
        runCatching { jsonObject }.getOrNull()

    private fun JsonElement.jsonArrayOrNull(): JsonArray? =
        runCatching { jsonArray }.getOrNull()

    private fun stableId(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
        return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }.take(24)
    }

    companion object {
        private const val TORBOX_LIBRARY_PREFIX = "torbox-root:"
        private const val TORBOX_MAX_LIST_ITEMS = 100_000
        private const val TORBOX_MAX_AUDIO_FILES = 100_000
        private const val TORBOX_MAX_ROOT_CANDIDATES = 5_000
        private const val TORBOX_DEFAULT_SELECTION_ROOT_THRESHOLD = 10
        private const val TORBOX_WEBDAV_MAX_DIRS = 2_000
    }

}
