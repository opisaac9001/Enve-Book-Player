package com.enve.app.data.repository

import com.enve.app.data.repository.grimmory.resolveCoverUrl
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.BookSummaryPage
import com.enve.core.data.model.GrimmoryLibrary
import com.enve.core.data.model.GrimmoryMagicShelf
import com.enve.core.data.model.GrimmoryShelf
import com.enve.core.data.model.ReadStatus
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.remote.GRIMMORY_MAX_PAGE_SIZE
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.GrimmoryBrowsePage
import com.enve.app.data.remote.dto.LegacyBookloreBookDto
import com.enve.app.data.remote.dto.MagicShelfDto
import com.enve.app.data.remote.dto.ShelfDto
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.repository.grimmory.catalogReadProgress
import com.enve.app.data.repository.grimmory.grimmoryBrowseSort
import com.enve.app.data.repository.grimmory.grimmoryCompanionAudiobookId
import com.enve.app.data.repository.grimmory.grimmoryFacet
import com.enve.app.data.repository.grimmory.grimmoryPercentFraction
import com.enve.app.data.repository.grimmory.isGrimmoryAudioType
import com.enve.app.data.repository.grimmory.isGrimmoryEbookType
import com.enve.app.data.repository.grimmory.shouldUseLegacyGrimmoryCatalog
import com.enve.app.data.repository.grimmory.toGrimmoryWireStatus
import com.enve.core.data.util.runSuspendCatching
import com.enve.core.data.util.titleFromPrimaryFileName
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import retrofit2.Response
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GrimmoryAppRepository @Inject constructor(
    private val api: GrimmoryApi,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
    private val cache: GrimmoryDiskCache,
    private val offlineAudio: OfflineDownloadManager,
    private val offlineComic: ComicOfflineService,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val connectionMutex = Mutex()

    private enum class ApiTier { BROWSE, LEGACY }
    private val connectionTier = java.util.concurrent.ConcurrentHashMap<String, ApiTier>()
    private fun tierFor(connectionId: String): ApiTier =
        connectionTier[connectionId] ?: ApiTier.BROWSE

    val downloadedKeys: Flow<Set<String>> = combine(
        offlineAudio.downloadedKeys,
        offlineComic.downloadedKeys,
    ) { audio, comic -> audio + comic }

    fun isDownloaded(downloadKey: String): Boolean =
        offlineAudio.isDownloaded(downloadKey) || offlineComic.isDownloaded(downloadKey)

    suspend fun getLibraries(connectionId: String): Result<List<GrimmoryLibrary>> {
        val key = "libraries:$connectionId"
        cache.read(key, TTL_LONG)?.let {
            runCatching {
                json.decodeFromString(ListSerializer(GrimmoryLibrary.serializer()), it.payloadJson)
            }.getOrNull()?.takeIf { cached -> cached.isNotEmpty() }?.let { cached ->
                return Result.success(cached)
            }
        }
        val result = getLibrariesUncached(connectionId)
        result.getOrNull()?.let { libraries ->
            cache.write(key, json.encodeToString(ListSerializer(GrimmoryLibrary.serializer()), libraries))
        }
        return result
    }

    suspend fun getBooksPage(
        connectionId: String,
        libraryId: Long? = null,
        shelfId: Long? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc",
        status: ReadStatus? = null,
        search: String? = null,
    ): Result<BookSummaryPage> = withConnection(connectionId) {
        val serverUrl = serverUrl(connectionId)
        val query = search?.takeIf { it.isNotBlank() }
        val hasFilters = shelfId != null || status != null || query != null
        var browseTierUnavailable = false

        if (tierFor(connectionId) == ApiTier.BROWSE) {
            val facets = buildList {
                libraryId?.let { add(grimmoryFacet("library", it)) }
                shelfId?.let { add(grimmoryFacet("shelf", it)) }
                status?.let { add(grimmoryFacet("read_status", it.toGrimmoryWireStatus())) }
            }
            val browseResp = runSuspendCatching {
                browse(facets, query, grimmoryBrowseSort(sort, dir), page, size)
            }.getOrNull()

            when {
                browseResp == null -> {
                    android.util.Log.w("GrimmoryAppRepo", "getBooks browse threw for $connectionId lib=$libraryId; trying legacy")
                }
                browseResp.isSuccessful -> {
                    val body = browseResp.body()
                    if (page > 0 || hasFilters || !shouldUseLegacyGrimmoryCatalog(browseResp.code(), body?.content?.size)) {
                        if (body == null) return@withConnection Result.failure(Exception("Empty body"))
                        return@withConnection Result.success(body.toBookPage(connectionId, serverUrl, libraryId?.toString()))
                    }
                    browseTierUnavailable = true
                    android.util.Log.i("GrimmoryAppRepo", "getBooks browse returned an empty first page for $connectionId lib=$libraryId; trying legacy")
                }
                else -> {
                    browseTierUnavailable = browseResp.code() == 404 || browseResp.code() >= 500
                    android.util.Log.i("GrimmoryAppRepo", "getBooks browse HTTP ${browseResp.code()} for $connectionId lib=$libraryId; trying legacy")
                }
            }
        }

        val targetLibraries: List<Long> = when {
            libraryId != null -> listOf(libraryId)
            else -> {
                val libs = getLibrariesUncached(connectionId).getOrElse {
                    return@withConnection Result.failure(it)
                }
                libs.map { it.id }
            }
        }

        if (page > 0) {
            return@withConnection Result.success(BookSummaryPage(emptyList(), page, page + 1, 0, false))
        }

        val merged = mutableListOf<BookSummary>()
        for (libId in targetLibraries) {
            val pageSize = 500
            var legacyPage = 0
            var libraryTotal = 0
            while (legacyPage < 200) {
                val callResult = runSuspendCatching { api.getBooksLegacy(libId.toString(), legacyPage, pageSize) }
                val resp = callResult.getOrNull()
                if (resp == null) {
                    val message = callResult.exceptionOrNull()?.message ?: "request failed"
                    android.util.Log.w("GrimmoryAppRepo", "Legacy /libraries/$libId/book p=$legacyPage threw on $connectionId: $message")
                    return@withConnection Result.failure(Exception("Grimmory legacy catalog request failed: $message"))
                }
                if (!resp.isSuccessful) {
                    android.util.Log.w("GrimmoryAppRepo", "Legacy /libraries/$libId/book p=$legacyPage HTTP ${resp.code()} on $connectionId")
                    return@withConnection Result.failure(Exception("Grimmory catalog unavailable (legacy HTTP ${resp.code()})"))
                }
                val list = resp.body().orEmpty()
                if (list.isEmpty()) break
                list.forEach { dto ->
                    merged += dto.toBookSummaries(connectionId, serverUrl, libId.toString())
                }
                libraryTotal += list.size
                if (list.size < pageSize) break
                legacyPage++
            }
            android.util.Log.i("GrimmoryAppRepo", "Legacy /libraries/$libId/book yielded $libraryTotal books across ${legacyPage + 1} pages on $connectionId")
        }
        if (browseTierUnavailable) connectionTier[connectionId] = ApiTier.LEGACY

        val filtered = if (query != null) {
            val needle = query.lowercase()
            merged.filter {
                it.title.lowercase().contains(needle) ||
                    it.authors.any { a -> a.lowercase().contains(needle) }
            }
        } else merged
        Result.success(
            BookSummaryPage(
                items = filtered,
                page = 0,
                totalPages = 1,
                totalElements = filtered.size.toLong(),
                hasNext = false,
            )
        )
    }

    private suspend fun getLibrariesUncached(connectionId: String): Result<List<GrimmoryLibrary>> = withConnection(connectionId) {
        val resp = api.getLibraries()
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        Result.success(resp.body().orEmpty().mapNotNull { dto ->
            val numericId = dto.id.toLongOrNull() ?: return@mapNotNull null
            GrimmoryLibrary(
                id = numericId,
                name = dto.name,
                bookCount = dto.bookCount ?: 0,
                allowedFormats = dto.allowedFormats.orEmpty(),
                paths = emptyList(),
            )
        })
    }

    private suspend fun browse(
        facets: List<String>,
        query: String?,
        sort: String,
        page: Int,
        size: Int,
    ): Response<GrimmoryBrowsePage<LegacyBookloreBookDto>> =
        api.getBooksPage(facets = facets, query = query, sort = sort, page = page, size = size.coerceIn(1, GRIMMORY_MAX_PAGE_SIZE))

    private fun GrimmoryBrowsePage<LegacyBookloreBookDto>.toBookPage(
        connectionId: String,
        serverUrl: String,
        fallbackLibraryId: String?,
    ) = BookSummaryPage(
        items = content.flatMap { it.toBookSummaries(connectionId, serverUrl, fallbackLibraryId) },
        page = page.number,
        totalPages = page.totalPages,
        totalElements = page.totalElements,
        hasNext = page.hasNext,
    )

    private fun LegacyBookloreBookDto.toBookSummaries(
        connectionId: String,
        serverUrl: String,
        fallbackLibraryId: String?,
    ): List<BookSummary> {
        val primaryFileType = primaryFile?.bookType
        val mediaType = primaryFileTypeToMediaType(primaryFileType)
        val hasAudio = mediaType == AppMediaType.AUDIOBOOK ||
            alternativeFormats.orEmpty().any { isGrimmoryAudioType(it.bookType ?: it.fileExtension) } ||
            metadata?.audiobookCoverUpdatedOn != null
        val hasEbook = mediaType == AppMediaType.EBOOK ||
            alternativeFormats.orEmpty().any { isGrimmoryEbookType(it.bookType ?: it.fileExtension) }

        val metadataTitle = listOfNotNull(title, metadata?.title, name)
            .firstOrNull { it.isNotBlank() } ?: "Untitled"
        val resolvedTitle = if (mediaType == AppMediaType.AUDIOBOOK) {
            titleFromPrimaryFileName(primaryFile?.fileName) ?: metadataTitle
        } else {
            metadataTitle
        }
        val summary = BookSummary(
            id = id,
            connectionId = connectionId,
            source = BookSource.GRIMMORY,
            title = resolvedTitle,
            authors = metadata?.authors.orEmpty(),
            thumbnailUrl = resolveCoverUrl(serverUrl, metadata?.thumbnailUrl, id, mediaType),
            seriesName = metadata?.seriesName,
            seriesNumber = metadata?.seriesNumber,
            readProgress = grimmoryPercentFraction(catalogReadProgress()) ?: 0f,
            readStatus = parseReadStatus(readStatus),
            serverReadStatus = readStatus?.uppercase(),
            personalRating = personalRating?.div(2f),
            primaryFileType = primaryFileType,
            mediaType = mediaType,
            addedOn = parseLegacyDate(addedOn),
            lastReadTime = parseLegacyDate(lastReadTime),
            isPhysical = isPhysical == true,
            libraryId = libraryId ?: fallbackLibraryId,
            hideFromContinue = readStatus.equals("ABANDONED", ignoreCase = true),
            hasAudio = hasAudio,
            hasEbook = hasEbook,
            publishedDate = metadata?.publishedDate,
            goodreadsRating = metadata?.goodreadsRating,
            narrator = metadata?.narrator,
            publisher = metadata?.publisher,
            categories = metadata?.categories.orEmpty(),
            language = metadata?.language,
            isbn13 = metadata?.isbn13 ?: metadata?.isbn10,
            pageCount = metadata?.pageCount,
        )
        if (mediaType != AppMediaType.EBOOK || !hasAudio) return listOf(summary)
        return listOf(
            summary,
            summary.copy(
                id = grimmoryCompanionAudiobookId(id),
                thumbnailUrl = resolveCoverUrl(serverUrl, null, id, AppMediaType.AUDIOBOOK),
                primaryFileType = "AUDIOBOOK",
                mediaType = AppMediaType.AUDIOBOOK,
                hasAudio = true,
                hasEbook = true,
            ),
        )
    }

    private fun parseLegacyDate(value: String?): Long {
        if (value.isNullOrBlank()) return 0L
        return runCatching { java.time.Instant.parse(value).toEpochMilli() }
            .recoverCatching {
                java.time.LocalDate.parse(value)
                    .atStartOfDay()
                    .toInstant(java.time.ZoneOffset.UTC)
                    .toEpochMilli()
            }
            .recoverCatching { value.toLong() }
            .getOrDefault(0L)
    }

    suspend fun getSeriesBooks(
        connectionId: String,
        seriesName: String,
        page: Int = 0,
        size: Int = 30,
        libraryId: Long? = null,
    ): Result<BookSummaryPage> = withConnection(connectionId) {
        val facets = listOfNotNull(
            grimmoryFacet("series", seriesName),
            libraryId?.let { grimmoryFacet("library", it) },
        ).let { if (it.size == 1 && ',' in seriesName) it + it else it }
        val resp = browse(facets, query = null, sort = "seriesNumber", page = page, size = size)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val body = resp.body() ?: return@withConnection Result.failure(Exception("Empty body"))
        Result.success(body.toBookPage(connectionId, serverUrl(connectionId), libraryId?.toString()))
    }

    suspend fun getShelves(connectionId: String): Result<List<GrimmoryShelf>> {
        val key = "shelves:$connectionId"
        val networkResult = try {
            withConnection(connectionId) {
                val resp = api.getShelves()
                if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
                val shelves = resp.body().orEmpty().mapNotNull { it.toModel() }
                cache.write(key, json.encodeToString(ListSerializer(GrimmoryShelf.serializer()), shelves))
                Result.success(shelves)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
        if (networkResult.isSuccess) return networkResult
        return cachedShelves(key, GrimmoryShelf.serializer())?.let { Result.success(it) } ?: networkResult
    }

    suspend fun getMagicShelves(connectionId: String): Result<List<GrimmoryMagicShelf>> {
        val key = "magic_shelves:$connectionId"
        val networkResult = try {
            withConnection(connectionId) {
                val resp = api.getMagicShelves()
                if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
                val shelves = resp.body().orEmpty().mapNotNull { it.toModel() }
                cache.write(key, json.encodeToString(ListSerializer(GrimmoryMagicShelf.serializer()), shelves))
                Result.success(shelves)
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
        if (networkResult.isSuccess) return networkResult
        return cachedShelves(key, GrimmoryMagicShelf.serializer())?.let { Result.success(it) } ?: networkResult
    }

    private suspend fun <T> cachedShelves(key: String, serializer: KSerializer<T>): List<T>? =
        cache.read(key, TTL_LONG)?.let { entry ->
            runCatching {
                json.decodeFromString(ListSerializer(serializer), entry.payloadJson)
            }.getOrNull()
        }

    suspend fun getMagicShelfBooks(
        connectionId: String,
        magicShelfId: Long,
        page: Int = 0,
        size: Int = 30,
    ): Result<BookSummaryPage> = withConnection(connectionId) {
        val resp = browse(listOf(grimmoryFacet("shelf", "magic:$magicShelfId")), query = null, sort = "-addedOn", page = page, size = size)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val body = resp.body() ?: return@withConnection Result.failure(Exception("Empty body"))
        Result.success(body.toBookPage(connectionId, serverUrl(connectionId), fallbackLibraryId = null))
    }

    suspend fun invalidateAllCaches() = cache.invalidate(prefix = null)

    private fun serverUrl(connectionId: String): String =
        connectionRegistry.getConnectionsSync().find { it.id == connectionId }?.serverUrl
            ?: error("Connection $connectionId not found")

    private suspend fun <T> withConnection(connectionId: String, block: suspend () -> Result<T>): Result<T> {
        val conn = connectionRegistry.connections.first().find { it.id == connectionId }
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
        return withContext(ConnectionScope.asContextElement(conn.id)) {
            runSuspendCatching { block() }.getOrElse { Result.failure(it) }
        }
    }

    private fun ShelfDto.toModel() = id.toLongOrNull()?.let { shelfId ->
        GrimmoryShelf(id = shelfId, name = name, icon = icon, bookCount = bookCount ?: 0, publicShelf = publicShelf)
    }

    private fun MagicShelfDto.toModel() = id.toLongOrNull()?.let { shelfId ->
        GrimmoryMagicShelf(id = shelfId, name = name, icon = icon, iconType = iconType, publicShelf = isPublic)
    }

    private fun primaryFileTypeToMediaType(primaryFileType: String?): AppMediaType {
        return when (primaryFileType?.uppercase()) {
            "AUDIOBOOK", "MP3", "M4A", "M4B", "FLAC", "OGG", "OPUS", "WAV" -> AppMediaType.AUDIOBOOK
            else -> AppMediaType.EBOOK
        }
    }

    private fun parseReadStatus(raw: String?): ReadStatus {
        return when (raw?.uppercase()) {
            "READ", "COMPLETED" -> ReadStatus.COMPLETED
            "IN_PROGRESS", "READING", "RE_READING", "STARTED" -> ReadStatus.IN_PROGRESS
            "ON_HOLD", "PAUSED", "PARTIALLY_READ" -> ReadStatus.ON_HOLD
            else -> ReadStatus.UNREAD
        }
    }

    companion object {
        private const val TTL_LONG = 24L * 60 * 60 * 1000
    }
}
