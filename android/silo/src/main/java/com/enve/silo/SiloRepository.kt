package com.enve.silo

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.data.sync.AcceptedAnnotation
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.RejectedAnnotation
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching
import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloCatalogItemDto
import com.enve.silo.dto.SiloAdminServerStatusDto
import com.enve.silo.dto.SiloAdminStatsDto
import com.enve.silo.dto.SiloAdminUserDto
import com.enve.silo.dto.SiloChapterDto
import com.enve.silo.dto.SiloEbookProgressRequest
import com.enve.silo.dto.SiloEbookProgressResponse
import com.enve.silo.dto.SiloFileVersionDto
import com.enve.silo.dto.SiloItemDetailDto
import com.enve.silo.dto.SiloLibrariesEnvelope
import com.enve.silo.dto.SiloLibraryDto
import com.enve.silo.dto.SiloPlaybackProgressRequest
import com.enve.silo.dto.SiloPlaybackStartRequest
import com.enve.silo.dto.SiloProgressStateDto
import com.enve.silo.dto.SiloProgressSyncItem
import com.enve.silo.dto.SiloProgressSyncRequest
import com.enve.silo.dto.SiloReaderAnnotationRecord
import com.enve.silo.dto.SiloReaderAnnotationRequest
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import retrofit2.Response
import java.net.URI
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

internal fun siloProgressLocation(locator: String?, progress: Double): String {
    EpubBridgeCheckpointCodec.foliateCfi(locator)?.let { return it }
    val raw = locator?.trim().orEmpty()
    if (raw.startsWith("fraction:")) return raw
    return "fraction:${"%.6f".format(Locale.US, progress.coerceIn(0.0, 1.0))}"
}

internal fun siloActiveEpubFileId(locator: String?): Int? =
    EpubBridgeCheckpointCodec.decode(locator)
        ?.providerFileId
        ?.toIntOrNull()

internal fun siloEbookProgressBody(
    response: Response<SiloEbookProgressResponse>,
): SiloEbookProgressResponse? {
    if (response.code() == 404 || response.code() == 204) return null
    if (!response.isSuccessful) {
        error("Silo ebook progress failed: HTTP ${response.code()} ${response.message()}".trim())
    }
    return response.body() ?: error("Silo ebook progress failed: empty response body")
}

internal fun siloNavigatorLocator(location: String?, progress: Double): String? {
    val raw = location?.trim()?.takeIf { it.isNotBlank() } ?: return null
    if (!EpubBridgeCheckpointCodec.isFullEpubCfi(raw)) return null
    val bounded = progress.coerceIn(0.0, 1.0)
    return """{"href":"","type":"application/xhtml+xml","locations":{"cfi":"$raw","progression":$bounded,"totalProgression":$bounded}}"""
}

