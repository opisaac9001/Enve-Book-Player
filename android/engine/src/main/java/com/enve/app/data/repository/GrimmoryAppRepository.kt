package com.enve.app.data.repository

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.BookSummary
import com.enve.core.data.model.GrimmoryAuthorDetail
import com.enve.core.data.model.BookSummaryPage
import com.enve.core.data.model.GrimmoryFilterOptions
import com.enve.core.data.model.GrimmoryGroupPage
import com.enve.core.data.model.GrimmoryLibrary
import com.enve.core.data.model.GrimmoryMagicShelf
import com.enve.core.data.model.GrimmoryShelf
import com.enve.core.data.model.GrimmoryUser
import com.enve.core.data.model.BrowseGroup
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.LanguageOption
import com.enve.core.data.model.NamedCount
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReadStatus
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.remote.GrimmoryAppApi
import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.remote.dto.grimmoryapp.AppAuthorSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppBookDetailDto
import com.enve.app.data.remote.dto.grimmoryapp.AppBookSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppFilterOptionsDto
import com.enve.app.data.remote.dto.grimmoryapp.AppLibrarySummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppMagicShelfSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppPageDto
import com.enve.app.data.remote.dto.grimmoryapp.AppSeriesSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppShelfSummaryDto
import com.enve.app.data.remote.dto.grimmoryapp.AppUserInfoDto
import com.enve.app.data.remote.dto.grimmoryapp.AudiobookInfoDto
import com.enve.app.data.remote.dto.grimmoryapp.UpdateRatingRequest
import com.enve.app.data.remote.dto.grimmoryapp.UpdateStatusRequest
import com.enve.app.data.repository.grimmory.companionAudiobook
import com.enve.app.data.repository.grimmory.grimmoryCompanionAudiobookId
import com.enve.app.data.repository.grimmory.grimmoryServerBookId
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
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GrimmoryAppRepository @Inject constructor(
    private val api: GrimmoryAppApi,

    private val legacyApi: GrimmoryApi,
    private val connectionRegistry: ConnectionRegistry,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val cache: GrimmoryDiskCache,
    private val offlineAudio: OfflineDownloadManager,
    private val offlineComic: ComicOfflineService,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val connectionMutex = Mutex()

    private enum class ApiTier { APP, LEGACY }
    private val connectionTier = java.util.concurrent.ConcurrentHashMap<String, ApiTier>()
    private fun tierFor(connectionId: String): ApiTier =
        connectionTier[connectionId] ?: ApiTier.APP

    val downloadedIds: Flow<Set<String>> = combine(
        offlineAudio.downloadedBookIds,
        offlineComic.downloadedBookIds,
    ) { audio, comic -> audio + comic }

    fun isDownloaded(bookId: String): Boolean =
        offlineAudio.isDownloaded(bookId) || offlineComic.isDownloaded(bookId)

    suspend fun getLibraries(connectionId: String): Result<List<GrimmoryLibrary>> {
        val key = "libraries:$connectionId"
        cache.read(key, TTL_LONG)?.let {
            runCatching {
                json.decodeFromString(ListSerializer(GrimmoryLibrary.serializer()), it.payloadJson)
            }.getOrNull()?.takeIf { cached -> cached.isNotEmpty() }?.let { cached ->
                return Result.success(cached)
            }
        }
        return withConnection(connectionId) {
            val libs: List<GrimmoryLibrary>? = if (tierFor(connectionId) == ApiTier.APP) {
                val resp = runSuspendCatching { api.getLibraries() }.getOrNull()
                when {
                    resp == null -> {
                        android.util.Log.w("GrimmoryAppRepo", "getLibraries APP threw for $connectionId; trying legacy")
                        null
                    }
                    resp.isSuccessful -> {
                        val mapped = resp.body().orEmpty().map { it.toModel() }
                        if (shouldUseLegacyGrimmoryCatalog(resp.code(), mapped.size)) {
                            android.util.Log.i("GrimmoryAppRepo", "getLibraries APP returned no libraries for $connectionId; trying legacy")
                            null
                        } else {
                            mapped
                        }
                    }
                    else -> {
                        android.util.Log.i("GrimmoryAppRepo", "getLibraries APP returned HTTP ${resp.code()} for $connectionId; trying legacy")
                        null
                    }
                }
            } else null

            val resolved = libs ?: run {
                val legacyResp = legacyApi.getLibrariesLegacy()
                if (!legacyResp.isSuccessful) {
                    android.util.Log.w("GrimmoryAppRepo", "getLibrariesLegacy HTTP ${legacyResp.code()} for $connectionId")
                    return@withConnection Result.failure(Exception("Grimmory catalog unavailable (legacy HTTP ${legacyResp.code()})"))
                }
                connectionTier[connectionId] = ApiTier.LEGACY
                val raw = legacyResp.body().orEmpty()
                val mapped = raw.mapNotNull { dto ->
                    val numericId = dto.id.toLongOrNull() ?: run {
                        android.util.Log.w("GrimmoryAppRepo", "Skipping legacy library with non-numeric id=${dto.id} on $connectionId")
                        return@mapNotNull null
                    }
                    GrimmoryLibrary(
                        id = numericId,
                        name = dto.name,
                        bookCount = dto.bookCount ?: 0,
                        allowedFormats = dto.allowedFormats.orEmpty(),
                        paths = emptyList(),
                    )
                }
                android.util.Log.i("GrimmoryAppRepo", "Legacy libraries on $connectionId: ${mapped.size} of ${raw.size} (kept those with numeric ids)")
                mapped
            }
            cache.write(key, json.encodeToString(ListSerializer(GrimmoryLibrary.serializer()), resolved))
            Result.success(resolved)
        }
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
        fileType: String? = null,
        authors: String? = null,
        language: String? = null,
        minRating: Int? = null,
        maxRating: Int? = null,
    ): Result<BookSummaryPage> = withConnection(connectionId) {
        val ctx = resolveContext(connectionId)

        val hasFilters = shelfId != null || status != null || !search.isNullOrBlank() ||
            fileType != null || authors != null || language != null || minRating != null || maxRating != null
        var appTierUnavailable = false

        if (tierFor(connectionId) == ApiTier.APP) {
            val appResp = runSuspendCatching {
                api.getBooks(
                    libraryId = libraryId,
                    shelfId = shelfId,
                    status = status?.toGrimmoryWireStatus(),
                    search = search?.takeIf { it.isNotBlank() },
                    fileType = fileType,
                    minRating = minRating,
                    maxRating = maxRating,
                    authors = authors,
                    language = language,
                    page = page,
                    size = size,
                    sort = sort,
                    dir = dir,
                )
            }.getOrNull()

            when {
                appResp == null -> {
                    android.util.Log.w("GrimmoryAppRepo", "getBooks APP threw for $connectionId lib=$libraryId; trying legacy")
                }
                appResp.isSuccessful -> {
                    val body = appResp.body()
                    if (page > 0 || hasFilters || !shouldUseLegacyGrimmoryCatalog(appResp.code(), body?.content?.size)) {
                        if (body == null) return@withConnection Result.failure(Exception("Empty body"))
                        return@withConnection Result.success(body.toBookPage(connectionId, ctx.serverUrl))
                    }
                    appTierUnavailable = true
                    android.util.Log.i("GrimmoryAppRepo", "getBooks APP returned an empty first page for $connectionId lib=$libraryId; trying legacy")
                }
                else -> {

                    appTierUnavailable = appResp.code() == 404 || appResp.code() >= 500
                    android.util.Log.i("GrimmoryAppRepo", "getBooks APP HTTP ${appResp.code()} for $connectionId lib=$libraryId; trying legacy")
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
                val callResult = runSuspendCatching { legacyApi.getBooksLegacy(libId.toString(), legacyPage, pageSize) }
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
                    merged += dto.toBookSummariesFromLegacy(connectionId, ctx.serverUrl, libId.toString())
                }
                libraryTotal += list.size
                if (list.size < pageSize) break
                legacyPage++
            }
            android.util.Log.i("GrimmoryAppRepo", "Legacy /libraries/$libId/book yielded $libraryTotal books across ${legacyPage + 1} pages on $connectionId")
        }
        if (appTierUnavailable) connectionTier[connectionId] = ApiTier.LEGACY

        val filtered = if (!search.isNullOrBlank()) {
            val needle = search.lowercase()
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
        val resp = legacyApi.getLibrariesLegacy()
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

    private fun com.enve.app.data.remote.dto.LegacyBookloreBookDto.toBookSummariesFromLegacy(
        connectionId: String,
        serverUrl: String,
        fallbackLibraryId: String,
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
            thumbnailUrl = resolveAppCoverUrl(serverUrl, metadata?.thumbnailUrl, id, mediaType),
            seriesName = metadata?.seriesName,
            seriesNumber = metadata?.seriesNumber,
            readProgress = (readProgress ?: 0f).coerceIn(0f, 1f),
            readStatus = parseReadStatus(readStatus),
            serverReadStatus = readStatus?.uppercase(),
            personalRating = null,
            primaryFileType = primaryFileType,
            mediaType = mediaType,
            addedOn = parseLegacyDate(addedOn),
            lastReadTime = parseLegacyDate(lastReadTime),
            isPhysical = false,
            libraryId = libraryId ?: fallbackLibraryId,
            hideFromContinue = readStatus.equals("ABANDONED", ignoreCase = true),
            hasAudio = hasAudio,
            hasEbook = hasEbook,
            narrator = metadata?.narrator,
            publisher = metadata?.publisher,
            language = metadata?.language,
            isbn13 = metadata?.isbn13,
            pageCount = metadata?.pageCount,
        )
        if (mediaType != AppMediaType.EBOOK || !hasAudio) return listOf(summary)
        return listOf(
            summary,
            summary.copy(
                id = grimmoryCompanionAudiobookId(id),
                thumbnailUrl = resolveAppCoverUrl(serverUrl, null, id, AppMediaType.AUDIOBOOK),
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

    suspend fun getBookDetail(connectionId: String, bookId: String): Result<Book> = withConnection(connectionId) {
        val rawBookId = bookId.grimmoryServerBookId()
        val resp = api.getBookDetail(rawBookId)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val dto = resp.body() ?: return@withConnection Result.failure(Exception("Empty body"))
        val ctx = resolveContext(connectionId)
        val mapped = dto.toBook(connectionId, ctx.serverUrl)
        Result.success(if (rawBookId != bookId) mapped.companionAudiobook(ctx.serverUrl) ?: mapped else mapped)
    }

    suspend fun searchBooks(
        connectionId: String,
        query: String,
        page: Int = 0,
        size: Int = 30,
    ): Result<BookSummaryPage> = withConnection(connectionId) {
        val resp = api.searchBooks(query = query, page = page, size = size)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body()!!.toBookPage(connectionId, ctx.serverUrl))
    }

    suspend fun getSeriesPage(
        connectionId: String,
        libraryId: Long? = null,
        page: Int = 0,
        size: Int = 30,
        sort: String = "name",
        dir: String = "asc",
        search: String? = null,
        status: String? = null,
    ): Result<GrimmoryGroupPage> = withConnection(connectionId) {
        val resp = api.getSeries(
            page = page, size = size, sort = sort, dir = dir,
            libraryId = libraryId, search = search?.takeIf { it.isNotBlank() }, status = status,
        )
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val body = resp.body() ?: return@withConnection Result.failure(Exception("Empty body"))
        val ctx = resolveContext(connectionId)
        Result.success(body.toGroupPage { it.toBrowseGroup(ctx.serverUrl) })
    }

    suspend fun getSeriesBooks(
        connectionId: String,
        seriesName: String,
        page: Int = 0,
        size: Int = 30,
        libraryId: Long? = null,
    ): Result<BookSummaryPage> = withConnection(connectionId) {
        val resp = api.getSeriesBooks(
            seriesName = seriesName, page = page, size = size,
            libraryId = libraryId,
        )
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body()!!.toBookPage(connectionId, ctx.serverUrl))
    }

    suspend fun getAuthorsPage(
        connectionId: String,
        libraryId: Long? = null,
        page: Int = 0,
        size: Int = 30,
        sort: String = "name",
        dir: String = "asc",
        search: String? = null,
        hasPhoto: Boolean? = null,
    ): Result<GrimmoryGroupPage> = withConnection(connectionId) {
        val resp = api.getAuthors(
            page = page, size = size, sort = sort, dir = dir,
            libraryId = libraryId, search = search?.takeIf { it.isNotBlank() }, hasPhoto = hasPhoto,
        )
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body()!!.toGroupPage { it.toBrowseGroup(ctx.serverUrl) })
    }

    suspend fun getAuthorDetail(connectionId: String, authorId: String): Result<GrimmoryAuthorDetail> = withConnection(connectionId) {
        val resp = api.getAuthorDetail(authorId)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val dto = resp.body()!!
        Result.success(GrimmoryAuthorDetail(
            id = dto.id, name = dto.name, description = dto.description,
            asin = dto.asin, bookCount = dto.bookCount, hasPhoto = dto.hasPhoto,
        ))
    }

    suspend fun getFilterOptions(
        connectionId: String,
        libraryId: Long? = null,
    ): Result<GrimmoryFilterOptions> {
        val key = "filters:$connectionId:${libraryId ?: "all"}"
        cache.read(key, TTL_SHORT)?.let {
            runCatching {
                json.decodeFromString(GrimmoryFilterOptions.serializer(), it.payloadJson)
            }.getOrNull()?.let { return Result.success(it) }
        }
        return withConnection(connectionId) {
            val resp = api.getFilterOptions(libraryId = libraryId)
            if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
            val opts = resp.body()!!.toModel()
            cache.write(key, json.encodeToString(GrimmoryFilterOptions.serializer(), opts))
            Result.success(opts)
        }
    }

    suspend fun getShelves(connectionId: String): Result<List<GrimmoryShelf>> {
        val key = "shelves:$connectionId"
        val networkResult = try {
            withConnection(connectionId) {
                val resp = api.getShelves()
                if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
                val shelves = resp.body().orEmpty().map { it.toModel() }
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
                val shelves = resp.body().orEmpty().map { it.toModel() }
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
        val resp = api.getMagicShelfBooks(magicShelfId = magicShelfId, page = page, size = size)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body()!!.toBookPage(connectionId, ctx.serverUrl))
    }

    suspend fun getContinueListening(connectionId: String, limit: Int = 10): Result<List<BookSummary>> = withConnection(connectionId) {
        val resp = api.getContinueListening(limit)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body().orEmpty().flatMap { it.toBookSummaries(connectionId, ctx.serverUrl) })
    }

    suspend fun getContinueReading(connectionId: String, limit: Int = 10): Result<List<BookSummary>> = withConnection(connectionId) {
        val resp = api.getContinueReading(limit)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body().orEmpty().flatMap { it.toBookSummaries(connectionId, ctx.serverUrl) })
    }

    suspend fun getRecentlyAdded(connectionId: String, limit: Int = 10): Result<List<BookSummary>> = withConnection(connectionId) {
        val resp = api.getRecentlyAdded(limit)
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val ctx = resolveContext(connectionId)
        Result.success(resp.body().orEmpty().flatMap { it.toBookSummaries(connectionId, ctx.serverUrl) })
    }

    suspend fun getCurrentUser(connectionId: String): Result<GrimmoryUser> = withConnection(connectionId) {
        val resp = api.getCurrentUser()
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        val dto = resp.body()!!
        Result.success(GrimmoryUser(
            isAdmin = dto.isAdmin, canUpload = dto.canUpload, canDownload = dto.canDownload,
            canAccessBookdrop = dto.canAccessBookdrop, maxFileUploadSizeMb = dto.maxFileUploadSizeMb,
        ))
    }

    suspend fun updateReadStatus(connectionId: String, bookId: String, status: ReadStatus): Result<Unit> = withConnection(connectionId) {
        val resp = api.updateBookStatus(bookId.grimmoryServerBookId(), UpdateStatusRequest(status.toGrimmoryWireStatus()))
        if (resp.isSuccessful) Result.success(Unit) else Result.failure(Exception("HTTP ${resp.code()}"))
    }

    suspend fun updateRating(connectionId: String, bookId: String, rating: Int): Result<Unit> = withConnection(connectionId) {
        val serverId = bookId.grimmoryServerBookId().toLongOrNull()
            ?: return@withConnection Result.failure(Exception("Unrecognized Grimmory book id"))

        val resp = api.updateBookRating(UpdateRatingRequest(ids = listOf(serverId), rating = rating.coerceIn(1, 5) * 2))
        if (resp.isSuccessful) Result.success(Unit) else Result.failure(Exception("HTTP ${resp.code()}"))
    }

    suspend fun getAudiobookInfo(connectionId: String, bookId: String): Result<AudiobookInfoDto> = withConnection(connectionId) {
        val resp = api.getAudiobookInfo(bookId.grimmoryServerBookId())
        if (!resp.isSuccessful) return@withConnection Result.failure(Exception("HTTP ${resp.code()}"))
        Result.success(resp.body()!!)
    }

    fun coverUrl(serverUrl: String, bookId: String): String =
        "${serverUrl.trimEnd('/')}/api/v1/media/book/$bookId/cover"

    fun audiobookCoverUrl(serverUrl: String, bookId: String): String =
        "${serverUrl.trimEnd('/')}/api/v1/media/book/$bookId/audiobook-cover"

    suspend fun invalidateCachesFor(connectionId: String) {
        cache.invalidate("libraries:$connectionId")
        cache.invalidate("shelves:$connectionId")
        cache.invalidate("magic_shelves:$connectionId")
        cache.invalidate("filters:$connectionId")
    }

    suspend fun invalidateAllCaches() = cache.invalidate(prefix = null)

    private data class ResolvedContext(
        val connection: ProviderConnection,
        val serverUrl: String,
        val token: String,
    )

    private fun resolveContext(connectionId: String): ResolvedContext {
        val conn = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
            ?: error("Connection $connectionId not found")
        val token = vault.get(CredentialVault.accessTokenKey(connectionId))
            ?: vault.get(CredentialVault.passwordKey(connectionId))
            ?: ""
        return ResolvedContext(conn, conn.serverUrl, token)
    }

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
        return withContext(ConnectionScope.asContextElement(conn.id)) { block() }
    }

    private fun AppLibrarySummaryDto.toModel() = GrimmoryLibrary(
        id = id, name = name, bookCount = bookCount,
        allowedFormats = allowedFormats, paths = paths,
    )

    private fun AppShelfSummaryDto.toModel() = GrimmoryShelf(
        id = id, name = name, icon = icon, bookCount = bookCount, publicShelf = publicShelf,
    )

    private fun AppMagicShelfSummaryDto.toModel() = GrimmoryMagicShelf(
        id = id, name = name, icon = icon, iconType = iconType, publicShelf = publicShelf,
    )

    private fun AppPageDto<AppBookSummaryDto>.toBookPage(connectionId: String, serverUrl: String) = BookSummaryPage(
        items = content.flatMap { it.toBookSummaries(connectionId, serverUrl) },
        page = page, totalPages = totalPages, totalElements = totalElements, hasNext = hasNext,
    )

    private inline fun <DTO> AppPageDto<DTO>.toGroupPage(map: (DTO) -> BrowseGroup) = GrimmoryGroupPage(
        items = content.map(map),
        page = page, totalPages = totalPages, totalElements = totalElements, hasNext = hasNext,
    )

    private fun AppBookSummaryDto.toBookSummaries(connectionId: String, serverUrl: String): List<BookSummary> {
        val primaryType = primaryFile?.resolvedType ?: primaryFileType
        val mediaType = primaryFileTypeToMediaType(primaryType)
        val hasAudio = mediaType == AppMediaType.AUDIOBOOK || hasAudioFormat()
        val hasEbook = mediaType == AppMediaType.EBOOK || hasEbookFormat()
        val resolvedTitle = if (mediaType == AppMediaType.AUDIOBOOK) {
            titleFromPrimaryFileName(primaryFileName) ?: title
        } else {
            title
        }
        val summary = BookSummary(
            id = id,
            connectionId = connectionId,
            source = BookSource.GRIMMORY,
            title = resolvedTitle.ifBlank { "Untitled" },
            authors = authors,
            thumbnailUrl = resolveAppCoverUrl(serverUrl, thumbnailUrl, id, mediaType),
            seriesName = seriesName,
            seriesNumber = seriesNumber,
            readProgress = readProgress.coerceIn(0f, 1f),
            readStatus = parseReadStatus(readStatus),
            serverReadStatus = readStatus?.uppercase(),
            personalRating = personalRating?.div(2f),
            primaryFileType = primaryType,
            mediaType = mediaType,
            addedOn = addedOn,
            lastReadTime = lastReadTime,
            isPhysical = isPhysical,
            libraryId = libraryId?.toString(),
            hideFromContinue = readStatus.equals("ABANDONED", ignoreCase = true),
            hasAudio = hasAudio,
            hasEbook = hasEbook,
            publishedDate = publishedDate,
            goodreadsRating = goodreadsRating,
            narrator = narrator,
            publisher = publisher,
            categories = categories,
            language = language,
            isbn13 = isbn13 ?: isbn10,
            pageCount = pageCount,
        )
        if (mediaType != AppMediaType.EBOOK || !hasAudio) return listOf(summary)
        return listOf(
            summary,
            summary.copy(
                id = grimmoryCompanionAudiobookId(id),
                thumbnailUrl = resolveAppCoverUrl(serverUrl, null, id, AppMediaType.AUDIOBOOK),
                primaryFileType = "AUDIOBOOK",
                mediaType = AppMediaType.AUDIOBOOK,
                hasAudio = true,
                hasEbook = true,
            ),
        )
    }

    private fun AppBookSummaryDto.hasAudioFormat(): Boolean {
        val types = buildList {
            add(primaryFileType)
            add(primaryFile?.resolvedType)
            addAll(fileTypes)
            files.mapNotNull { it.resolvedType }.let { addAll(it) }
        }
        return types.any(::isGrimmoryAudioType) ||
            audiobookCoverUpdatedOn > 0L ||
            thumbnailUrl?.contains("/audiobook-", ignoreCase = true) == true
    }

    private fun AppBookSummaryDto.hasEbookFormat(): Boolean {
        val types = buildList {
            add(primaryFileType)
            add(primaryFile?.resolvedType)
            addAll(fileTypes)
            files.mapNotNull { it.resolvedType }.let { addAll(it) }
        }
        return types.any(::isGrimmoryEbookType)
    }

    private fun AppBookDetailDto.hasAudioFormat(): Boolean {
        val types = buildList {
            add(primaryFileType)
            addAll(fileTypes)
            files.mapNotNull { it.resolvedType }.let { addAll(it) }
        }
        return types.any(::isGrimmoryAudioType) ||
            audiobookProgress != null ||
            thumbnailUrl?.contains("/audiobook-", ignoreCase = true) == true
    }

    private fun AppBookDetailDto.hasEbookFormat(): Boolean {
        val types = buildList {
            add(primaryFileType)
            addAll(fileTypes)
            files.mapNotNull { it.resolvedType }.let { addAll(it) }
        }
        return types.any(::isGrimmoryEbookType) || epubProgress != null || pdfProgress != null || cbxProgress != null
    }

    private fun resolveAppCoverUrl(
        serverUrl: String,
        path: String?,
        bookId: String,
        mediaType: AppMediaType,
    ): String {
        val base = serverUrl.trimEnd('/')
        val resolvedPath = when {
            path.isNullOrBlank() -> fallbackCoverPath(bookId, mediaType)
            path.startsWith("http://") || path.startsWith("https://") ->
                return rewriteAbsoluteLegacyCoverUrl(path, mediaType)
            path.startsWith("/api/books/") -> rewriteLegacyCoverPath(path, mediaType)
            else -> path
        }
        return base + if (resolvedPath.startsWith('/')) resolvedPath else "/$resolvedPath"
    }

    private fun fallbackCoverPath(bookId: String, mediaType: AppMediaType): String =
        if (mediaType == AppMediaType.AUDIOBOOK) "/api/v1/media/book/$bookId/audiobook-thumbnail"
        else "/api/v1/media/book/$bookId/cover"

    private fun rewriteLegacyCoverPath(path: String, mediaType: AppMediaType): String {
        if (!path.startsWith("/api/books/")) return path
        val withoutPrefix = path.removePrefix("/api/books/")
        val slashIdx = withoutPrefix.indexOf('/')
        if (slashIdx < 0) return path
        val id = withoutPrefix.substring(0, slashIdx)
        val suffix = withoutPrefix.substring(slashIdx)
        return when (suffix) {
            "/cover" -> if (mediaType == AppMediaType.AUDIOBOOK) "/api/v1/media/book/$id/audiobook-thumbnail"
                else "/api/v1/media/book/$id/cover"
            "/thumbnail" -> if (mediaType == AppMediaType.AUDIOBOOK) "/api/v1/media/book/$id/audiobook-thumbnail"
                else "/api/v1/media/book/$id/thumbnail"
            "/audiobook-cover", "/audiobook-thumbnail" -> "/api/v1/media/book/$id$suffix"
            else -> "/api/v1/media/book/$id$suffix"
        }
    }

    private fun rewriteAbsoluteLegacyCoverUrl(url: String, mediaType: AppMediaType): String {
        val schemeEnd = url.indexOf("//").takeIf { it >= 0 } ?: return url
        val slashAfterHost = url.indexOf('/', schemeEnd + 2).takeIf { it >= 0 } ?: return url
        val rawPath = url.substring(slashAfterHost)
        val rewritten = rewriteLegacyCoverPath(rawPath, mediaType)
        return if (rewritten != rawPath) url.substring(0, slashAfterHost) + rewritten else url
    }

    private fun AppSeriesSummaryDto.toBrowseGroup(serverUrl: String): BrowseGroup {
        val coverBookId = coverBooks.firstOrNull()?.id
        val coverUrl = coverBookId?.let { coverUrl(serverUrl, it) }
        val secondary = if (booksRead > 0) "$booksRead of $bookCount read" else null
        return BrowseGroup(
            key = seriesName,
            name = seriesName,
            count = bookCount,
            coverUrl = coverUrl,
            secondary = secondary,
        )
    }

    private fun AppAuthorSummaryDto.toBrowseGroup(serverUrl: String): BrowseGroup {
        val photoUrl = if (hasPhoto) "${serverUrl.trimEnd('/')}/api/v1/media/author/$id/photo" else null
        return BrowseGroup(
            key = id,
            name = name,
            count = bookCount,
            coverUrl = photoUrl,
            secondary = null,
        )
    }

    private fun AppFilterOptionsDto.toModel() = GrimmoryFilterOptions(
        authors = authors.map { NamedCount(it.name, it.count) },
        narrators = narrators.map { NamedCount(it.name, it.count) },
        categories = categories.map { NamedCount(it.name, it.count) },
        languages = languages.map { LanguageOption(it.code, it.label, it.count) },
        readStatuses = readStatuses.map { NamedCount(it.name, it.count) },
        fileTypes = fileTypes.map { NamedCount(it.name, it.count) },
        publishers = publishers.map { NamedCount(it.name, it.count) },
    )

    private fun AppBookDetailDto.toBook(connectionId: String, serverUrl: String): Book {
        val primaryFile = files.firstOrNull { it.isPrimary == true || it.primary == true } ?: files.firstOrNull()
        val resolvedPrimaryFileType = primaryFile?.resolvedType ?: primaryFileType
        val mediaType = primaryFileTypeToMediaType(resolvedPrimaryFileType)
        val hasAudio = mediaType == AppMediaType.AUDIOBOOK || hasAudioFormat()
        val hasEbook = mediaType == AppMediaType.EBOOK || hasEbookFormat()
        val authorString = authors.joinToString(", ").takeIf { it.isNotBlank() }
        val downloaded = isDownloaded(id)
        val resolvedTitle = if (mediaType == AppMediaType.AUDIOBOOK) {
            titleFromPrimaryFileName(primaryFile?.fileName) ?: title
        } else {
            title
        }

        val unifiedProgress = audiobookProgress?.percentage
            ?: epubProgress?.percentage
            ?: pdfProgress?.percentage
            ?: cbxProgress?.percentage
            ?: readProgress
        return Book(
            id = id,
            title = resolvedTitle.ifBlank { "Untitled" },
            subtitle = subtitle,
            author = authorString,
            description = description,
            coverUrl = resolveAppCoverUrl(serverUrl, thumbnailUrl, id, mediaType),
            duration = 0L,
            currentTime = audiobookProgress?.let {

                (it.positionMs / 1000L)
            } ?: 0L,
            isFinished = parseReadStatus(readStatus) == ReadStatus.COMPLETED,
            source = BookSource.GRIMMORY,
            mediaType = mediaType,
            readStatus = parseReadStatus(readStatus),
            seriesName = seriesName,
            seriesNumber = seriesNumber,
            publisher = publisher,
            publishedDate = publishedDate,
            isbn13 = isbn13,
            language = language,
            pageCount = pageCount,
            categories = categories,
            personalRating = personalRating?.div(2f),
            goodreadsRating = goodreadsRating,
            primaryFileType = resolvedPrimaryFileType,
            libraryId = libraryId?.let { "$connectionId::$it" },
            libraryName = libraryName,
            connectionId = connectionId,
            addedOn = addedOn,
            lastReadTime = lastReadTime,
            readProgress = unifiedProgress.coerceIn(0f, 1f),
            epubProgress = epubProgress?.percentage,
            epubLocator = epubProgress?.cfi,
            readAlongAvailable = false,
            hasEbook = hasEbook,
            hasAudio = hasAudio,
            hideFromContinue = readStatus.equals("ABANDONED", ignoreCase = true),
            isDownloaded = downloaded,
            shelves = shelves.map { it.name },
        )
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

    fun extractChapters(info: AudiobookInfoDto): List<Chapter> = info.chapters.map { c ->
        Chapter(
            index = c.index,
            title = c.title ?: "Chapter ${c.index + 1}",
            startTime = c.startTimeMs / 1000L,
            endTime = c.endTimeMs / 1000L,
        )
    }

    fun buildAudioTracks(info: AudiobookInfoDto, serverUrl: String, bookId: String): List<AudioTrack> {
        val base = serverUrl.trimEnd('/')
        return if (info.tracks.isNotEmpty()) {
            info.tracks.map { t ->
                AudioTrack(
                    index = t.index,
                    fileName = t.fileName ?: t.title ?: "Track ${t.index + 1}",
                    title = t.title ?: t.fileName,
                    durationMs = t.durationMs ?: 0L,
                    fileSizeBytes = t.fileSizeBytes ?: 0L,
                    cumulativeStartMs = t.cumulativeStartMs ?: 0L,
                    contentUrl = "$base/api/v1/audiobooks/$bookId/track/${t.index}/stream",
                )
            }
        } else {

            listOf(
                AudioTrack(
                    index = 0,
                    fileName = info.title ?: "Audiobook",
                    title = info.title,
                    durationMs = info.durationMs,
                    contentUrl = "$base/api/v1/audiobooks/$bookId/stream",
                )
            )
        }
    }

    companion object {
        private const val TTL_SHORT = 5L * 60 * 1000
        private const val TTL_LONG = 24L * 60 * 60 * 1000
    }
}
