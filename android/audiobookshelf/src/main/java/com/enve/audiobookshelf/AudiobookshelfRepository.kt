package com.enve.audiobookshelf

import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.audiobookshelf.api.AudiobookshelfApi
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import com.enve.audiobookshelf.dto.*
import com.enve.core.data.remote.dto.AbsLoginRequest
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
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
) {

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
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "libraries_abs_${safeServer}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForLane(serverUrl: String, lane: String): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
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

    suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> {
        return try {
            prefs.setActiveBookSource(BookSource.AUDIOBOOKSHELF)
            prefs.saveServerInfo(serverUrl.trimEnd('/'), username)
            invalidateListCaches()

            val response = api.login(AbsLoginRequest(username, password))
            if (!response.isSuccessful) {
                return Result.failure(Exception("Audiobookshelf login failed: HTTP ${response.code()}"))
            }
            val body = response.body() ?: return Result.failure(Exception("Audiobookshelf login returned an empty response"))
            val accessToken = body.user?.accessToken ?: body.user?.token ?: body.accessToken
            val refreshToken = body.user?.refreshToken ?: body.refreshToken
            if (accessToken.isNullOrBlank()) {
                return Result.failure(Exception("Audiobookshelf login succeeded but no token was returned"))
            }
            prefs.saveAuth(accessToken, refreshToken)
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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
        runCatching {
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
        runCatching {
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

    suspend fun getLibraries(): Result<List<Library>> {
        return try {
            val serverUrl = scopedServerUrlAndToken().first
            val normalizedUrl = serverUrl.trimEnd('/')

            val cached = loadLibrariesFromDisk(normalizedUrl)
            if (!cached.isNullOrEmpty()) {
                return Result.success(cached)
            }

            val response = api.getLibraries()
            if (!response.isSuccessful) {
                return Result.failure(Exception("Failed to fetch ABS libraries: HTTP ${response.code()}"))
            }
            val body = response.body()
                ?: return Result.failure(IllegalStateException("ABS libraries returned an empty body"))

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
            Result.success(libs)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getBooks(
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "addedOn",
        dir: String = "desc",
    ): Result<List<Book>> {
        return try {
            val normalizedUrl = scopedServerUrlAndToken().first.trimEnd('/')

            val targetLibraryIds = if (libraryId != null) {
                listOf(libraryId)
            } else {
                getLibraries().getOrElse { return Result.failure(it) }.map { it.id }
            }

            if (targetLibraryIds.isEmpty()) return Result.success(emptyList())

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
            Result.success(sortAbsBooks(pages.flatten().distinctBy { it.id }, sort, dir))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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
    ): Result<com.enve.core.data.model.BookSummaryPage> {
        return try {
            val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
            val response = api.getLibraryItems(
                libraryId = libraryId,
                limit = size,
                page = page,
                minified = 1,
                sort = sort,
                desc = if (dir == "desc") 1 else 0,
            )
            if (!response.isSuccessful) return Result.failure(Exception("HTTP ${response.code()}"))
            val body = response.body() ?: return Result.failure(Exception("Empty body"))
            val items = body.items.map { dto -> mapAbsItemToBookSummary(dto, libraryId, connectionId, serverUrl) }
            val total = body.total ?: items.size
            val pageSize = body.limit?.takeIf { it > 0 } ?: size
            val totalPages = if (pageSize > 0) ((total + pageSize - 1) / pageSize) else 1
            val hasNext = (page + 1) < totalPages
            Result.success(com.enve.core.data.model.BookSummaryPage(
                items = items,
                page = page,
                totalPages = totalPages,
                totalElements = total.toLong(),
                hasNext = hasNext,
            ))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun updateBookMetadata(book: Book, metadata: ProviderMetadataUpdate): Result<Unit> {
        return try {
            val response = api.updateMetadata(
                itemId = book.id,
                request = AbsMetadataUpdateRequest(metadata = metadata.toAbsMetadataUpdatePayload()),
            )
            if (!response.isSuccessful) {
                Result.failure(Exception("ABS metadata update failed: HTTP ${response.code()}"))
            } else {
                Result.success(Unit)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun matchAllLibraryMetadata(libraryId: String): Result<Unit> {
        return try {
            val response = api.matchAllLibraryItems(libraryId)
            if (!response.isSuccessful) {
                Result.failure(Exception("ABS metadata refresh failed: HTTP ${response.code()}"))
            } else {
                Result.success(Unit)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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
            dto.mediaProgress?.isFinished == true -> com.enve.core.data.model.ReadStatus.COMPLETED
            progressFraction > 0f -> com.enve.core.data.model.ReadStatus.IN_PROGRESS
            else -> com.enve.core.data.model.ReadStatus.UNREAD
        }
        return com.enve.core.data.model.BookSummary(
            id = dto.id,
            connectionId = connectionId,
            source = BookSource.AUDIOBOOKSHELF,
            title = title,
            authors = authors,
            thumbnailUrl = "$serverUrl/api/items/${dto.id}/cover",
            seriesName = meta?.seriesName,
            seriesNumber = meta?.seriesNumber,
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
            try {
                api.getItemDetail(id).body()
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
        val media = detail?.media ?: dto.media
        val progress = dto.mediaProgress ?: detail?.mediaProgress
        val title = media?.metadata?.title?.takeIf { it.isNotBlank() } ?: "(Untitled)"

        val mediaType = resolveAbsMediaType(detail ?: dto)

        val author = media?.metadata?.authorName
            ?: media?.metadata?.authors?.firstOrNull()?.name

        val seriesName = media?.metadata?.seriesName
            ?: media?.metadata?.title?.let { t -> if (t.contains(":")) t.split(":").first().trim() else null }

        val durationSec = resolveAbsDurationSeconds(media, progress)

        val progressFraction = progress?.progress ?: 0f
        val positionSec = normalizeAbsCurrentTimeSeconds(
            rawCurrentTime = progress?.currentTime,
            durationSec = durationSec,
            progressFraction = progressFraction,
            fallbackSec = null,
        )
        val lastReadTime = progress?.lastUpdate
            ?.takeIf { it > 0L }
            ?.let { if (it < 100_000_000_000L) it * 1000L else it }
            ?: 0L

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
            seriesName = seriesName,
            seriesNumber = media?.metadata?.seriesNumber,
            addedOn = dto.addedAt ?: 0L,
            lastReadTime = lastReadTime,
            chapters = chapters,
            audioTracks = tracks,
            hasAudio = hasAbsAudio(media),
            hasEbook = hasAbsEbook(media),
            isFinished = progress?.isFinished == true || progressFraction >= 0.99f,
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

        progress?.duration?.takeIf { it > 0.0 }?.let {
            return normalizeAbsDurationSeconds(it, audioFileDurationSec)
        }
        media?.duration?.takeIf { it > 0.0 }?.let {
            return normalizeAbsDurationSeconds(it, audioFileDurationSec)
        }
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

        val durationSec = progress.duration
            ?.takeIf { it > 0.0 }
            ?.let { normalizeAbsDurationSeconds(it, base.duration.takeIf { d -> d > 0L }) }
            ?: base.duration
        val audioProgress = progress.progress?.coerceIn(0f, 1f) ?: base.readProgress
        val ebookProgress = progress.ebookProgress?.coerceIn(0f, 1f) ?: base.epubProgress
        val currentTimeSec = normalizeAbsCurrentTimeSeconds(
            rawCurrentTime = progress.currentTime,
            durationSec = durationSec,
            progressFraction = audioProgress,
            fallbackSec = base.currentTime,
        )
        val lastReadTime = progress.lastUpdate
            ?.takeIf { it > 0L }
            ?.let { if (it < 100_000_000_000L) it * 1000L else it }
            ?: base.lastReadTime

        return base.copy(
            duration = durationSec,
            currentTime = currentTimeSec,
            readProgress = audioProgress,
            epubProgress = ebookProgress,
            epubLocator = progress.ebookLocation ?: base.epubLocator,
            lastReadTime = lastReadTime,
            isFinished = progress.isFinished == true || audioProgress >= 0.99f || (ebookProgress ?: 0f) >= 0.99f,
        )
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

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> {
        return try {
            val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')

            val sessionResponse = api.startPlaybackSession(book.id, AbsPlaybackStartRequest())
            if (!sessionResponse.isSuccessful) {
                return Result.failure(Exception("Failed to start Audiobookshelf playback: HTTP ${sessionResponse.code()}"))
            }
            val session = sessionResponse.body()
                ?: return Result.failure(Exception("Audiobookshelf playback session returned an empty response"))
            val sessionTracks = session.audioTracks
                .mapNotNull { mapPlaybackTrackToTrack(it, serverUrl) }
                .sortedBy { it.index }
            val chapters = session.chapters.mapIndexed { index, chapter ->
                Chapter(
                    index = index,
                    title = chapter.title ?: "Chapter ${index + 1}",
                    startTime = (chapter.start ?: chapter.startOffset ?: 0.0).toLong(),
                    endTime = (chapter.end ?: chapter.start ?: 0.0).toLong(),
                )
            }.filter { it.endTime > it.startTime }
            Result.success(
                ProviderPlaybackSession(
                    sessionId = session.id,
                    audioTracks = sessionTracks,
                    chapters = chapters,
                    serverCurrentTimeSec = normalizeAbsCurrentTimeSeconds(
                        rawCurrentTime = session.currentTime,
                        durationSec = session.duration
                            ?.takeIf { it > 0.0 }
                            ?.let { normalizeAbsDurationSeconds(it, null) }
                            ?: 0L,
                        progressFraction = null,
                        fallbackSec = null,
                    ),
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
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
    ): Result<Unit> {
        return try {
            val request = AbsPlaybackSessionUpdateRequest(
                currentTime = currentTimeSec.coerceAtLeast(0).toDouble(),
                timeListened = (timeListenedMs.coerceAtLeast(0) / 1000.0),
                duration = durationSec.coerceAtLeast(0).toDouble(),
            )
            val response = if (close) {
                api.closePlaybackSession(sessionId, request)
            } else {
                api.syncPlaybackSession(sessionId, request)
            }
            if (response.isSuccessful) {
                Result.success(Unit)
            } else {
                val action = if (close) "close" else "sync"
                Result.failure(Exception("Audiobookshelf playback session $action failed: HTTP ${response.code()}"))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun normalizeAbsDurationSeconds(rawDuration: Double, referenceDurationSec: Long?): Long {
        if (rawDuration <= 0.0) return 0L
        val raw = rawDuration.toLong()
        if (raw <= 0L) return 0L
        val ref = referenceDurationSec?.takeIf { it > 0L }
        if (ref != null) {
            if (raw > ref * 10L) return (raw / 1000L).coerceAtLeast(1L)
            if (raw * 10L < ref) return raw.coerceAtLeast(1L)
            return raw.coerceAtLeast(1L)
        }
        return if (raw > 1_000_000L) (raw / 1000L).coerceAtLeast(1L) else raw
    }

    private fun normalizeAbsCurrentTimeSeconds(
        rawCurrentTime: Double?,
        durationSec: Long,
        progressFraction: Float?,
        fallbackSec: Long?,
    ): Long {
        val computedFromProgress = progressFraction
            ?.coerceIn(0f, 1f)
            ?.let { pct -> if (durationSec > 0L) (durationSec * pct).toLong() else null }

        val raw = rawCurrentTime?.takeIf { it > 0.0 }?.toLong()
        val normalized = when {
            raw == null -> null
            durationSec > 0L && raw > durationSec * 10L -> raw / 1000L
            raw > 10_000_000L -> raw / 1000L
            else -> raw
        }

        val candidate = when {
            normalized != null && normalized > 0L -> normalized
            computedFromProgress != null && computedFromProgress > 0L -> computedFromProgress
            else -> fallbackSec
        } ?: 0L

        return if (durationSec > 0L) candidate.coerceIn(0L, durationSec) else candidate.coerceAtLeast(0L)
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> {
        return startPlaybackSession(book).mapCatching { session ->
            session.audioTracks.ifEmpty {
                val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
                api.getItemDetail(book.id).body()?.media?.audioFiles.orEmpty()
                    .mapNotNull { mapAudioFileToTrack(book.id, it, serverUrl) }
                    .sortedBy { it.index }
            }
        }
    }

    suspend fun fetchChapters(book: Book): Result<List<Chapter>> = try {
        Result.success(startPlaybackSession(book).getOrThrow().chapters)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> {
        return try {
            val response = api.updateProgress(
                libraryItemId = book.id,
                request = AbsProgressUpdateRequest(
                    currentTime = currentTimeSec.toDouble().coerceAtLeast(0.0),
                    duration = book.duration.takeIf { it > 0 }?.toDouble(),
                    progress = progressFraction.coerceIn(0f, 1f),
                    isFinished = progressFraction >= 0.99f,
                ),
            )
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Audiobookshelf progress sync failed: HTTP ${response.code()}"))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        return try {
            val response = api.getProgress(book.id)
            val progress = response.body()
            if (!response.isSuccessful || progress == null) {
                return Result.success(null)
            }
            val pct = progress.progress?.coerceIn(0f, 1f) ?: return Result.success(null)
            if (pct <= 0f) return Result.success(null)
            val positionMs = progress.currentTime?.let { (it * 1000).toLong() }
            Result.success(
                com.enve.core.data.sync.SyncSnapshot(
                    percentage = pct,
                    positionMs = positionMs,
                    source = "Audiobookshelf",
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchEbookProgress(book: Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        return try {
            val response = api.getProgress(book.id)
            val progress = response.body()
            if (!response.isSuccessful || progress == null) {
                return Result.success(null)
            }
            val pct = progress.progress?.coerceIn(0f, 1f) ?: return Result.success(null)
            if (pct <= 0f) return Result.success(null)
            Result.success(
                com.enve.core.data.sync.SyncSnapshot(
                    percentage = pct,
                    source = "Audiobookshelf",
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getMe(): Result<com.enve.audiobookshelf.dto.AbsMeResponse> = try {
        val resp = api.getMe()
        if (resp.isSuccessful) Result.success(resp.body() ?: com.enve.audiobookshelf.dto.AbsMeResponse())
        else Result.failure(Exception("Audiobookshelf /api/me failed: HTTP ${resp.code()}"))
    } catch (e: Exception) {
        if (e is kotlinx.coroutines.CancellationException) throw e
        Result.failure(e)
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
        if (!resp.isSuccessful) error("ABS deleteBookmark failed: HTTP ${resp.code()}")
    }

    suspend fun syncEbookProgress(bookId: String, percentage: Float, locator: String?): Result<Unit> {
        return try {
            val normalized = percentage.coerceIn(0f, 1f)
            val response = api.updateProgress(
                libraryItemId = bookId,
                request = AbsProgressUpdateRequest(
                    progress = normalized,
                    ebookProgress = normalized,
                    ebookLocation = locator,
                    isFinished = normalized >= 0.99f,
                ),
            )
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Audiobookshelf ebook progress sync failed: HTTP ${response.code()}"))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getBooksInProgress(): Result<List<Book>> {
        return try {
            val serverUrl = scopedServerUrlAndToken().first
            val normalizedUrl = serverUrl.trimEnd('/')

            val itemsResponse = api.getItemsInProgress()
            if (!itemsResponse.isSuccessful) {
                throw IllegalStateException("ABS in-progress items failed: HTTP ${itemsResponse.code()}")
            }
            val items = itemsResponse.body()?.items
                ?: throw IllegalStateException("ABS in-progress items returned an empty body")

            val meResponse = api.getMe()
            if (!meResponse.isSuccessful) {
                throw IllegalStateException("ABS user progress failed: HTTP ${meResponse.code()}")
            }
            val progressEntries = meResponse.body()?.mediaProgress
                ?: throw IllegalStateException("ABS user progress returned an empty body")

            val books = mergeAbsMediaProgress(items, progressEntries)
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
            Result.success(books)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val cached = runCatching {
                val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
                loadLaneFromDisk(serverUrl, "in-progress")
            }.getOrNull()
            if (cached != null) Result.success(cached) else Result.failure(e)
        }
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

    suspend fun getRecentlyAdded(): Result<List<Book>> {
        return try {
            val normalizedUrl = scopedServerUrlAndToken().first.trimEnd('/')
            loadLaneFromDisk(normalizedUrl, "recently-added")?.let { return Result.success(it) }

            val libraries = getLibraries().getOrElse { return Result.failure(it) }
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
                        if (!response.isSuccessful) {
                            throw IllegalStateException("ABS recently added failed: HTTP ${response.code()}")
                        }
                        val body = response.body()
                            ?: throw IllegalStateException("ABS recently added returned an empty body")
                        body.items.mapNotNull {
                            mapAbsItemToBook(it, library.id, normalizedUrl, fetchDetail = false)
                        }
                    }
                }.awaitAll()
            }
            val unique = pages.flatten().distinctBy { it.id }.sortedByDescending { it.addedOn }.take(20)

            saveLaneToDisk(normalizedUrl, "recently-added", unique)
            Result.success(unique)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun invalidateListCaches() {
        val cacheDirectory = java.io.File(context.cacheDir, "book-index-cache")
        cacheDirectory.listFiles()?.forEach { file ->
            if (file.name.startsWith("books_abs_") ||
                file.name.startsWith("libraries_abs_") ||
                file.name.startsWith("lane_abs_")) {
                file.delete()
            }
        }
    }

    suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> {
        return try {
            val serverUrl = scopedServerUrlAndToken().first.trimEnd('/')
            val librariesResp = api.getLibraries()
            val libraries = librariesResp.body()?.libraries.orEmpty()
                .filter { it.mediaType == "book" || it.mediaType == "audiobook" }
            val merged = mutableMapOf<String, com.enve.core.data.remote.dto.SeriesSummaryDto>()
            for (library in libraries) {
                val resp = try {
                    api.getSeriesInLibrary(library.id)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    continue
                }
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
            Result.success(merged.values.toList())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> {
        return try {
            val librariesResp = api.getLibraries()
            val libraries = librariesResp.body()?.libraries.orEmpty()
                .filter { it.mediaType == "book" || it.mediaType == "audiobook" }
            val merged = mutableMapOf<String, com.enve.core.data.remote.dto.AuthorSummaryDto>()
            for (library in libraries) {
                val resp = try {
                    api.getAuthorsInLibrary(library.id)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    continue
                }
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
            Result.success(merged.values.toList())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}

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