@Singleton
class SiloRepository @Inject constructor(
    private val api: SiloApi,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true; encodeDefaults = true; explicitNulls = false }
    private val detailCache = ConcurrentHashMap<String, SiloItemDetailDto>()
    private val playbackSessions = ConcurrentHashMap<String, List<SiloPartSession>>()

    private data class SiloPartSession(
        val sessionId: String,
        val fileId: Int,
        val startOffsetSec: Long,
        val durationSec: Long,
    )

    suspend fun isCurrentUserAdmin(): Result<Boolean> = runSuspendCatching {
        val response = api.me()
        if (response.code() == 401 || response.code() == 403) return@runSuspendCatching false
        val me = response.bodyOrThrow("Silo current-user check failed")
        me.role.equals("admin", ignoreCase = true)
    }

    suspend fun getAdminStats(): Result<SiloAdminStatsDto> = runSuspendCatching {
        api.adminStats().bodyOrThrow("Silo admin stats failed")
    }

    suspend fun getAdminServerStatus(): Result<SiloAdminServerStatusDto> = runSuspendCatching {
        api.adminServerStatus().bodyOrThrow("Silo server status failed")
    }

    suspend fun getAdminUsers(): Result<List<SiloAdminUserDto>> = runSuspendCatching {
        api.adminUsers().bodyOrThrow("Silo admin users failed")
    }

    suspend fun getLibraries(): Result<List<Library>> = runSuspendCatching {
        val libraries = decodeLibraries(api.libraries().bodyOrThrow("Silo libraries failed"))
        libraries
            .filter { it.type.lowercase() in SUPPORTED_LIBRARY_TYPES }
            .map {
                Library(
                    id = it.id.toString(),
                    name = it.name,
                    source = BookSource.SILO,
                    connectionId = currentConnection()?.id,
                )
            }
    }

    suspend fun getBooks(libraryId: String?, page: Int, size: Int, sort: String, dir: String): Result<List<Book>> = runSuspendCatching {
        val libId = libraryId ?: getLibraries().getOrThrow().firstOrNull()?.id ?: return@runSuspendCatching emptyList()
        val requestedSize = size.coerceAtLeast(1)
        val offset = page.coerceAtLeast(0) * requestedSize
        val profileId = ensureProfile()
        val response = api.catalog(
            profileId = profileId,
            libraryId = libId,
            offset = offset,
            limit = requestedSize,
            sort = sort.toSiloSort(),
            order = dir.toSiloOrder(),
        )
        val body = response.bodyOrThrow("Silo catalog failed")
        body.items.mapNotNull { item -> bookFromCatalogItem(item, libId) }
    }

    suspend fun getRecentlyAdded(limit: Int = 20): Result<List<Book>> = runSuspendCatching {
        getLibraries().getOrThrow()
            .flatMap { library ->
                val profileId = ensureProfile()
                val response = api.catalog(
                    profileId = profileId,
                    libraryId = library.id,
                    offset = 0,
                    limit = limit.coerceIn(1, PAGE_SIZE),
                    sort = "added_at",
                    order = "desc",
                )
                response.bodyOrThrow("Silo recently-added failed").items.mapNotNull { item ->
                    bookFromCatalogItem(item, library.id)
                }
            }
            .take(limit.coerceAtLeast(1))
    }

    suspend fun getContinueListening(): Result<List<Book>> = getContinue(AppMediaType.AUDIOBOOK)

    suspend fun getContinueReading(): Result<List<Book>> = getContinue(AppMediaType.EBOOK)

    private suspend fun getContinue(mediaType: AppMediaType): Result<List<Book>> = runSuspendCatching {
        val profileId = ensureProfile()

        val progressResponse = api.progressList(profileId)
        val recencyByItem = if (progressResponse.isSuccessful) {
            progressResponse.body()?.progress.orEmpty()
                .mapNotNull { entry -> parseDateMillis(entry.updatedAt)?.let { entry.mediaItemId to it } }
                .toMap()
        } else {
            emptyMap()
        }
        getLibraries().getOrThrow()
            .flatMap { library ->
                api.catalog(
                    profileId = profileId,
                    libraryId = library.id,
                    offset = 0,
                    limit = PAGE_SIZE,
                    sort = "added_at",
                    order = "desc",
                ).bodyOrThrow("Silo continue failed").items.mapNotNull { item ->
                    bookFromCatalogItem(item, library.id)
                }
            }
            .filter { it.mediaType == mediaType && it.readProgress in 0.001f..0.999f }
            .map { book -> recencyByItem[book.id]?.let { book.copy(lastReadTime = it) } ?: book }
            .sortedByDescending { it.lastReadTime }
    }

    suspend fun getBook(bookId: String, fallbackLibraryId: String?): Result<Book> = runSuspendCatching {
        itemDetail(bookId).toBook(fallbackLibraryId) ?: error("Silo item is not an ebook or audiobook")
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runSuspendCatching {
        if (book.audioTracks.isNotEmpty()) return@runSuspendCatching book.audioTracks
        getBook(book.id, book.libraryId).getOrThrow().audioTracks
    }

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val profileId = ensureProfile()
        val detail = itemDetail(book.id)
        playbackSessions.remove(sessionKey(book))

        val partVersions = audiobookPartVersions(detail)
        if (partVersions != null) {
            return@runSuspendCatching startMultipartPlayback(book, profileId, partVersions)
        }

        val version = primaryVersion(detail) ?: error("No playable Silo file is available")
        val response = api.startPlayback(
            profileId = profileId,
            request = SiloPlaybackStartRequest(fileId = version.fileId, profileId = profileId),
        )
        val session = response.bodyOrThrow("Silo playback start failed")
        val durationSec = (session.durationSeconds ?: version.duration?.toDouble() ?: detail.runtime?.toDouble() ?: 0.0)
            .roundToLong()
            .coerceAtLeast(0L)
        playbackSessions[sessionKey(book)] = listOf(
            SiloPartSession(session.sessionId, version.fileId, startOffsetSec = 0L, durationSec = durationSec),
        )
        val streamUrl = absoluteUrl(session.streamUrl, addTokenForStream = true)
        val track = AudioTrack(
            index = 0,
            fileName = version.fileName ?: book.title,
            title = version.fileName ?: book.title,
            durationMs = durationSec * 1000L,
            fileSizeBytes = version.fileSize ?: 0L,
            cumulativeStartMs = 0L,
            fileId = version.fileId.toString(),
            contentUrl = streamUrl,
        )
        ProviderPlaybackSession(
            sessionId = session.sessionId,
            audioTracks = listOf(track),
            chapters = chaptersFrom(version, durationSec, isAudiobook = true),
            serverCurrentTimeSec = session.position?.roundToLong(),
        )
    }

    private suspend fun startMultipartPlayback(
        book: Book,
        profileId: String,
        parts: List<SiloFileVersionDto>,
    ): ProviderPlaybackSession {
        val tracks = mutableListOf<AudioTrack>()
        val sessions = mutableListOf<SiloPartSession>()
        var serverPositionSec: Long? = null
        var offsetSec = 0L

        parts.forEachIndexed { index, part ->
            val session = api.startPlayback(
                profileId = profileId,
                request = SiloPlaybackStartRequest(
                    fileId = part.fileId,
                    profileId = profileId,
                    disableProgressPersistence = true,
                ),
            ).bodyOrThrow("Silo playback start failed")
            val partDurationSec = (session.durationSeconds ?: part.duration?.toDouble() ?: 0.0)
                .roundToLong()
                .coerceAtLeast(0L)
            tracks += AudioTrack(
                index = index,
                fileName = part.fileName ?: book.title,
                title = part.fileName ?: book.title,
                durationMs = partDurationSec * 1000L,
                fileSizeBytes = part.fileSize ?: 0L,
                cumulativeStartMs = offsetSec * 1000L,
                fileId = part.fileId.toString(),
                contentUrl = absoluteUrl(session.streamUrl, addTokenForStream = true),
            )
            sessions += SiloPartSession(session.sessionId, part.fileId, offsetSec, partDurationSec)
            if (index == 0) serverPositionSec = session.position?.roundToLong()
            offsetSec += partDurationSec
        }

        playbackSessions[sessionKey(book)] = sessions
        return ProviderPlaybackSession(
            sessionId = sessions.first().sessionId,
            audioTracks = tracks,
            chapters = combinedChapters(parts),
            serverCurrentTimeSec = serverPositionSec,
        )
    }

    suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> = runSuspendCatching {
        val sessions = playbackSessions[sessionKey(book)] ?: return@runSuspendCatching
        val profileId = ensureProfile()
        val position = currentTimeSec.coerceAtLeast(0L)
        val isPaused = progressFraction >= 0.99f

        if (sessions.size > 1) {

            val active = sessions.lastOrNull { position >= it.startOffsetSec } ?: sessions.first()
            val localPosition = (position - active.startOffsetSec).coerceIn(0L, active.durationSec)
            try {
                api.updatePlaybackProgress(
                    profileId = profileId,
                    sessionId = active.sessionId,
                    request = SiloPlaybackProgressRequest(localPosition.toDouble(), isPaused),
                )
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
            val duration = maxOf(book.duration, position)
            val result = api.syncProgress(
                profileId = profileId,
                request = SiloProgressSyncRequest(
                    items = listOf(
                        SiloProgressSyncItem(
                            mediaItemId = book.id,
                            position = position.toDouble(),
                            duration = duration.toDouble(),
                            updatedAt = Instant.now().toString(),
                        ),
                    ),
                ),
            ).bodyOrThrow("Silo audiobook progress sync failed")
            if (result.results.none { it.mediaItemId == book.id && it.status == "ok" }) {
                error("Silo rejected the progress update")
            }
            return@runSuspendCatching
        }

        val single = sessions.first()
        val request = SiloPlaybackProgressRequest(position.toDouble(), isPaused)
        var response = api.updatePlaybackProgress(profileId, single.sessionId, request)
        if (response.code() == 404) {

            val restarted = api.startPlayback(
                profileId = profileId,
                request = SiloPlaybackStartRequest(fileId = single.fileId, profileId = profileId),
            ).bodyOrThrow("Silo playback session restart failed")
            playbackSessions[sessionKey(book)] = listOf(single.copy(sessionId = restarted.sessionId))
            response = api.updatePlaybackProgress(profileId, restarted.sessionId, request)
        }
        if (!response.isSuccessful) error(httpMessage("Silo audiobook progress sync failed", response))
    }

    suspend fun stopPlaybackSession(book: Book): Result<Unit> = runSuspendCatching {
        val sessions = playbackSessions.remove(sessionKey(book)) ?: return@runSuspendCatching
        val profileId = ensureProfile()
        sessions.forEach { session ->

            api.stopPlayback(profileId, session.sessionId)
        }
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        val detail = itemDetail(book.id, forceRefresh = true)
        val userData = detail.userData ?: return@runSuspendCatching null
        val position = userData.positionSeconds ?: return@runSuspendCatching null
        val duration = userData.durationSeconds ?: book.duration.takeIf { it > 0 }?.toDouble() ?: return@runSuspendCatching null
        if (duration <= 0.0) return@runSuspendCatching null
        val percentage = (position / duration).toFloat().coerceIn(0f, 1f)
        SyncSnapshot(
            percentage = percentage,
            positionMs = (position * 1000.0).roundToLong(),
            source = BookSource.SILO.displayName,

            updatedAt = null,
            finished = userData.played ?: (percentage >= 0.99f),
        )
    }

    suspend fun syncEbookProgress(bookId: String, percentage: Float, locator: String?): Result<Unit> = runSuspendCatching {
        val profileId = ensureProfile()
        val fileId = siloActiveEpubFileId(locator)
            ?: error("Silo active EPUB file id was unavailable.")
        val bounded = percentage.coerceIn(0f, 1f).toDouble()
        val response = api.updateEbookProgress(
            profileId = profileId,
            bookId = bookId,
            request = SiloEbookProgressRequest(
                fileId = fileId,
                location = siloProgressLocation(locator, bounded),
                progress = bounded,
            ),
        )
        if (!response.isSuccessful) error(httpMessage("Silo ebook progress sync failed", response))
    }

    suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        val progress = siloEbookProgressBody(
            api.ebookProgress(ensureProfile(), book.id),
        ) ?: return@runSuspendCatching null
        val value = progress.progress ?: return@runSuspendCatching null
        val selectedFileId = preferredSiloEpubVersion(
            versions = itemDetail(book.id).versions,
            savedProgressFileId = progress.fileId,
        )?.fileId
        val location = progress.location.takeIf {
            selectedFileId != null && progress.fileId == selectedFileId
        }
        SyncSnapshot(
            percentage = value.toFloat().coerceIn(0f, 1f),
            locatorJson = location?.let { siloNavigatorLocator(it, value) },
            epubCfi = location?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi),
            source = BookSource.SILO.displayName,
            updatedAt = parseDateMillis(progress.updatedAt),
            finished = value >= 0.99,
        )
    }

    suspend fun fetchChapters(book: Book): Result<List<Chapter>> = runSuspendCatching {
        val detail = itemDetail(book.id)
        audiobookPartVersions(detail)?.let { return@runSuspendCatching combinedChapters(it) }
        val version = primaryVersion(detail) ?: return@runSuspendCatching emptyList()
        chaptersFrom(version, book.duration, detail.type.equals("audiobook", ignoreCase = true))
    }

    suspend fun getEbookDownloadUrl(bookId: String): String? {
        return getEbookResource(bookId)?.url
    }

    suspend fun getEbookResource(bookId: String): ProviderEbookResource? {
        val profileId = ensureProfile()
        val fileId = selectedEpubVersion(profileId, bookId, itemDetail(bookId))?.fileId ?: return null
        return ProviderEbookResource(
            url = "${apiBaseUrl()}/ebooks/$bookId/files/$fileId/read",
            providerFileId = fileId.toString(),
        )
    }

    suspend fun validateConnection(): Result<Boolean> = runSuspendCatching {
        ensureProfile()
        api.libraries().isSuccessful
    }

    suspend fun pushAnnotations(book: Book, annotations: List<ReaderAnnotation>): Result<AnnotationsPushResult> = runSuspendCatching {
        if (annotations.isEmpty()) return@runSuspendCatching AnnotationsPushResult()
        val profileId = ensureProfile()
        val accepted = mutableListOf<AcceptedAnnotation>()
        val rejected = mutableListOf<RejectedAnnotation>()
        annotations.forEach { annotation ->
            if (annotation.deletedAt != null) {
                val serverId = annotation.serverId
                if (!serverId.isNullOrBlank()) {
                    val response = api.deleteAnnotation(profileId, book.id, serverId)
                    if (!response.isSuccessful && response.code() != 404) {
                        rejected += RejectedAnnotation(annotation.id, "HTTP ${response.code()}")
                        return@forEach
                    }
                }
                accepted += AcceptedAnnotation(annotation.id, serverId)
                return@forEach
            }
            val request = annotation.toSiloRequest()
            if (request == null) {
                rejected += RejectedAnnotation(annotation.id, "Silo requires an EPUB CFI or reader location")
                return@forEach
            }
            val serverId = annotation.serverId
            val response = if (serverId.isNullOrBlank()) {
                api.createAnnotation(profileId, book.id, request)
            } else {
                api.updateAnnotation(profileId, book.id, serverId, request)
            }
            if (response.isSuccessful) {
                val body = response.body()
                accepted += AcceptedAnnotation(
                    id = annotation.id,
                    serverId = body?.id ?: serverId,
                    etag = body?.updatedAt,
                )
            } else {
                rejected += RejectedAnnotation(annotation.id, "HTTP ${response.code()}")
            }
        }
        AnnotationsPushResult(accepted = accepted, rejected = rejected)
    }

    suspend fun fetchAnnotations(book: Book): Result<List<ReaderAnnotation>> = runSuspendCatching {
        val response = api.annotations(ensureProfile(), book.id)
        if (response.code() == 404 || response.code() == 204) return@runSuspendCatching emptyList()
        response.bodyOrThrow("Silo annotations pull failed").items.map { it.toReaderAnnotation(book.id) }
    }

    suspend fun deleteRemoteAnnotation(book: Book, serverId: String): Result<Unit> = runSuspendCatching {
        val response = api.deleteAnnotation(ensureProfile(), book.id, serverId)
        if (!response.isSuccessful && response.code() != 404) {
            error(httpMessage("Silo annotation delete failed", response))
        }
    }

    fun invalidateCaches() {
        detailCache.clear()
        playbackSessions.clear()
    }

    private suspend fun bookFromCatalogItem(item: SiloCatalogItemDto, libraryId: String): Book? {
        if (!item.type.equals("audiobook", true) && !item.type.equals("ebook", true)) return null
        return itemDetail(item.contentId).toBook(libraryId, fallbackPosterUrl = item.posterUrl)
    }

    private suspend fun itemDetail(id: String, forceRefresh: Boolean = false): SiloItemDetailDto {
        val cacheKey = detailCacheKey(id)
        if (!forceRefresh) {
            detailCache[cacheKey]?.let { return it }
        }
        val detail = api.itemDetail(id).bodyOrThrow("Silo item detail failed")
        detailCache[cacheKey] = detail
        return detail
    }

    private fun detailCacheKey(id: String): String = "${currentConnection()?.id.orEmpty()}:$id"

    internal suspend fun ensureProfile(): String {
        val connection = currentConnection()
        val connectionId = connection?.id
        if (connectionId != null) {
            val storedProfile = vault.get(profileIdKey(connectionId))
            val storedUser = vault.get(profileUserIdKey(connectionId))
            if (!storedProfile.isNullOrBlank() && storedUser == connection.username) return storedProfile
        }
        val response = api.profiles()
        val profiles = response.bodyOrThrow("Silo profiles failed").profiles
        val profile = profiles
            .firstOrNull { it.isPrimary }
            ?: profiles.firstOrNull()
            ?: error("No Silo profile is available for this account")
        if (connectionId != null) {
            vault.put(profileIdKey(connectionId), profile.id)
            vault.put(profileUserIdKey(connectionId), connection.username)
        }
        return profile.id
    }

    private fun SiloItemDetailDto.toBook(fallbackLibraryId: String?, fallbackPosterUrl: String? = null): Book? {
        val isAudiobook = type.equals("audiobook", ignoreCase = true)
        if (!isAudiobook && !type.equals("ebook", ignoreCase = true)) return null
        val version = primaryVersion(this)
        val partVersions = audiobookPartVersions(this)
        val authors = audiobook?.authors?.map { it.name } ?: ebook?.authors?.map { it.name } ?: emptyList()
        val narrators = audiobook?.narrators?.map { it.name }.orEmpty()
        val series = audiobook?.series?.name ?: ebook?.series?.name ?: seriesTitle
        val durationSec = if (partVersions != null) {
            partVersions.sumOf { (it.duration ?: 0).toLong() }.coerceAtLeast(0L)
        } else {
            (audiobook?.totalDurationSeconds ?: version?.duration ?: runtime ?: 0).toLong().coerceAtLeast(0L)
        }
        val userProgress = progressSnapshot(userData, durationSec)
        val chapters = partVersions?.let { combinedChapters(it) }
            ?: version?.let { chaptersFrom(it, durationSec, isAudiobook) }.orEmpty()
        val audioTracks = when {
            partVersions != null -> {
                var offsetSec = 0L
                partVersions.mapIndexed { index, part ->
                    val partDurationSec = (part.duration ?: 0).toLong().coerceAtLeast(0L)
                    AudioTrack(
                        index = index,
                        fileName = part.fileName ?: title,
                        title = part.fileName ?: title,
                        durationMs = partDurationSec * 1000L,
                        fileSizeBytes = part.fileSize ?: 0L,
                        cumulativeStartMs = offsetSec * 1000L,
                        fileId = part.fileId.toString(),
                        contentUrl = null,
                    ).also { offsetSec += partDurationSec }
                }
            }
            isAudiobook && version != null -> listOf(
                AudioTrack(
                    index = 0,
                    fileName = version.fileName ?: title,
                    title = version.fileName ?: title,
                    durationMs = durationSec * 1000L,
                    fileSizeBytes = version.fileSize ?: 0L,
                    cumulativeStartMs = 0L,
                    fileId = version.fileId.toString(),
                    contentUrl = null,
                )
            )
            else -> emptyList()
        }
        return Book(
            id = contentId,
            title = title,
            author = authors.joinToString(", ").ifBlank { null },
            narrator = narrators.joinToString(", ").ifBlank { null },
            description = overview,
            coverUrl = coverUrl(posterUrl ?: fallbackPosterUrl),
            duration = if (isAudiobook) durationSec else 0L,
            currentTime = userProgress?.positionSeconds?.roundToLong() ?: 0L,
            isFinished = userProgress?.played ?: false,
            source = BookSource.SILO,
            mediaType = if (isAudiobook) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK,
            readStatus = if (userProgress?.played == true) ReadStatus.COMPLETED else ReadStatus.UNREAD,
            seriesName = series,
            publisher = audiobook?.publisher ?: ebook?.publisher,
            publishedDate = year?.toString(),
            categories = genres.orEmpty(),
            primaryFileType = ebookFormat(version),
            libraryId = fallbackLibraryId,
            connectionId = currentConnection()?.id,
            readProgress = userProgress?.fraction ?: 0f,
            chapters = chapters,
            audioTracks = audioTracks,
            bitrate = version?.bitrate,
            epubProgress = if (!isAudiobook) userProgress?.fraction else null,
            hasEbook = !isAudiobook,
            hasAudio = isAudiobook,
        )
    }

    private data class SiloMappedProgress(
        val positionSeconds: Double?,
        val fraction: Float?,
        val played: Boolean?,
    )

    private fun progressSnapshot(progress: SiloProgressStateDto?, durationSec: Long): SiloMappedProgress? {
        if (progress == null) return null
        val position = progress.positionSeconds
        val duration = durationSec.takeIf { it > 0 }?.toDouble()
            ?: progress.durationSeconds?.takeIf { it > 0.0 }
        val fraction = when {
            position != null && duration != null -> (position / duration).toFloat().coerceIn(0f, 1f)
            progress.played == true -> 1f
            else -> null
        }
        return SiloMappedProgress(position, fraction, progress.played)
    }

    private fun decodeLibraries(element: JsonElement?): List<SiloLibraryDto> {
        if (element == null) return emptyList()
        return when (element) {
            is JsonArray -> json.decodeFromJsonElement(ListSerializer(SiloLibraryDto.serializer()), element)
            is JsonObject -> {
                val envelope = json.decodeFromJsonElement(SiloLibrariesEnvelope.serializer(), element)
                envelope.libraries ?: envelope.items ?: emptyList()
            }
            else -> emptyList()
        }
    }

    private fun primaryVersion(detail: SiloItemDetailDto): SiloFileVersionDto? =
        if (detail.type.equals("ebook", ignoreCase = true)) {
            preferredSiloEpubVersion(detail.versions) ?: detail.versions.firstOrNull()
        } else {
            detail.versions.firstOrNull()
        }

    private fun audiobookPartVersions(detail: SiloItemDetailDto): List<SiloFileVersionDto>? {
        if (!detail.type.equals("audiobook", ignoreCase = true)) return null
        val variants = detail.playbackVariants?.takeIf { it.isNotEmpty() } ?: return null
        val primaryFileId = detail.versions.firstOrNull()?.fileId
        val variant = variants.firstOrNull { candidate ->
            candidate.parts.any { part -> part.versions.any { it.fileId == primaryFileId } }
        } ?: variants.first()
        if (variant.parts.size <= 1) return null
        val parts = variant.parts
            .sortedBy { it.partIndex }
            .mapNotNull { part ->
                part.versions.firstOrNull { it.fileId == part.defaultFileId } ?: part.versions.firstOrNull()
            }
        return parts.takeIf { it.size > 1 }
    }

    private fun combinedChapters(parts: List<SiloFileVersionDto>): List<Chapter> {
        val result = mutableListOf<Chapter>()
        var offsetSec = 0L
        parts.forEachIndexed { partIndex, part ->
            val partDurationSec = (part.duration ?: 0).toLong().coerceAtLeast(0L)
            val partChapters = part.chapters.orEmpty()
            if (partChapters.isEmpty()) {
                result += Chapter(
                    index = result.size,
                    title = "Part ${partIndex + 1}",
                    startTime = offsetSec,
                    endTime = offsetSec + partDurationSec,
                )
            } else {
                partChapters.forEach { chapter ->
                    result += Chapter(
                        index = result.size,
                        title = chapter.title,
                        startTime = offsetSec + chapter.startSeconds.roundToLong().coerceAtLeast(0L),
                        endTime = offsetSec + chapter.endSeconds.roundToLong().coerceAtLeast(0L),
                    )
                }
            }
            offsetSec += partDurationSec
        }
        return result
    }

    private suspend fun selectedEpubVersion(
        profileId: String,
        bookId: String,
        detail: SiloItemDetailDto,
    ): SiloFileVersionDto? {
        val savedFileId = siloEbookProgressBody(
            api.ebookProgress(profileId, bookId),
        )?.fileId
        return preferredSiloEpubVersion(detail.versions, savedFileId)
    }

    private fun chaptersFrom(version: SiloFileVersionDto, fallbackDurationSec: Long, isAudiobook: Boolean): List<Chapter> {
        val chapters = version.chapters.orEmpty()
        if (chapters.isEmpty()) {
            if (!isAudiobook) return emptyList()
            val end = fallbackDurationSec.takeIf { it > 0 } ?: version.duration?.toLong() ?: 0L
            return if (end > 0L) listOf(Chapter(index = 0, title = "Track 1", startTime = 0L, endTime = end)) else emptyList()
        }
        return chapters.map { chapter ->
            Chapter(
                index = chapter.index,
                title = chapter.title,
                startTime = chapter.startSeconds.roundToLong().coerceAtLeast(0L),
                endTime = chapter.endSeconds.roundToLong().coerceAtLeast(0L),
            )
        }
    }

    private fun coverUrl(raw: String?): String? {
        val value = raw?.trim()?.takeIf { it.isNotBlank() } ?: return null
        if (value.startsWith("http://") || value.startsWith("https://")) return value
        return "${serverUrl().trimEnd('/')}${if (value.startsWith("/")) value else "/$value"}"
    }

    private fun absoluteUrl(raw: String, addTokenForStream: Boolean): String {
        val value = raw.trim()
        val absolute = if (value.startsWith("http://") || value.startsWith("https://")) {
            value
        } else if (value == "/stream" || value.startsWith("/stream/")) {
            "${apiBaseUrl()}$value"
        } else {
            "${serverUrl().trimEnd('/')}${if (value.startsWith("/")) value else "/$value"}"
        }
        if (!addTokenForStream) return absolute
        val path = runCatching { URI(absolute).path }.getOrNull().orEmpty()
        if (!path.contains("/stream/") && path != "/api/v1/stream") return absolute
        if (absolute.contains("token=")) return absolute
        val token = currentConnection()?.id?.let { vault.get(CredentialVault.accessTokenKey(it)) }
            ?: vault.get(CredentialVault.KEY_ACCESS_TOKEN)
            ?: return absolute
        val separator = if (absolute.contains("?")) "&" else "?"
        return "$absolute${separator}token=$token"
    }

    private fun apiBaseUrl(): String = "${serverUrl().trimEnd('/')}/api/v1"

    private fun serverUrl(): String =
        currentConnection()?.serverUrl ?: error("No Silo server URL configured")

    private fun currentConnection(): ProviderConnection? {
        val scopedId = ConnectionScope.getConnectionId()
        val connections = connectionRegistry.getConnectionsSync()
        if (scopedId != null) {
            connections.firstOrNull { it.id == scopedId }?.let { return it }
        }
        return connections.firstOrNull { it.source == BookSource.SILO && it.enabled }
            ?: connections.firstOrNull { it.source == BookSource.SILO }
    }

    private fun String.toSiloSort(): String = when (lowercase()) {
        "addedon", "added_at", "date_added" -> "added_at"
        "progress" -> "progress"
        "title" -> "title"
        else -> this
    }

    private fun String.toSiloOrder(): String = if (equals("asc", true) || equals("ascending", true)) "asc" else "desc"

    private fun ebookFormat(version: SiloFileVersionDto?): String? {
        val container = version?.container?.lowercase()?.takeIf { it.isNotBlank() }
        if (container != null) return container
        return version?.fileName?.substringAfterLast('.', missingDelimiterValue = "")?.lowercase()?.takeIf { it.isNotBlank() }
    }

    private fun sessionKey(book: Book): String = "${book.connectionId.orEmpty()}:${book.id}"

    private fun extractCfi(locator: String?): String? {
        EpubBridgeCheckpointCodec.cfi(locator)?.let { return it }
        val raw = locator?.trim()?.takeIf { it.isNotBlank() } ?: return null
        if (raw.startsWith("epubcfi(")) return raw
        val parsed = runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull() ?: return null
        val locations = parsed["locations"]?.jsonObject ?: return null
        val fragments = runCatching { locations["fragments"]?.jsonArray }.getOrNull()
        fragments?.firstOrNull { it.jsonPrimitive.content.startsWith("epubcfi(") }?.let { return it.jsonPrimitive.content }
        return locations["cfi"]?.jsonPrimitive?.content?.takeIf { it.startsWith("epubcfi(") }
    }

    private fun ReaderAnnotation.toSiloRequest(): SiloReaderAnnotationRequest? {
        val location = cfi?.takeIf { it.isNotBlank() }
            ?: extractCfi(locatorJson)
            ?: locatorJson?.takeIf { it.startsWith("fraction:") }
            ?: totalProgression?.let {
                "fraction:${"%.6f".format(Locale.US, it.coerceIn(0.0, 1.0))}"
            }
            ?: progression?.let {
                "fraction:${"%.6f".format(Locale.US, it.coerceIn(0.0, 1.0))}"
            }
            ?: return null
        val hasCfi = location.startsWith("epubcfi(")
        val parsedKind = AnnotationKind.parse(kind)
        val siloKind = if (parsedKind == AnnotationKind.BOOKMARK || !hasCfi) {
            "bookmark"
        } else {
            when (parsedKind) {
                AnnotationKind.NOTE -> "note"
                AnnotationKind.HIGHLIGHT -> "highlight"
                AnnotationKind.BOOKMARK -> "bookmark"
            }
        }
        return SiloReaderAnnotationRequest(
            kind = siloKind,
            cfiRange = location.takeIf { hasCfi },
            location = location,
            selectedText = selectedText,
            note = note,
            style = AnnotationStyle.parse(style).name.lowercase(),
            color = colorHex,
            metadata = buildMap {
                put("enve_local_id", id)
                put("enve_position", (totalProgression ?: progression ?: 0.0).toString())
                chapterId?.let { put("enve_chapter_title", it) }
            },
        )
    }

    private fun SiloReaderAnnotationRecord.toReaderAnnotation(bookId: String): ReaderAnnotation {
        val localId = metadata["enve_local_id"]?.takeIf { it.isNotBlank() } ?: id
        val cfi = cfiRange?.takeIf { it.startsWith("epubcfi(") }
            ?: location?.takeIf { it.startsWith("epubcfi(") }
        val progression = metadata["enve_position"]?.toDoubleOrNull()
        return ReaderAnnotation(
            id = localId,
            bookId = bookId,
            kind = when (kind.lowercase()) {
                "bookmark" -> AnnotationKind.BOOKMARK.name
                "note" -> AnnotationKind.NOTE.name
                else -> AnnotationKind.HIGHLIGHT.name
            },
            media = AnnotationMedia.EPUB.name,
            style = AnnotationStyle.parse(style.uppercase()).name,
            colorHex = color,
            locatorJson = siloNavigatorLocator(location ?: cfi, progression ?: 0.0),
            cfi = cfi,
            progression = progression,
            totalProgression = progression,
            selectedText = selectedText,
            note = note,
            chapterId = metadata["enve_chapter_title"]?.takeIf { it.isNotBlank() },
            createdAt = parseDateMillis(createdAt) ?: System.currentTimeMillis(),
            updatedAt = parseDateMillis(updatedAt) ?: System.currentTimeMillis(),
            serverId = id,
            providerSource = BookSource.SILO.displayName.lowercase(),
            syncDirty = false,
            syncEtag = updatedAt,
        )
    }

    private fun parseDateMillis(raw: String?): Long? {
        if (raw.isNullOrBlank()) return null
        return runCatching { Instant.parse(raw).toEpochMilli() }.getOrNull()
            ?: runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
            ?: runCatching { LocalDateTime.parse(raw, DateTimeFormatter.ISO_DATE_TIME).toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
            ?: runCatching { LocalDate.parse(raw, DateTimeFormatter.ISO_DATE).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli() }.getOrNull()
            ?: raw.toLongOrNull()?.let { if (it > 1_000_000_000_000L) it else it * 1000L }
    }

    private fun <T> Response<T>.bodyOrThrow(prefix: String): T {
        if (!isSuccessful) error(httpMessage(prefix, this))
        return body() ?: error("$prefix: empty response body")
    }

    private fun httpMessage(prefix: String, response: Response<*>): String =
        "$prefix: HTTP ${response.code()} ${response.message()}".trim()

    private fun profileIdKey(connectionId: String) = "silo_profile_id_$connectionId"
    private fun profileUserIdKey(connectionId: String) = "silo_profile_user_id_$connectionId"

    private companion object {
        const val PAGE_SIZE = 100

        val SUPPORTED_LIBRARY_TYPES = setOf("audiobooks", "audiobook", "ebooks", "ebook", "books")
    }
}

internal fun preferredSiloEpubVersion(
    versions: List<SiloFileVersionDto>,
    savedProgressFileId: Int? = null,
): SiloFileVersionDto? =
    versions.firstOrNull { version ->
        version.fileId == savedProgressFileId &&
            version.siloReaderFormat() in SILO_READER_FORMATS
    } ?: versions.firstOrNull { it.siloReaderFormat() == "epub" }
        ?: versions.firstOrNull { it.siloReaderFormat() in SILO_READER_FORMATS }

private fun SiloFileVersionDto.siloReaderFormat(): String {
    val name = fileName ?: filePath.orEmpty()
    if (name.endsWith(".fb2.zip", ignoreCase = true)) return "fbz"
    val extension = name.substringAfterLast('.', missingDelimiterValue = "").lowercase()
    val normalizedContainer = container?.trim()?.lowercase()?.removePrefix(".").orEmpty()
    return if (normalizedContainer.isNotBlank() && normalizedContainer !in setOf("zip", "rar")) {
        normalizedContainer
    } else {
        extension.ifBlank { normalizedContainer }
    }
}

private val SILO_READER_FORMATS = setOf("epub")
