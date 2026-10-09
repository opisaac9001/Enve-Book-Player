package com.enve.audiobookshelf

import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations

import android.util.Log
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.provider.LibraryAccessRevocations
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.PodcastShow
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.audiobookshelf.api.AudiobookshelfApi
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.core.data.util.runSuspendCatching
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import com.enve.audiobookshelf.dto.*
import com.enve.audiobookshelf.listening.AbsCrossProviderHistory
import com.enve.audiobookshelf.listening.AbsListeningEntry
import com.enve.audiobookshelf.listening.AbsLocalListeningStore
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.dto.AbsLoginRequest
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

private const val TAG = "AudiobookshelfRepo"
private const val HTTP_FORBIDDEN = 403

internal fun mergeAbsMediaProgress(
    items: List<AbsLibraryItemDto>,
    progressEntries: List<AbsMediaProgressDto>,
): List<AbsLibraryItemDto> {
    val progressByItemId = progressEntries
        .mapNotNull { progress -> progress.libraryItemId?.let { it to progress } }
        .toMap()
    return items.map { item ->
        item.copy(mediaProgress = progressByItemId[item.id] ?: item.mediaProgress)
    }
}

@Singleton
class AudiobookshelfRepository @Inject constructor(
    private val api: AudiobookshelfApi,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
    private val vault: CredentialVault,
    private val httpClient: okhttp3.OkHttpClient,
    @ApplicationContext private val context: android.content.Context,
    private val ebookPositions: AbsEbookPositionResolver,
    private val libraryRevocations: LibraryAccessRevocations,
    private val localListening: AbsLocalListeningStore,
    private val progressWrites: com.enve.core.data.sync.AudiobookProgressWriteCoordinator,
    private val bookCache: com.enve.core.data.local.BookCacheDao,
    private val pendingProgress: com.enve.core.data.local.PendingProgressPushDao,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore = com.enve.core.data.local.ProfileServerSyncStore(context, locations),
) {
    suspend fun getCollections(libraryId: String): Result<List<AbsCollectionDto>> = runSuspendCatching {
        val response = api.getCollections(libraryId)
        if (!response.isSuccessful) error("Collections request failed: HTTP ${response.code()}")
        val body = response.body() ?: error("Collections response is empty")
        if (body.results == null && body.collections == null) error("Collections response has no list")
        if (body.items.size >= 500) error("Collections response may be incomplete")
        body.items
    }

    suspend fun setCollectionBook(book: Book, name: String, saved: Boolean): Result<Unit> = runSuspendCatching {
        val libraryId = book.libraryId ?: error("Book has no Audiobookshelf library")
        val collection = getCollections(libraryId).getOrThrow().firstOrNull { it.name.equals(name, ignoreCase = true) }
        if (collection == null) {
            if (!saved) return@runSuspendCatching
            val created = api.createCollection(AbsCreateCollectionRequest(libraryId, name, listOf(book.id)))
            if (!created.isSuccessful) error("Create collection failed: HTTP ${created.code()}")
            return@runSuspendCatching
        }
        val ids = collection.books?.map(AbsCollectionBookDto::id) ?: error("Collection membership is missing")
        if ((book.id in ids) == saved) return@runSuspendCatching
        val response = if (saved) api.addCollectionBook(collection.id, AbsCollectionBookRequest(book.id))
        else api.removeCollectionBook(collection.id, book.id)
        if (!response.isSuccessful) error("Update collection failed: HTTP ${response.code()}")
    }

    private fun scopedServerUrlAndToken(): Pair<String, String?> {
        connectionRegistry.getScopedConnectionSync()?.let { connection ->
            val token = vault.get(CredentialVault.accessTokenKey(connection.id))
                ?: vault.get(CredentialVault.passwordKey(connection.id))
                ?: prefs.getAccessTokenSync()
            return connection.serverUrl to token
        }
        return (prefs.getServerUrlSync() ?: "") to prefs.getAccessTokenSync()
    }

    fun currentAccessToken(): String? = scopedServerUrlAndToken().second?.takeIf { it.isNotBlank() }
    private val jsonSerializer = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Serializable
    private data class AbsLibraryCachePayload(
        val serverUrl: String,
        val savedAt: Long,
        val libraries: List<Library> = emptyList(),
    )

    @Serializable
    private data class AbsLaneCachePayload(
        val serverUrl: String,
        val lane: String,
        val savedAt: Long,
        val books: List<Book> = emptyList(),
    )

    private fun cacheFileForLibraries(serverUrl: String): java.io.File {
        val cacheDir = java.io.File(locations.cacheDirectory, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "libraries_abs_${safeServer}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForLane(serverUrl: String, lane: String): java.io.File {
        val cacheDir = java.io.File(locations.cacheDirectory, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "lane_abs_v2_${safeServer}_${lane}.json"
        return java.io.File(cacheDir, name)
    }

    private suspend fun loadLibrariesFromDisk(serverUrl: String): List<Library>? = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val file = cacheFileForLibraries(normalizedUrl)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<AbsLibraryCachePayload>(file.readText())
            if (payload.serverUrl.trimEnd('/') != normalizedUrl) return@runCatching null

            if (System.currentTimeMillis() - payload.savedAt > 86400_000) return@runCatching null
            payload.libraries
        }.getOrNull()
    }

    private suspend fun saveLibrariesToDisk(serverUrl: String, libraries: List<Library>) = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val payload = AbsLibraryCachePayload(
                serverUrl = normalizedUrl,
                savedAt = System.currentTimeMillis(),
                libraries = libraries,
            )
            cacheFileForLibraries(normalizedUrl).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun forgetForbiddenLibrary(serverUrl: String, libraryId: String) {
        Log.i(TAG, "ABS library $libraryId is no longer accessible; dropping it until the library list refreshes")
        withContext(Dispatchers.IO) {
            runCatching {
                val file = cacheFileForLibraries(serverUrl)
                if (file.exists()) {
                    val payload = jsonSerializer.decodeFromString<AbsLibraryCachePayload>(file.readText())
                    val remaining = payload.copy(libraries = payload.libraries.filterNot { it.id == libraryId })
                    file.writeText(jsonSerializer.encodeToString(remaining))
                }
            }
            cacheFileForLane(serverUrl, "recently-added").delete()
        }
        connectionRegistry.getScopedConnectionSync()?.let { libraryRevocations.revoke(it.id, libraryId) }
    }

    private suspend fun loadLaneFromDisk(serverUrl: String, lane: String): List<Book>? = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val file = cacheFileForLane(normalizedUrl, lane)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<AbsLaneCachePayload>(file.readText())
            if (payload.serverUrl.trimEnd('/') != normalizedUrl || payload.lane != lane) return@runCatching null

            if (System.currentTimeMillis() - payload.savedAt > 1800_000) return@runCatching null
            payload.books.normalizeCachedAbsMediaTypes()
        }.getOrNull()
    }

    private suspend fun saveLaneToDisk(serverUrl: String, lane: String, books: List<Book>) = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val payload = AbsLaneCachePayload(
                serverUrl = normalizedUrl,
                lane = lane,
                savedAt = System.currentTimeMillis(),
                books = books,
            )
            cacheFileForLane(normalizedUrl, lane).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private fun List<Book>.normalizeCachedAbsMediaTypes(): List<Book> = map { book ->
        if (book.source == BookSource.AUDIOBOOKSHELF &&
            book.mediaType == AppMediaType.EBOOK &&
            (book.audioTracks.isNotEmpty() || book.hasAudio)
        ) {
            book.copy(mediaType = AppMediaType.AUDIOBOOK)
        } else {
            book
        }
    }

    private fun resolveAgainstBase(serverUrl: String, pathOrUrl: String): String {
        val trimmed = pathOrUrl.trim()
        if (trimmed.startsWith("http://", ignoreCase = true) || trimmed.startsWith("https://", ignoreCase = true)) {
            return trimmed
        }
        val base = serverUrl.trimEnd('/')
        return if (trimmed.startsWith('/')) "$base$trimmed" else "$base/$trimmed"
    }

    suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runSuspendCatching {
        prefs.setActiveBookSource(BookSource.AUDIOBOOKSHELF)
        prefs.saveServerInfo(serverUrl.trimEnd('/'), username)
        invalidateListCaches()

        val response = api.login(AbsLoginRequest(username, password))
        if (!response.isSuccessful) error("Audiobookshelf login failed: HTTP ${response.code()}")
        val body = response.body() ?: error("Audiobookshelf login returned an empty response")
        val accessToken = body.user?.accessToken ?: body.user?.token ?: body.accessToken
        val refreshToken = body.user?.refreshToken ?: body.refreshToken
        if (accessToken.isNullOrBlank()) error("Audiobookshelf login succeeded but no token was returned")
        prefs.saveAuth(accessToken, refreshToken)
    }

    private val absOauthRedirectUri = com.enve.core.auth.OAuthRedirectUris.AUDIOBOOKSHELF

    private val rawClient: okhttp3.OkHttpClient by lazy {
        httpClient.newBuilder()
            .also { b ->
                b.interceptors().removeAll { true }
                b.networkInterceptors().removeAll { true }
            }
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }

    data class OauthPreflightResult(val authUrl: String, val cookieHeader: String?)

    suspend fun oauthPreflight(serverUrl: String, challenge: String, state: String): Result<OauthPreflightResult> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val base = serverUrl.trimEnd('/')
            val url = "$base/auth/openid".toHttpUrlOrNull()
                ?: error("Invalid server URL")
            val builder = url.newBuilder()
                .addQueryParameter("code_challenge", challenge)
                .addQueryParameter("code_challenge_method", "S256")
                .addQueryParameter("redirect_uri", absOauthRedirectUri)

                .addQueryParameter("callback", absOauthRedirectUri)
                .addQueryParameter("client_id", "Enve-App")
                .addQueryParameter("response_type", "code")
                .addQueryParameter("scope", "openid")
                .addQueryParameter("state", state)
            val request = okhttp3.Request.Builder().url(builder.build()).get().build()
            rawClient.newCall(request).execute().use { resp ->
                if (resp.code !in 300..399) {
                    val body = resp.body?.string()?.take(200).orEmpty()
                    error("Preflight returned HTTP ${resp.code}${if (body.isNotBlank()) ": $body" else ""}")
                }
                val location = resp.header("Location") ?: resp.header("location")
                    ?: error("Preflight 3xx response missing Location header")

                val cookieHeader = resp.headers("Set-Cookie")
                    .mapNotNull { it.substringBefore(';').trim().takeIf { v -> v.isNotEmpty() } }
                    .joinToString("; ")
                    .takeIf { it.isNotBlank() }
                OauthPreflightResult(authUrl = location, cookieHeader = cookieHeader)
            }
        }
    }

    suspend fun oauthExchangeCode(
        serverUrl: String,
        code: String,
        state: String,
        verifier: String,
        username: String?,
        cookieHeader: String?,
    ): Result<String> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val base = serverUrl.trimEnd('/')
            val url = "$base/auth/openid/callback".toHttpUrlOrNull()
                ?: error("Invalid server URL")
            val finalUrl = url.newBuilder()
                .addQueryParameter("code", code)
                .addQueryParameter("state", state)
                .addQueryParameter("code_verifier", verifier)
                .build()
            val requestBuilder = okhttp3.Request.Builder()
                .url(finalUrl)
                .get()
                .header("Accept", "application/json")
                .header("x-return-tokens", "true")
            if (!cookieHeader.isNullOrBlank()) {
                requestBuilder.header("Cookie", cookieHeader)
            }
            val request = requestBuilder.build()
            rawClient.newCall(request).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    error("Token exchange HTTP ${resp.code}${if (body.isNotBlank()) ": ${body.take(200)}" else ""}")
                }
                if (body.isBlank()) error("Token exchange returned empty body")
                val parsed = jsonSerializer.decodeFromString(
                    com.enve.core.data.remote.dto.AbsLoginResponse.serializer(),
                    body,
                )
                val accessToken = parsed.user?.accessToken
                    ?: parsed.user?.token
                    ?: parsed.accessToken
                    ?: error("Token exchange succeeded but no access token returned")
                val refreshToken = parsed.user?.refreshToken ?: parsed.refreshToken

                prefs.setActiveBookSource(BookSource.AUDIOBOOKSHELF)
                val effectiveUsername = parsed.user?.username ?: username.orEmpty()
                prefs.saveServerInfo(base, effectiveUsername)
                prefs.saveAuth(accessToken, refreshToken)
                invalidateListCaches()
                effectiveUsername
            }
        }
    }

    suspend fun getLibraries(): Result<List<Library>> = runSuspendCatching {
        val normalizedUrl = scopedServerUrlAndToken().first.trimEnd('/')

        val cached = loadLibrariesFromDisk(normalizedUrl)
        if (!cached.isNullOrEmpty()) return@runSuspendCatching cached

        val response = api.getLibraries()
        if (!response.isSuccessful) error("Failed to fetch ABS libraries: HTTP ${response.code()}")
        val body = response.body() ?: error("ABS libraries returned an empty body")

        val libs = body.libraries.filter {
            it.mediaType == "book" || it.mediaType == "audiobook" || it.mediaType == "podcast"
        }.map { dto ->
            Library(
                id = dto.id,
                name = dto.name,
                bookCount = 0
            )
        }

        saveLibrariesToDisk(normalizedUrl, libs)
        libs
    }

    suspend fun getBooks(
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc",
    ): Result<List<Book>> = runSuspendCatching {
        val normalizedUrl = scopedServerUrlAndToken().first.trimEnd('/')

        val targetLibraryIds = libraryId?.let { listOf(it) } ?: getLibraries().getOrThrow().map { it.id }
        if (targetLibraryIds.isEmpty()) return@runSuspendCatching emptyList()

        val pages = coroutineScope {
            targetLibraryIds.map { targetLibraryId ->
                async {
                    fetchAbsBooksPage(
                        libraryId = targetLibraryId,
                        serverUrl = normalizedUrl,
                        page = page,
                        size = size,
                        sort = sort,
                        dir = dir,
                    )
                }
            }.awaitAll()
        }
        sortAbsBooks(pages.flatten().distinctBy { it.id }, sort, dir)
    }

    private suspend fun fetchAbsBooksPage(
        libraryId: String,
        serverUrl: String,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): List<Book> {
        val response = api.getLibraryItems(
            libraryId = libraryId,
            limit = size,
            page = page,
            sort = absSortField(sort),
            desc = if (dir.equals("desc", ignoreCase = true)) 1 else 0,
        )
        if (response.code() == HTTP_FORBIDDEN) {
            forgetForbiddenLibrary(serverUrl, libraryId)
            return emptyList()
        }
        if (!response.isSuccessful) {
            throw IllegalStateException("ABS library page failed: HTTP ${response.code()}")
        }
        val body = response.body() ?: throw IllegalStateException("ABS library page returned an empty body")
        return body.items.mapNotNull {
            mapAbsItemToBook(it, libraryId, serverUrl, fetchDetail = false)
        }
    }

    suspend fun getBooksPage(
        connectionId: String,
        libraryId: String,
        page: Int = 0,
        size: Int = 50,
        sort: String = "media.metadata.title",
        dir: String = "asc",
    ): Result<com.enve.core.data.model.BookSummaryPage> = runSuspendCatching {
        val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
        val response = api.getLibraryItems(
            libraryId = libraryId,
            limit = size,
            page = page,
            minified = 1,
            sort = sort,
            desc = if (dir == "desc") 1 else 0,
        )
        if (response.code() == HTTP_FORBIDDEN) forgetForbiddenLibrary(serverUrl, libraryId)
        if (!response.isSuccessful) error("HTTP ${response.code()}")
        val body = response.body() ?: error("Empty body")
        val items = body.items.map { dto -> mapAbsItemToBookSummary(dto, libraryId, connectionId, serverUrl) }
        val total = body.total ?: items.size
        val pageSize = body.limit?.takeIf { it > 0 } ?: size
        val totalPages = if (pageSize > 0) ((total + pageSize - 1) / pageSize) else 1
        com.enve.core.data.model.BookSummaryPage(
            items = items,
            page = page,
            totalPages = totalPages,
            totalElements = total.toLong(),
            hasNext = (page + 1) < totalPages,
        )
    }

    suspend fun updateBookMetadata(book: Book, metadata: ProviderMetadataUpdate): Result<Unit> = runSuspendCatching {
        val response = api.updateMetadata(
            itemId = book.id,
            request = AbsMetadataUpdateRequest(metadata = metadata.toAbsMetadataUpdatePayload()),
        )
        if (!response.isSuccessful) error("ABS metadata update failed: HTTP ${response.code()}")
    }

    suspend fun matchAllLibraryMetadata(libraryId: String): Result<Unit> = runSuspendCatching {
        val response = api.matchAllLibraryItems(libraryId)
        if (!response.isSuccessful) error("ABS metadata refresh failed: HTTP ${response.code()}")
    }

    private fun mapAbsItemToBookSummary(
        dto: AbsLibraryItemDto,
        libraryId: String,
        connectionId: String,
        serverUrl: String,
    ): com.enve.core.data.model.BookSummary {
        val media = dto.media
        val meta = media?.metadata
        val title = meta?.title?.takeIf { it.isNotBlank() } ?: "(Untitled)"
        val authors = meta?.authors?.mapNotNull { it.name }
            ?: listOfNotNull(meta?.authorName?.takeIf { it.isNotBlank() })
        val hasAudio = hasAbsAudio(media)
        val hasEbook = hasAbsEbook(media)
        val mediaType = resolveAbsMediaType(dto)
        val progressFraction = (dto.mediaProgress?.progress ?: 0f).coerceIn(0f, 1f)
        val readStatus = when {
            dto.mediaProgress?.resolvedIsFinished == true -> com.enve.core.data.model.ReadStatus.COMPLETED
            progressFraction > 0f -> com.enve.core.data.model.ReadStatus.IN_PROGRESS
            else -> com.enve.core.data.model.ReadStatus.UNREAD
        }
        val series = absSeriesEntries(meta?.seriesName).firstOrNull()
        return com.enve.core.data.model.BookSummary(
            id = dto.id,
            connectionId = connectionId,
            source = BookSource.AUDIOBOOKSHELF,
            title = title,
            authors = authors,
            thumbnailUrl = "$serverUrl/api/items/${dto.id}/cover",
            seriesName = series?.name,
            seriesNumber = series?.sequence,
            readProgress = progressFraction,
            readStatus = readStatus,
            mediaType = mediaType,
            primaryFileType = when (mediaType) {
                AppMediaType.EBOOK -> media?.ebookFormat?.uppercase()
                AppMediaType.AUDIOBOOK -> "AUDIOBOOK"
                else -> null
            },
            addedOn = dto.addedAt ?: 0L,
            lastReadTime = dto.mediaProgress?.lastUpdate ?: 0L,
            libraryId = libraryId,
            hasAudio = hasAudio,
            hasEbook = hasEbook,
        )
    }

    private suspend fun mapAbsItemToBook(
        dto: AbsLibraryItemDto,
        libraryId: String,
        serverUrl: String,
        fetchDetail: Boolean = true,
    ): Book? {
        val id = dto.id
        val initialMediaType = resolveAbsMediaType(dto)
        val initialDurationSec = resolveAbsDurationSeconds(dto.media, dto.mediaProgress)
        val detail = if (fetchDetail && shouldFetchAbsItemDetail(dto, initialMediaType, initialDurationSec)) {
            runSuspendCatching { api.getItemDetail(id).body() }.getOrNull()
        } else {
            null
        }
        val media = detail?.media ?: dto.media
        val progress = dto.mediaProgress ?: detail?.mediaProgress
        val title = media?.metadata?.title?.takeIf { it.isNotBlank() } ?: "(Untitled)"

        val mediaType = resolveAbsMediaType(detail ?: dto)

        val author = media?.metadata?.authorName
            ?: media?.metadata?.authors?.firstOrNull()?.name

        val series = absSeriesEntries(media?.metadata?.seriesName).firstOrNull()

        val durationSec = resolveAbsDurationSeconds(media, progress)

        val progressFraction = progress?.progress ?: 0f
        val positionSec = normalizeAbsCurrentTimeSeconds(
            rawCurrentTime = progress?.currentTime,
            durationSec = durationSec,
            progressFraction = progressFraction,
            fallbackSec = null,
        )
        val lastReadTime = progress?.lastUpdate?.takeIf { it > 0L } ?: 0L

        val chapters = if (fetchDetail && mediaType == AppMediaType.AUDIOBOOK) {
            media?.chapters
                ?.mapIndexed { idx, ch ->
                    val startSec = (ch.start ?: ch.startOffset ?: 0.0).toLong()
                    val endSec = ch.end?.toLong()
                    Chapter(
                        index = idx,
                        title = ch.title ?: "Chapter ${idx + 1}",
                        startTime = startSec,
                        endTime = endSec ?: (startSec + 60L),
                    )
                } ?: emptyList()
        } else {
            emptyList()
        }

        val tracks = media?.audioFiles.orEmpty()
            .mapNotNull { mapAudioFileToTrack(id, it, serverUrl) }
            .sortedBy { it.index }
        val primaryFileType = when (mediaType) {
            AppMediaType.EBOOK -> media?.ebookFormat
                ?: media?.ebookFile?.ebookFormat
                ?: media?.ebookFile?.metadata?.ext?.trimStart('.')
            AppMediaType.AUDIOBOOK, AppMediaType.PODCAST -> tracks.firstOrNull()
                ?.fileName
                ?.substringAfterLast('.', missingDelimiterValue = "")
                ?.takeIf { it.isNotBlank() }
        }?.uppercase()

        return Book(
            id = id,
            title = title,
            author = author,
            narrator = media?.metadata?.narratorName,
            description = media?.metadata?.description,
            coverUrl = "${serverUrl.trimEnd('/')}/api/items/$id/cover",
            duration = durationSec,
            currentTime = positionSec,
            readProgress = progressFraction,
            source = BookSource.AUDIOBOOKSHELF,
            mediaType = mediaType,
            libraryId = libraryId,
            seriesName = series?.name,
            seriesNumber = series?.sequence,
            addedOn = dto.addedAt ?: 0L,
            lastReadTime = lastReadTime,
            chapters = chapters,
            audioTracks = tracks,
            hasAudio = hasAbsAudio(media),
            hasEbook = hasAbsEbook(media),
            isFinished = progress?.resolvedIsFinished == true,
            primaryFileType = primaryFileType,
        )
    }

    private fun shouldFetchAbsItemDetail(
        dto: AbsLibraryItemDto,
        mediaType: AppMediaType,
        durationSec: Long,
    ): Boolean {
        val media = dto.media
        if (media?.metadata?.title.isNullOrBlank()) return true
        return when (mediaType) {
            AppMediaType.AUDIOBOOK,
            AppMediaType.PODCAST -> durationSec <= 0L || media.audioFiles.isNullOrEmpty()
            AppMediaType.EBOOK -> media.ebookFile == null
        }
    }

    private fun resolveAbsDurationSeconds(
        media: AbsMediaDto?,
        progress: AbsMediaProgressDto? = null,
    ): Long {
        val audioFileDurationSec = media?.audioFiles.orEmpty()
            .sumOf { it.duration?.takeIf { duration -> duration > 0.0 } ?: 0.0 }
            .takeIf { it > 0.0 }
            ?.toLong()

        progress?.duration?.takeIf { it > 0.0 }?.let { return it.toLong() }
        media?.duration?.takeIf { it > 0.0 }?.let { return it.toLong() }
        return audioFileDurationSec ?: 0L
    }

    private suspend fun mapAbsItemWithProgress(
        dto: AbsLibraryItemDto,
        libraryId: String,
        serverUrl: String,
        fetchDetail: Boolean = true,
    ): Book? {
        val base = mapAbsItemToBook(dto, libraryId, serverUrl, fetchDetail = fetchDetail) ?: return null
        val progress = dto.mediaProgress
        if (progress == null) return base
        return applyAbsMediaProgress(base, progress)
    }

    private fun mapAudioFileToTrack(itemId: String, file: AbsAudioFileDto, serverUrl: String): AudioTrack? {
        val fileId = file.ino ?: return null
        val index = file.index ?: 0
        val filename = file.metadata?.filename ?: "Track ${index + 1}"
        return AudioTrack(
            index = index,
            fileName = filename,
            title = filename,
            durationMs = ((file.duration ?: 0.0) * 1000).toLong(),
            fileSizeBytes = file.metadata?.size ?: 0L,
            fileId = fileId,
            contentUrl = resolveAgainstBase(serverUrl, "/api/items/$itemId/file/$fileId"),
        )
    }

    private fun mapPlaybackTrackToTrack(track: AbsPlaybackTrackDto, serverUrl: String): AudioTrack? {
        val url = track.contentUrl?.takeIf { it.isNotBlank() } ?: return null
        val index = track.index ?: 0
        val title = track.title ?: track.metadata?.filename ?: "Track ${index + 1}"
        val startOffsetMs = ((track.startOffset ?: 0.0) * 1000).toLong()
        return AudioTrack(
            index = index,
            fileName = track.metadata?.filename ?: title,
            title = title,
            durationMs = ((track.duration ?: 0.0) * 1000).toLong(),
            fileSizeBytes = track.metadata?.size ?: 0L,
            cumulativeStartMs = startOffsetMs,
            contentUrl = resolveAgainstBase(serverUrl, url),
        )
    }

    suspend fun getEbookDownloadUrl(bookId: String): String? {
        val serverUrl = scopedServerUrlAndToken().first.takeIf { it.isNotBlank() } ?: return null
        return "${serverUrl.trimEnd('/')}/api/items/$bookId/ebook"
    }

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        if (!serverSync.isEnabled) return@runSuspendCatching ProviderPlaybackSession("", getAudioTracks(book).getOrThrow(), fetchChapters(book).getOrThrow())
        val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')

        val episodeId = book.episodeId
        val sessionResponse = if (episodeId != null) {
            api.startEpisodePlaybackSession(book.absItemId, episodeId, AbsPlaybackStartRequest(localListening.deviceInfo))
        } else {
            api.startPlaybackSession(book.id, AbsPlaybackStartRequest(localListening.deviceInfo))
        }
        if (!sessionResponse.isSuccessful) error("Failed to start Audiobookshelf playback: HTTP ${sessionResponse.code()}")
        val session = sessionResponse.body() ?: error("Audiobookshelf playback session returned an empty response")
        val sessionTracks = session.audioTracks
            .mapNotNull { mapPlaybackTrackToTrack(it, serverUrl) }
            .sortedBy { it.index }
        val chapters = session.chapters.toChapters()
        ProviderPlaybackSession(
            sessionId = session.id,
            audioTracks = sessionTracks,
            chapters = chapters,
            serverCurrentTimeSec = normalizeAbsCurrentTimeSeconds(
                rawCurrentTime = session.currentTime,
                durationSec = session.duration?.takeIf { it > 0.0 }?.toLong() ?: 0L,
                progressFraction = null,
                fallbackSec = null,
            ),
        )
    }

    suspend fun syncPlaybackSession(
        sessionId: String,
        currentTimeSec: Long,
        timeListenedMs: Long,
        durationSec: Long,
    ): Result<Unit> {
        return submitPlaybackSessionUpdate(
            sessionId = sessionId,
            currentTimeSec = currentTimeSec,
            timeListenedMs = timeListenedMs,
            durationSec = durationSec,
            close = false,
        )
    }

    suspend fun closePlaybackSession(
        sessionId: String,
        currentTimeSec: Long,
        timeListenedMs: Long,
        durationSec: Long,
    ): Result<Unit> {
        return submitPlaybackSessionUpdate(
            sessionId = sessionId,
            currentTimeSec = currentTimeSec,
            timeListenedMs = timeListenedMs,
            durationSec = durationSec,
            close = true,
        )
    }

    private suspend fun submitPlaybackSessionUpdate(
        sessionId: String,
        currentTimeSec: Long,
        timeListenedMs: Long,
        durationSec: Long,
        close: Boolean,
    ): Result<Unit> = progressWrites.ordered(BookSource.AUDIOBOOKSHELF, ConnectionScope.getConnectionId()) {
        runSuspendCatching {
            requireProgressConnection(ConnectionScope.getConnectionId())
            val syncStartedAt = System.currentTimeMillis()
            if (!serverSync.isEnabled) return@runSuspendCatching
            val request = AbsPlaybackSessionUpdateRequest(
                currentTime = currentTimeSec.coerceAtLeast(0).toDouble(),
                timeListened = (timeListenedMs.coerceAtLeast(0) / 1000.0),
                duration = durationSec.coerceAtLeast(0).toDouble(),
            )
            if (!serverSync.accepts(syncStartedAt)) return@runSuspendCatching
            val response = if (close) {
                api.closePlaybackSession(sessionId, request)
            } else {
                api.syncPlaybackSession(sessionId, request)
            }
            if (!response.isSuccessful) {
                val action = if (close) "close" else "sync"
                error("Audiobookshelf playback session $action failed: HTTP ${response.code()}")
            }
        }
    }

    suspend fun recordLocalListening(book: Book, currentTimeSec: Long, durationSec: Long, listenedMs: Long) {
        if (!serverSync.isEnabled) return
        localListening.record(
            AbsListeningEntry(
                connectionId = ConnectionScope.getConnectionId().orEmpty(),
                libraryItemId = book.absItemId,
                episodeId = book.episodeId,
                displayTitle = book.title,
                displayAuthor = book.author,
                durationSec = durationSec.toDouble(),
                currentTimeSec = currentTimeSec.toDouble(),
                listenedMs = listenedMs,
            ),
        )
    }

    suspend fun verifiedHistoryAccountAndItem(book: Book): Result<String> = runSuspendCatching {
        require(book.source == BookSource.AUDIOBOOKSHELF && book.mediaType == AppMediaType.AUDIOBOOK && book.episodeId == null)
        val accountId = getMe().getOrThrow().id?.takeIf(String::isNotBlank)
            ?: error("Audiobookshelf account has no stable ID")
        itemMedia(book)
        accountId
    }

    suspend fun removePendingCrossProviderHistory(sourceBookKey: String) {
        localListening.removeCrossProviderHistory(sourceBookKey)
    }

    suspend fun historyProgress(itemId: String): Result<AbsMediaProgressDto?> = runSuspendCatching {
        if (!serverSync.isEnabled) return@runSuspendCatching null
        val response = api.getProgress(itemId)
        if (response.code() == 404) return@runSuspendCatching null
        if (!response.isSuccessful) error("Audiobookshelf history progress failed: HTTP ${response.code()}")
        response.body()
    }

    suspend fun enqueueCrossProviderHistory(session: com.enve.audiobookshelf.listening.AbsLocalListeningSession) {
        if (!serverSync.accepts(session.startedAtMs)) return
        localListening.enqueueHistory(session)
    }

    private suspend fun requireProgressConnection(connectionId: String?) {
        if (connectionId == null) return
        check(connectionRegistry.connections.first().any { it.id == connectionId && it.source == BookSource.AUDIOBOOKSHELF && it.enabled }) {
            "Requested provider connection is unavailable"
        }
    }

    suspend fun uploadLocalListening(): Result<Int> = progressWrites.ordered(BookSource.AUDIOBOOKSHELF, ConnectionScope.getConnectionId()) {
        runSuspendCatching {
            requireProgressConnection(ConnectionScope.getConnectionId())
            val syncStartedAt = System.currentTimeMillis()
            if (!serverSync.isEnabled) return@runSuspendCatching 0
            val accountId = getMe().getOrNull()?.id?.takeIf(String::isNotBlank)
            val pending = localListening.pending(ConnectionScope.getConnectionId().orEmpty(), accountId)
                .filter { serverSync.accepts(it.startedAtMs) }
            if (pending.isEmpty()) return@runSuspendCatching 0
            val progressByItem = pending
                .map { it.libraryItemId }.distinct()
                .associateWith { historyProgress(it) }
            val episodeProgress = pending.filter { it.episodeId != null }.associate { session ->
                "${session.libraryItemId}:${session.episodeId}" to runSuspendCatching {
                    val response = api.getEpisodeProgress(session.libraryItemId, checkNotNull(session.episodeId))
                    if (!response.isSuccessful && response.code() != 404) error("Episode history progress is unavailable")
                    response.body()
                }
            }
            val ready = AbsCrossProviderHistory.readyForUpload(pending, progressByItem).filter { session ->
                if (session.episodeId == null) progressByItem[session.libraryItemId]?.isSuccess == true
                else episodeProgress["${session.libraryItemId}:${session.episodeId}"]?.isSuccess == true
            }
            val dirtyPositionByItem = ready.filter { it.accountId == null && it.episodeId == null }
                .map { it.libraryItemId }.distinct().associateWith { id ->
                    val connectionId = ConnectionScope.getConnectionId()
                    val dirty = pendingProgress.get(id, BookSource.AUDIOBOOKSHELF.name, connectionId.orEmpty())
                    if (dirty?.mediaType == "AUDIOBOOK") {
                        bookCache.getByCacheKey("${connectionId ?: BookSource.AUDIOBOOKSHELF.name}:$id")?.currentTime?.toDouble()
                    } else null
                }
            if (ready.isEmpty()) return@runSuspendCatching 0
            if (!serverSync.accepts(syncStartedAt)) return@runSuspendCatching 0
            requireProgressConnection(ConnectionScope.getConnectionId())
            val response = api.syncLocalSessions(
                AbsLocalSessionsRequest(
                    sessions = ready.map { session ->
                        AbsLocalSessionDto(
                            id = session.id,
                            libraryItemId = session.libraryItemId,
                            episodeId = session.episodeId,
                            mediaType = if (session.episodeId != null) "podcast" else "book",
                            displayTitle = session.displayTitle,
                            displayAuthor = session.displayAuthor,
                            duration = session.durationSec,
                            date = session.day,
                            dayOfWeek = session.dayOfWeek,
                            timeListening = session.timeListeningSec,
                            currentTime = AbsCrossProviderHistory.uploadPosition(
                                session,
                                if (session.episodeId != null) episodeProgress["${session.libraryItemId}:${session.episodeId}"]?.getOrNull()?.currentTime
                                else progressByItem[session.libraryItemId]?.getOrNull()?.currentTime,
                                dirtyPositionByItem[session.libraryItemId],
                            ),
                            startedAt = session.startedAtMs,
                            updatedAt = session.updatedAtMs,
                        )
                    },
                    deviceInfo = localListening.deviceInfo,
                ),
            )
            if (!response.isSuccessful) error("Audiobookshelf local session upload failed: HTTP ${response.code()}")
            val results = response.body()?.results.orEmpty()
            val succeeded = results.filter { it.success }.mapTo(HashSet()) { it.id }
            val rejected = results.filter { !it.success && it.error != null }.mapTo(HashSet()) { it.id }
            localListening.markUploaded(ready.filter { it.id in succeeded }, rejected)
            succeeded.size
        }
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runSuspendCatching {
        val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
        val media = itemMedia(book)
        val files = book.episodeId?.let { episodeId ->
            listOfNotNull(media.episodes?.firstOrNull { it.id == episodeId }?.audioFile)
        } ?: media.audioFiles.orEmpty()
        files.mapNotNull { mapAudioFileToTrack(book.absItemId, it, serverUrl) }.sortedBy { it.index }
    }

    suspend fun fetchChapters(book: Book): Result<List<Chapter>> = runSuspendCatching {
        if (book.episodeId != null) return@runSuspendCatching emptyList()
        itemMedia(book).chapters.orEmpty().toChapters()
    }

    // Reads the item instead of POSTing /play: ABS closes the device's open session on every /play.
    private suspend fun itemMedia(book: Book): AbsMediaDto {
        val response = api.getItemDetail(book.absItemId)
        if (!response.isSuccessful) error("Audiobookshelf item lookup failed: HTTP ${response.code()}")
        return response.body()?.media ?: error("Audiobookshelf item has no media")
    }

    suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> = progressWrites.ordered(BookSource.AUDIOBOOKSHELF, ConnectionScope.getConnectionId() ?: book.connectionId) {
        runSuspendCatching {
            requireProgressConnection(ConnectionScope.getConnectionId() ?: book.connectionId)
            val syncStartedAt = System.currentTimeMillis()
            if (!serverSync.isEnabled) return@runSuspendCatching
            val finished = progressFraction >= FINISHED_PROGRESS_THRESHOLD
            val request = AbsProgressUpdateRequest(
                currentTime = currentTimeSec.toDouble().coerceAtLeast(0.0),
                duration = book.duration.takeIf { it > 0 }?.toDouble(),
                progress = progressFraction.coerceIn(0f, 1f),
                isFinished = finished.takeIf { it || currentTimeSec <= 0 },
            )
            val episodeId = book.episodeId
            if (!serverSync.accepts(syncStartedAt)) return@runSuspendCatching
            val response = if (episodeId != null) {
                api.updateEpisodeProgress(book.absItemId, episodeId, request)
            } else {
                api.updateProgress(book.id, request)
            }
            if (!response.isSuccessful) error("Audiobookshelf progress sync failed: HTTP ${response.code()}")
        }
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<com.enve.core.data.sync.SyncSnapshot?> = runSuspendCatching {
        if (!serverSync.isEnabled) return@runSuspendCatching null
        val episodeId = book.episodeId
        val response = if (episodeId != null) api.getEpisodeProgress(book.absItemId, episodeId) else api.getProgress(book.id)
        val progress = response.body()
        if (!response.isSuccessful || progress == null) return@runSuspendCatching null
        val pct = progress.progress?.coerceIn(0f, 1f)?.takeIf { it > 0f } ?: return@runSuspendCatching null
        com.enve.core.data.sync.SyncSnapshot(
            percentage = pct,
            positionMs = progress.currentTime?.let { (it * 1000).toLong() },
            source = "Audiobookshelf",
        )
    }

    suspend fun fetchEbookProgress(book: Book): Result<com.enve.core.data.sync.SyncSnapshot?> = runSuspendCatching {
        if (!serverSync.isEnabled) return@runSuspendCatching null
        val response = api.getProgress(book.id)
        val progress = response.body()
        if (!response.isSuccessful || progress == null) null else ebookPositions.ebookSnapshot(book, progress)
    }

    suspend fun getPodcastShow(show: Book): Result<PodcastShow> = runSuspendCatching {
        val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
        coroutineScope {
            val me = async { getMe().getOrThrow() }
            val response = api.getExpandedItem(show.id)
            if (!response.isSuccessful) error("Audiobookshelf podcast fetch failed: HTTP ${response.code()}")
            val item = response.body() ?: error("Audiobookshelf podcast returned an empty body")
            mapAbsPodcastShow(item, me.await().mediaProgress, serverUrl)
        }
    }

    suspend fun getMe(): Result<com.enve.audiobookshelf.dto.AbsMeResponse> = runSuspendCatching {
        val resp = api.getMe()
        if (!resp.isSuccessful) error("Audiobookshelf /api/me failed: HTTP ${resp.code()}")
        resp.body() ?: com.enve.audiobookshelf.dto.AbsMeResponse()
    }

    suspend fun getProgressForBooks(books: List<Book>): List<Book> {
        if (!serverSync.isEnabled) return books
        val response = api.getMe()
        check(response.isSuccessful) { "ABS user progress failed: HTTP ${response.code()}" }
        val progress = checkNotNull(response.body()) { "ABS user progress returned an empty body" }
            .mediaProgress.filter { it.episodeId == null }
            .groupBy { it.libraryItemId }
            .mapValues { (_, entries) -> entries.maxBy { it.lastUpdate ?: 0L } }
        return books.mapNotNull { book -> progress[book.id]?.let { applyAbsMediaProgress(book, it) } }
    }

    suspend fun createBookmark(
        itemId: String,
        request: com.enve.audiobookshelf.dto.AbsBookmarkRequest,
    ): com.enve.audiobookshelf.dto.AbsBookmarkDto {
        val resp = api.createBookmark(itemId, request)
        if (!resp.isSuccessful) error("ABS createBookmark failed: HTTP ${resp.code()}")
        return resp.body() ?: error("ABS createBookmark returned empty body")
    }

    suspend fun updateBookmark(
        itemId: String,
        request: com.enve.audiobookshelf.dto.AbsBookmarkRequest,
    ): com.enve.audiobookshelf.dto.AbsBookmarkDto {
        val resp = api.updateBookmark(itemId, request)
        if (!resp.isSuccessful) error("ABS updateBookmark failed: HTTP ${resp.code()}")
        return resp.body() ?: error("ABS updateBookmark returned empty body")
    }

    suspend fun deleteBookmark(itemId: String, timeSec: Double) {
        val resp = api.deleteBookmark(itemId, timeSec)
        if (!resp.isSuccessful && resp.code() != 404) error("ABS deleteBookmark failed: HTTP ${resp.code()}")
    }

    suspend fun syncEbookProgress(bookId: String, percentage: Float, locator: String?): Result<Unit> = runSuspendCatching {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return@runSuspendCatching
        if (!serverSync.accepts(syncStartedAt)) return@runSuspendCatching
        ebookPositions.pushEbookProgress(bookId, percentage, locator)
    }

    suspend fun getBooksInProgress(allowCachedFallback: Boolean = true): Result<List<Book>> {
        if (!serverSync.isEnabled) return Result.success(emptyList())
        val result = runSuspendCatching {
            val normalizedUrl = scopedServerUrlAndToken().first.trimEnd('/')

            val itemsResponse = api.getItemsInProgress()
            check(itemsResponse.isSuccessful) { "ABS in-progress items failed: HTTP ${itemsResponse.code()}" }
            val items = checkNotNull(itemsResponse.body()?.items) { "ABS in-progress items returned an empty body" }

            val meResponse = api.getMe()
            check(meResponse.isSuccessful) { "ABS user progress failed: HTTP ${meResponse.code()}" }
            val progressEntries = checkNotNull(meResponse.body()?.mediaProgress) { "ABS user progress returned an empty body" }

            val accessibleLibraryIds = getLibraries().getOrNull()?.mapTo(HashSet()) { it.id }
            val books = mergeAbsMediaProgress(items, progressEntries)
                .filter { item -> accessibleLibraryIds == null || item.libraryId == null || item.libraryId in accessibleLibraryIds }
                .mapNotNull { item ->
                    mapAbsItemWithProgress(item, item.libraryId ?: "", normalizedUrl, fetchDetail = false)
                }
                .filter {
                    it.readProgress > 0.001f ||
                        (it.epubProgress ?: 0f) > 0.001f ||
                        it.currentTime > 0L
                }
                .filter { !it.isFinished && !it.hideFromContinue }

            saveLaneToDisk(normalizedUrl, "in-progress", books)
            books
        }
        if (result.isSuccess || !allowCachedFallback) return result
        val cached = runSuspendCatching {
            loadLaneFromDisk(scopedServerUrlAndToken().first.trimEnd('/'), "in-progress")
        }.getOrNull()
        return cached?.let { Result.success(it) } ?: result
    }

    suspend fun getContinueListening(): Result<List<Book>> =
        getBooksInProgress().map { books ->
            books
                .filter { it.mediaType == AppMediaType.AUDIOBOOK || it.mediaType == AppMediaType.PODCAST }
                .take(20)
        }

    suspend fun getContinueReading(): Result<List<Book>> {
        return getBooksInProgress().map { books ->
            books
                .filter { it.mediaType == AppMediaType.EBOOK || (it.epubProgress ?: 0f) > 0f }
                .take(20)
        }
    }

    suspend fun getRecentlyAdded(): Result<List<Book>> = runSuspendCatching {
        val normalizedUrl = scopedServerUrlAndToken().first.trimEnd('/')
        loadLaneFromDisk(normalizedUrl, "recently-added")?.let { return@runSuspendCatching it }

        val libraries = getLibraries().getOrThrow()
        val pages = coroutineScope {
            libraries.map { library ->
                async {
                    val response = api.getLibraryItems(
                        libraryId = library.id,
                        limit = 20,
                        sort = "addedAt",
                        desc = 1,
                        page = 0,
                    )
                    if (response.code() == HTTP_FORBIDDEN) {
                        forgetForbiddenLibrary(normalizedUrl, library.id)
                        return@async emptyList()
                    }
                    check(response.isSuccessful) { "ABS recently added failed: HTTP ${response.code()}" }
                    val body = checkNotNull(response.body()) { "ABS recently added returned an empty body" }
                    body.items.mapNotNull {
                        mapAbsItemToBook(it, library.id, normalizedUrl, fetchDetail = false)
                    }
                }
            }.awaitAll()
        }
        val unique = pages.flatten().distinctBy { it.id }.sortedByDescending { it.addedOn }.take(20)

        saveLaneToDisk(normalizedUrl, "recently-added", unique)
        unique
    }

    fun invalidateListCaches() {
        val cacheDirectory = java.io.File(locations.cacheDirectory, "book-index-cache")
        cacheDirectory.listFiles()?.forEach { file ->
            if (file.name.startsWith("books_abs_") ||
                file.name.startsWith("libraries_abs_") ||
                file.name.startsWith("lane_abs_")) {
                file.delete()
            }
        }
    }

    suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> = runSuspendCatching {
        val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
        val librariesResp = api.getLibraries()
        val libraries = librariesResp.body()?.libraries.orEmpty()
            .filter { it.mediaType == "book" || it.mediaType == "audiobook" }
        val merged = mutableMapOf<String, com.enve.core.data.remote.dto.SeriesSummaryDto>()
        for (library in libraries) {
            val resp = runSuspendCatching { api.getSeriesInLibrary(library.id) }.getOrNull() ?: continue
            if (!resp.isSuccessful) continue
            resp.body()?.series.orEmpty().forEach { s ->
                val key = s.name.lowercase()
                val existing = merged[key]
                val incomingIds = s.books?.map { it.id }.orEmpty()
                val combinedIds = ((existing?.bookIds.orEmpty()) + incomingIds).distinct()
                val coverBookId = combinedIds.firstOrNull()
                merged[key] = com.enve.core.data.remote.dto.SeriesSummaryDto(
                    name = s.name,
                    bookCount = (existing?.bookCount ?: 0) + incomingIds.size,
                    bookIds = combinedIds,
                    coverUrl = coverBookId?.let { "$serverUrl/api/items/$it/cover" },
                )
            }
        }
        merged.values.toList()
    }

    suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> = runSuspendCatching {
        val librariesResp = api.getLibraries()
        val libraries = librariesResp.body()?.libraries.orEmpty()
            .filter { it.mediaType == "book" || it.mediaType == "audiobook" }
        val merged = mutableMapOf<String, com.enve.core.data.remote.dto.AuthorSummaryDto>()
        for (library in libraries) {
            val resp = runSuspendCatching { api.getAuthorsInLibrary(library.id) }.getOrNull() ?: continue
            if (!resp.isSuccessful) continue
            resp.body()?.authors.orEmpty().forEach { a ->
                val existing = merged[a.id]
                merged[a.id] = com.enve.core.data.remote.dto.AuthorSummaryDto(
                    id = a.id,
                    name = a.name,
                    bookCount = (existing?.bookCount ?: 0) + (a.numBooks ?: 0),
                )
            }
        }
        merged.values.toList()
    }
}

private val Book.absItemId: String
    get() = podcastLibraryItemId ?: id

private fun List<AbsChapter>.toChapters(): List<Chapter> = mapIndexed { index, chapter ->
    Chapter(
        index = index,
        title = chapter.title ?: "Chapter ${index + 1}",
        startTime = (chapter.start ?: chapter.startOffset ?: 0.0).toLong(),
        endTime = (chapter.end ?: chapter.start ?: 0.0).toLong(),
    )
}.filter { it.endTime > it.startTime }

private fun absSortField(sort: String): String = when (sort.lowercase()) {
    "addedon", "addedat" -> "addedAt"
    "title", "media.metadata.title" -> "media.metadata.title"
    else -> sort
}

private fun sortAbsBooks(books: List<Book>, sort: String, dir: String): List<Book> {
    val comparator = when (absSortField(sort)) {
        "media.metadata.title" -> compareBy<Book> { it.title.lowercase() }
        else -> compareBy { it.addedOn }
    }
    return if (dir.equals("desc", ignoreCase = true)) {
        books.sortedWith(comparator.reversed())
    } else {
        books.sortedWith(comparator)
    }
}

internal fun resolveAbsMediaType(dto: AbsLibraryItemDto): AppMediaType {
    val mediaType = dto.mediaType?.lowercase().orEmpty()
    val hasAudio = hasAbsAudio(dto.media)
    val hasEbook = hasAbsEbook(dto.media)

    return when (mediaType) {
        "podcast" -> AppMediaType.PODCAST
        "ebook" -> AppMediaType.EBOOK
        "audiobook" -> AppMediaType.AUDIOBOOK
        else -> when {
            hasAudio -> AppMediaType.AUDIOBOOK
            hasEbook -> AppMediaType.EBOOK
            else -> AppMediaType.AUDIOBOOK
        }
    }
}

private fun hasAbsAudio(media: AbsMediaDto?): Boolean =
    !media?.audioFiles.isNullOrEmpty() ||
        (media?.numTracks ?: 0) > 0 ||
        (media?.numAudioFiles ?: 0) > 0

private fun hasAbsEbook(media: AbsMediaDto?): Boolean =
    media?.ebookFile != null || !media?.ebookFormat.isNullOrBlank()

internal fun ProviderMetadataUpdate.toAbsMetadataUpdatePayload(): AbsMetadataUpdatePayload {
    val published = publishedDate.clean()
    return AbsMetadataUpdatePayload(
        title = title.clean(),
        subtitle = subtitle.clean(),
        authors = author.toAbsAuthors(),
        narrators = narrator.toNameList(),
        series = seriesName.clean()?.let { name ->
            listOf(AbsSeriesPayload(name = name, sequence = seriesNumber.clean()))
        } ?: emptyList(),
        genres = categories.map { it.trim() }.filter { it.isNotEmpty() }.ifEmpty { null },
        publishedYear = published?.take(4)?.takeIf { it.length == 4 && it.all(Char::isDigit) },
        publishedDate = published,
        publisher = publisher.clean(),
        description = description.clean(),
        isbn = isbn13.clean(),
        language = language.clean(),
    )
}

private fun String?.toAbsAuthors(): List<AbsAuthorPayload> =
    toNameList().map { AbsAuthorPayload(name = it) }

private fun String?.toNameList(): List<String> =
    clean()
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        .orEmpty()

private fun String?.clean(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
