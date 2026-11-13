package com.enve.silo

import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.AnnotationsPushResult
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.core.data.util.reachesFinishedThreshold
import com.enve.core.data.util.runSuspendCatching
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloAdminServerStatusDto
import com.enve.silo.dto.SiloAdminStatsDto
import com.enve.silo.dto.SiloAdminUserDto
import com.enve.silo.dto.SiloCatalogItemDto
import com.enve.silo.dto.SiloEbookProgressDto
import com.enve.silo.dto.SiloEbookProgressEnvelope
import com.enve.silo.dto.SiloEbookProgressRequest
import com.enve.silo.dto.SiloFileVersionDto
import com.enve.silo.dto.SiloItemDetailDto
import com.enve.silo.dto.SiloPlaybackMutationDto
import com.enve.silo.dto.SiloPlaybackPlan
import com.enve.silo.dto.SiloPlaybackProgressRequest
import com.enve.silo.dto.SiloPlaybackStartRequest
import com.enve.silo.dto.SiloPlaybackStartResponse
import com.enve.silo.dto.SiloPlaybackStopRequest
import com.enve.silo.dto.SiloProgressStateDto
import com.enve.silo.dto.SiloProgressSyncItem
import com.enve.silo.dto.SiloProgressSyncRequest
import kotlinx.coroutines.CancellationException
import okhttp3.HttpUrl.Companion.toHttpUrl
import retrofit2.Response
import java.net.URI
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

internal fun siloProgressLocation(locator: String?, progress: Double): String {
    EpubBridgeCheckpointCodec.foliateCfi(locator)?.let { return it }
    val raw = locator?.trim().orEmpty()
    if (raw.startsWith("fraction:")) return raw
    return "fraction:${"%.6f".format(Locale.US, progress.coerceIn(0.0, 1.0))}"
}

internal fun siloActiveEpubFileId(locator: String?): String? =
    EpubBridgeCheckpointCodec.decode(locator)
        ?.providerFileId
        ?.takeIf { it.isNotBlank() }

internal fun siloEbookProgress(response: Response<SiloEbookProgressEnvelope>): SiloEbookProgressDto? {
    if (response.code() == 404) return null
    return response.siloBody("Silo ebook progress failed").progress
}

internal suspend fun SiloApi.saveSiloEbookProgress(profileId: String, bookId: String, request: SiloEbookProgressRequest) {
    val current = updateEbookProgress(profileId, bookId, request)
        .siloBody("Silo ebook progress sync failed")
        .progress
        ?: error("Silo did not return the saved ebook position")
    val observedAt = siloInstantMillis(request.updatedAt) ?: error("Silo ebook observation time is invalid")
    val storedAt = siloInstantMillis(current.updatedAt) ?: error("Silo ebook response time is invalid")
    if (storedAt > observedAt) return
    val kept = current.fileId == request.fileId &&
        current.location == request.location &&
        storedAt == observedAt
    if (!kept) error("Silo did not acknowledge the ebook position")
}

internal fun siloNavigatorLocator(location: String?, progress: Double): String? {
    val raw = location?.trim()?.takeIf { it.isNotBlank() } ?: return null
    if (!EpubBridgeCheckpointCodec.isFullEpubCfi(raw)) return null
    val bounded = progress.coerceIn(0.0, 1.0)
    return """{"href":"","type":"application/xhtml+xml","locations":{"cfi":"$raw","progression":$bounded,"totalProgression":$bounded}}"""
}

internal fun SiloPlaybackStartResponse.audioPlan(): Pair<String, SiloPlaybackPlan> {
    if (protocolVersion != 3) error("Silo returned an unsupported playback protocol")
    if (outcome != "playable") error("Silo cannot play this audio: ${terminal?.reason ?: "no compatible route"}")
    val plan = playbackPlan ?: error("Silo did not return a playback plan")
    val id = sessionId?.takeIf { it.isNotBlank() } ?: error("Silo did not return a playback session")
    if (plan.protocolVersion != 3 || plan.delivery != "original_http" || plan.stream.protocol != "http_progressive" || plan.stream.url.isBlank() || plan.timeline.timelineOffsetSeconds != 0.0) {
        error("Silo returned an unsupported audio playback route")
    }
    return id to plan
}

internal enum class SiloSampleOutcome { APPLIED, SESSION_GONE, INSTALLATION_CHANGED }

internal fun Response<SiloPlaybackMutationDto>.sampleOutcome(sequence: Long, lastIssued: Long): SiloSampleOutcome {
    if (isSuccessful) {
        val mutation = body() ?: error("Silo playback progress failed: empty response body")
        return when (mutation.outcome) {
            "applied", "replayed" -> SiloSampleOutcome.APPLIED
            "stale_sample" -> {
                val accepted = mutation.accepted?.sequence ?: 0L
                if (accepted in (sequence + 1)..lastIssued) SiloSampleOutcome.APPLIED
                else error("Silo kept a newer playback sample")
            }
            else -> error("Silo returned an unknown playback progress outcome")
        }
    }
    val problem = siloProblem()
    return when {
        code() == 404 || code() == 410 -> SiloSampleOutcome.SESSION_GONE
        problem?.id == SILO_INSTALLATION_CHANGED -> SiloSampleOutcome.INSTALLATION_CHANGED
        else -> siloFailure("Silo audiobook progress sync failed", this, problem)
    }
}

data class SiloAudioDownload(val tracks: List<AudioTrack>, val headers: Map<String, String>)

@Singleton
class SiloRepository @Inject constructor(
    private val api: SiloApi,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    private val installations: SiloPlaybackInstallations,
    private val catalogCursors: SiloCatalogCursors,
) {
    private val detailCache = ConcurrentHashMap<String, SiloItemDetailDto>()
    private val playbackSessions = ConcurrentHashMap<String, List<SiloPartSession>>()
    private val pausedBooks = ConcurrentHashMap.newKeySet<String>()

    private class SiloPartSession(
        val sessionId: String,
        val fileId: String,
        val startOffsetSec: Long,
        val durationSec: Long,
        val installationId: String,
    ) {
        private val sequence = AtomicLong()
        val stopId: String = UUID.randomUUID().toString()
        val lastSequence: Long get() = sequence.get()
        fun nextSequence(): Long = sequence.incrementAndGet()
    }

    suspend fun isCurrentUserAdmin(): Result<Boolean> = runSuspendCatching {
        val response = api.me()
        if (response.code() == 401 || response.code() == 403) return@runSuspendCatching false
        response.siloBody("Silo current-user check failed").role.equals("admin", ignoreCase = true)
    }

    suspend fun getAdminStats(): Result<SiloAdminStatsDto> = runSuspendCatching {
        api.adminStats(ensureProfile()).siloBody("Silo admin stats failed")
    }

    suspend fun getAdminServerStatus(): Result<SiloAdminServerStatusDto> = runSuspendCatching {
        api.adminServerStatus(ensureProfile()).siloBody("Silo server status failed")
    }

    suspend fun getAdminUsers(): Result<List<SiloAdminUserDto>> = runSuspendCatching {
        val profileId = ensureProfile()
        siloCollectAll { cursor -> api.adminUsers(profileId, cursor).siloBody("Silo admin users failed") }
    }

    suspend fun getLibraries(): Result<List<Library>> = runSuspendCatching {
        api.libraries(ensureProfile()).siloBody("Silo libraries failed").items
            .filter { it.type.lowercase() in SUPPORTED_LIBRARY_TYPES }
            .map {
                Library(
                    id = it.id,
                    name = it.name,
                    source = BookSource.SILO,
                    connectionId = currentConnection()?.id,
                )
            }
    }

    suspend fun getBooks(libraryId: String?, page: Int, size: Int, sort: String, dir: String): Result<List<Book>> = runSuspendCatching {
        val libId = libraryId ?: getLibraries().getOrThrow().firstOrNull()?.id ?: return@runSuspendCatching emptyList()
        val pageSize = size.coerceIn(1, MAX_PAGE_SIZE)
        val profileId = ensureProfile()
        val siloSort = siloSort(sort, dir)
        val listingKey = listOf(connectionKey(), profileId, libId, siloSort.orEmpty(), pageSize).joinToString("|")
        catalogCursors.page(listingKey, page.coerceAtLeast(0), pageSize) { cursor ->
            api.catalog(profileId, libId, siloSort, cursor, pageSize).siloBody("Silo catalog failed")
        }.mapNotNull { item -> bookFromCatalogItem(item, libId) }
    }

    suspend fun getRecentlyAdded(limit: Int = 20): Result<List<Book>> = runSuspendCatching {
        val count = limit.coerceIn(1, MAX_PAGE_SIZE)
        val profileId = ensureProfile()
        getLibraries().getOrThrow()
            .flatMap { library ->
                newestItems(profileId, library.id, count).mapNotNull { item -> bookFromCatalogItem(item, library.id) }
            }
            .take(count)
    }

    suspend fun getContinueListening(): Result<List<Book>> = getContinue(AppMediaType.AUDIOBOOK)

    suspend fun getContinueReading(): Result<List<Book>> = getContinue(AppMediaType.EBOOK)

    private suspend fun getContinue(mediaType: AppMediaType): Result<List<Book>> = runSuspendCatching {
        val profileId = ensureProfile()
        getLibraries().getOrThrow()
            .flatMap { library ->
                val recency = siloCollectAll { cursor ->
                    api.progressList(profileId, library.id, cursor).siloBody("Silo progress failed")
                }.associate { it.mediaItemId to (siloInstantMillis(it.updatedAt) ?: 0L) }
                val newest = newestItems(profileId, library.id, MAX_PAGE_SIZE)
                    .mapNotNull { item -> bookFromCatalogItem(item, library.id) }
                val inProgress = recency.keys
                    .filter { id -> newest.none { it.id == id } }
                    .mapNotNull { id -> runSuspendCatching { getBook(id, library.id).getOrThrow() }.getOrNull() }
                (newest + inProgress).map { book -> recency[book.id]?.let { book.copy(lastReadTime = it) } ?: book }
            }
            .filter { it.mediaType == mediaType && it.readProgress in 0.001f..0.999f }
            .distinctBy { it.id }
            .sortedByDescending { it.lastReadTime }
    }

    private suspend fun newestItems(profileId: String, libraryId: String, count: Int): List<SiloCatalogItemDto> =
        siloFillPage(SiloPageStart(null), count) { cursor ->
            api.catalog(profileId, libraryId, "-added_at", cursor, count).siloBody("Silo catalog failed")
        }.items

    suspend fun getBook(bookId: String, fallbackLibraryId: String?): Result<Book> = runSuspendCatching {
        itemDetail(bookId).toBook(fallbackLibraryId) ?: error("Silo item is not an ebook or audiobook")
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runSuspendCatching {
        if (book.audioTracks.isNotEmpty()) return@runSuspendCatching book.audioTracks.map { track ->
            val scheme = track.contentUrl?.substringBefore(':')?.lowercase()
            if (scheme == "http" || scheme == "https") track.copy(contentUrl = null) else track
        }
        getBook(book.id, book.libraryId).getOrThrow().audioTracks
    }

    suspend fun getAudioDownload(book: Book): Result<SiloAudioDownload> = runSuspendCatching {
        val profileId = ensureProfile()
        val tracks = itemDetail(book.id, forceRefresh = true).toBook(book.libraryId)?.audioTracks.orEmpty()
        check(tracks.isNotEmpty()) { "Silo returned no audio files" }
        val connection = currentConnection() ?: error("No Silo connection selected")
        val token = vault.get(CredentialVault.accessTokenKey(connection.id)) ?: error("Silo authentication is unavailable")
        SiloAudioDownload(
            tracks.map { track ->
                val fileId = track.fileId ?: error("Silo audio file has no identifier")
                track.copy(contentUrl = apiBaseUrl().toHttpUrl().newBuilder()
                    .addPathSegment("direct-download").addQueryParameter("file_id", fileId).build().toString())
            },
            buildMap {
                put("Authorization", "Bearer $token")
                put("X-Profile-Id", profileId)
                vault.get("silo_profile_token_${connection.id}")?.takeIf { it.isNotBlank() }?.let { put("X-Profile-Token", it) }
            },
        )
    }

    suspend fun startPlaybackSession(book: Book, persistProgress: Boolean = true): Result<ProviderPlaybackSession> = runSuspendCatching {
        val profileId = ensureProfile()
        val detail = itemDetail(book.id)
        playbackSessions.remove(sessionKey(book))

        val partVersions = audiobookPartVersions(detail)
        if (partVersions != null) {
            return@runSuspendCatching startMultipartPlayback(book, profileId, partVersions)
        }

        val version = primaryVersion(detail) ?: error("No playable Silo file is available")
        val (installation, response) = startAttempt(profileId) { installationId ->
            SiloPlaybackStartRequest(
                installationId = installationId,
                fileId = version.fileId,
                profileId = profileId,
                playbackAttemptId = UUID.randomUUID().toString(),
                progressPersistence = if (persistProgress) "server" else "client",
                startPosition = if (persistProgress) null else 0.0,
            )
        }
        val (sessionId, plan) = response.audioPlan()
        val durationSec = (plan.source.durationSeconds ?: version.duration?.toDouble() ?: detail.runtimeSeconds()?.toDouble() ?: 0.0)
            .roundToLong()
            .coerceAtLeast(0L)
        playbackSessions[sessionKey(book)] = listOf(
            SiloPartSession(sessionId, version.fileId, startOffsetSec = 0L, durationSec = durationSec, installationId = installation),
        )
        val track = AudioTrack(
            index = 0,
            fileName = version.fileName ?: book.title,
            title = version.fileName ?: book.title,
            durationMs = durationSec * 1000L,
            fileSizeBytes = version.fileSize ?: 0L,
            cumulativeStartMs = 0L,
            fileId = version.fileId,
            contentUrl = streamUrl(plan.stream.url),
        )
        ProviderPlaybackSession(
            sessionId = sessionId,
            audioTracks = listOf(track),
            chapters = chaptersFrom(version, durationSec, isAudiobook = true),
            serverCurrentTimeSec = plan.timeline.sourceStartSeconds.roundToLong(),
        )
    }

    private suspend fun startMultipartPlayback(
        book: Book,
        profileId: String,
        parts: List<SiloFileVersionDto>,
    ): ProviderPlaybackSession {
        val tracks = mutableListOf<AudioTrack>()
        val sessions = mutableListOf<SiloPartSession>()
        var offsetSec = 0L

        parts.forEachIndexed { index, part ->
            val (installation, response) = startAttempt(profileId) { installationId ->
                SiloPlaybackStartRequest(
                    installationId = installationId,
                    fileId = part.fileId,
                    profileId = profileId,
                    playbackAttemptId = UUID.randomUUID().toString(),
                    progressPersistence = "client",
                    startPosition = 0.0,
                )
            }
            val (sessionId, plan) = response.audioPlan()
            val partDurationSec = (plan.source.durationSeconds ?: part.duration?.toDouble() ?: 0.0)
                .roundToLong()
                .coerceAtLeast(0L)
            tracks += AudioTrack(
                index = index,
                fileName = part.fileName ?: book.title,
                title = part.fileName ?: book.title,
                durationMs = partDurationSec * 1000L,
                fileSizeBytes = part.fileSize ?: 0L,
                cumulativeStartMs = offsetSec * 1000L,
                fileId = part.fileId,
                contentUrl = streamUrl(plan.stream.url),
            )
            sessions += SiloPartSession(sessionId, part.fileId, offsetSec, partDurationSec, installation)
            offsetSec += partDurationSec
        }

        playbackSessions[sessionKey(book)] = sessions
        return ProviderPlaybackSession(
            sessionId = sessions.first().sessionId,
            audioTracks = tracks,
            chapters = combinedChapters(parts),
            serverCurrentTimeSec = 0L,
        )
    }

    private suspend fun startAttempt(
        profileId: String,
        request: (installationId: String) -> SiloPlaybackStartRequest,
    ): Pair<String, SiloPlaybackStartResponse> {
        val key = connectionKey()
        var installation = installations.current(key, profileId)
        var response = api.startPlayback(profileId, request(installation))
        var problem = response.siloProblem()
        if (problem?.id == SILO_INSTALLATION_CHANGED) {
            installations.forget(key)
            installation = installations.current(key, profileId)
            response = api.startPlayback(profileId, request(installation))
            problem = response.siloProblem()
        }
        if (!response.isSuccessful) siloFailure("Silo playback start failed", response, problem)
        return installation to (response.body() ?: error("Silo playback start failed: empty response body"))
    }

    private suspend fun sendSample(profileId: String, session: SiloPartSession, positionSec: Long, paused: Boolean): SiloSampleOutcome {
        val sequence = session.nextSequence()
        val outcome = api.updatePlaybackProgress(
            profileId = profileId,
            sessionId = session.sessionId,
            request = SiloPlaybackProgressRequest(session.installationId, sequence, positionSec.toDouble(), paused),
        ).sampleOutcome(sequence, session.lastSequence)
        if (outcome == SiloSampleOutcome.INSTALLATION_CHANGED) installations.forget(connectionKey())
        return outcome
    }

    private fun List<SiloPartSession>.activePart(positionSec: Long): Pair<SiloPartSession, Long> {
        if (size == 1) return first() to positionSec
        val active = lastOrNull { positionSec >= it.startOffsetSec } ?: first()
        return active to (positionSec - active.startOffsetSec).coerceIn(0L, active.durationSec)
    }

    suspend fun setPlaybackPaused(book: Book, positionSec: Long, paused: Boolean): Result<Unit> = runSuspendCatching {
        if (paused) pausedBooks += sessionKey(book) else pausedBooks -= sessionKey(book)
        val sessions = playbackSessions[sessionKey(book)] ?: return@runSuspendCatching
        val (active, localPosition) = sessions.activePart(positionSec.coerceAtLeast(0L))
        sendSample(ensureProfile(), active, localPosition, paused)
        Unit
    }

    suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> = runSuspendCatching {
        val profileId = ensureProfile()
        val position = currentTimeSec.coerceAtLeast(0L)
        val key = sessionKey(book)
        val sessions = playbackSessions[key]
            ?: return@runSuspendCatching syncProgressWithoutSession(profileId, book, position)
        val paused = key in pausedBooks

        if (sessions.size > 1) {
            val (active, localPosition) = sessions.activePart(position)
            try {
                sendSample(profileId, active, localPosition, paused)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
            syncProgressWithoutSession(profileId, book, position)
            return@runSuspendCatching
        }

        val single = sessions.first()
        when (sendSample(profileId, single, position, paused)) {
            SiloSampleOutcome.APPLIED -> return@runSuspendCatching
            SiloSampleOutcome.INSTALLATION_CHANGED -> Unit
            SiloSampleOutcome.SESSION_GONE -> if (restartedSampleApplied(profileId, key, single, position, paused)) return@runSuspendCatching
        }
        playbackSessions.remove(key)
        syncProgressWithoutSession(profileId, book, position)
    }

    private suspend fun restartedSampleApplied(
        profileId: String,
        key: String,
        previous: SiloPartSession,
        positionSec: Long,
        paused: Boolean,
    ): Boolean = try {
        val (installation, response) = startAttempt(profileId) { installationId ->
            SiloPlaybackStartRequest(
                installationId = installationId,
                fileId = previous.fileId,
                profileId = profileId,
                playbackAttemptId = UUID.randomUUID().toString(),
                startPosition = positionSec.toDouble(),
            )
        }
        val (sessionId, _) = response.audioPlan()
        val replacement = SiloPartSession(sessionId, previous.fileId, 0L, previous.durationSec, installation)
        playbackSessions[key] = listOf(replacement)
        sendSample(profileId, replacement, positionSec, paused) == SiloSampleOutcome.APPLIED
    } catch (e: CancellationException) {
        throw e
    } catch (_: Exception) {
        false
    }

    private suspend fun syncProgressWithoutSession(profileId: String, book: Book, positionSec: Long) {
        val item = SiloProgressSyncItem(
            mediaItemId = book.id,
            positionMs = positionSec * 1000L,
            durationMs = maxOf(book.duration, positionSec) * 1000L,
            updatedAt = siloInstant(book.lastReadTime.takeIf { it > 0L } ?: error("Silo progress has no observation timestamp")),
        )
        val result = api.syncProgress(profileId, SiloProgressSyncRequest(listOf(item)))
            .siloBody("Silo audiobook progress sync failed")
            .items
            .firstOrNull { it.mediaItemId == book.id }
        if (result?.status != "success") {
            error("Silo rejected the progress update: ${result?.failure?.id ?: "no result"}")
        }
    }

    suspend fun stopPlaybackSession(book: Book): Result<Unit> = runSuspendCatching {
        pausedBooks -= sessionKey(book)
        val sessions = playbackSessions.remove(sessionKey(book)) ?: return@runSuspendCatching
        val profileId = ensureProfile()
        sessions.forEach { session ->
            val response = api.stopPlayback(profileId, session.sessionId, SiloPlaybackStopRequest(session.installationId, session.stopId))
            if (response.isSuccessful || response.code() == 404 || response.code() == 410) return@forEach
            val problem = response.siloProblem()
            if (problem?.id == SILO_INSTALLATION_CHANGED) {
                installations.forget(connectionKey())
                return@forEach
            }
            siloFailure("Silo playback stop failed", response, problem)
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
            finished = userData.played ?: (percentage >= FINISHED_PROGRESS_THRESHOLD),
        )
    }

    suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        locator: String?,
        observedAt: Long = System.currentTimeMillis(),
    ): Result<Unit> = runSuspendCatching {
        val fileId = siloActiveEpubFileId(locator)
            ?: error("Silo active EPUB file id was unavailable.")
        val bounded = percentage.coerceIn(0f, 1f).toDouble()
        api.saveSiloEbookProgress(
            profileId = ensureProfile(),
            bookId = bookId,
            request = SiloEbookProgressRequest(
                fileId = fileId,
                location = siloProgressLocation(locator, bounded),
                progress = bounded,
                updatedAt = siloInstant(observedAt),
            ),
        )
    }

    suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> = runSuspendCatching {
        val progress = siloEbookProgress(api.ebookProgress(ensureProfile(), book.id))
            ?: return@runSuspendCatching null
        val selectedFileId = preferredSiloEpubVersion(
            versions = itemDetail(book.id).versions,
            savedProgressFileId = progress.fileId,
        )?.fileId
        val location = progress.location.takeIf { selectedFileId == progress.fileId }
        SyncSnapshot(
            percentage = progress.progress.toFloat().coerceIn(0f, 1f),
            locatorJson = location?.let { siloNavigatorLocator(it, progress.progress) },
            epubCfi = location?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi),
            source = BookSource.SILO.displayName,
            updatedAt = siloInstantMillis(progress.updatedAt),
            finished = progress.progress.reachesFinishedThreshold(),
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
        val savedFileId = siloEbookProgress(api.ebookProgress(ensureProfile(), bookId))?.fileId
        val fileId = preferredSiloEpubVersion(itemDetail(bookId).versions, savedFileId)?.fileId ?: return null
        return ProviderEbookResource(
            url = apiBaseUrl().toHttpUrl().newBuilder()
                .addPathSegment("ebooks").addPathSegment(bookId).addPathSegment("files")
                .addPathSegment(fileId).addPathSegment("read").build().toString(),
            providerFileId = fileId,
        )
    }

    suspend fun validateConnection(): Result<Boolean> = runSuspendCatching {
        api.libraries(ensureProfile()).isSuccessful
    }

    suspend fun pushAnnotations(book: Book, annotations: List<ReaderAnnotation>): Result<AnnotationsPushResult> = runSuspendCatching {
        if (annotations.isEmpty()) return@runSuspendCatching AnnotationsPushResult()
        SiloAnnotationSync(api, ensureProfile(), book.id).push(annotations)
    }

    suspend fun fetchAnnotations(book: Book): Result<List<ReaderAnnotation>> = runSuspendCatching {
        SiloAnnotationSync(api, ensureProfile(), book.id).records().map { it.toReaderAnnotation(book.id) }
    }

    suspend fun deleteRemoteAnnotation(book: Book, serverId: String): Result<Unit> = runSuspendCatching {
        SiloAnnotationSync(api, ensureProfile(), book.id).deleteRemote(serverId)
    }

    fun invalidateCaches() {
        detailCache.clear()
        playbackSessions.clear()
        catalogCursors.clear()
        installations.clear()
    }

    private suspend fun bookFromCatalogItem(item: SiloCatalogItemDto, libraryId: String): Book? {
        if (!item.type.equals("audiobook", true) && !item.type.equals("ebook", true)) return null
        return itemDetail(item.contentId).toBook(libraryId, fallbackPosterUrl = item.posterUrl)
    }

    private suspend fun itemDetail(id: String, forceRefresh: Boolean = false): SiloItemDetailDto {
        val cacheKey = "${connectionKey()}:$id"
        if (!forceRefresh) {
            detailCache[cacheKey]?.let { return it }
        }
        val detail = api.itemDetail(ensureProfile(), id).siloBody("Silo item detail failed")
        detailCache[cacheKey] = detail
        return detail
    }

    internal suspend fun ensureProfile(): String {
        val connection = currentConnection()
        val connectionId = connection?.id
        if (connectionId != null) {
            val storedProfile = vault.get(profileIdKey(connectionId))
            val storedUser = vault.get(profileUserIdKey(connectionId))
            if (!storedProfile.isNullOrBlank() && storedUser == connection.username) return storedProfile
        }
        val profiles = api.profiles().siloBody("Silo profiles failed").items
        val profile = profiles.firstOrNull { it.isPrimary }
            ?: profiles.firstOrNull()
            ?: error("No Silo profile is available for this account")
        if (profile.hasPin) error("Sign in again to unlock your Silo profile with its PIN.")
        if (connectionId != null) {
            vault.put(profileIdKey(connectionId), profile.id)
            vault.put(profileUserIdKey(connectionId), connection.username)
        }
        return profile.id
    }

    private fun SiloItemDetailDto.runtimeSeconds(): Long? = runtimeMinutes?.toLong()?.times(60L)

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
            (
                audiobook?.totalDurationSeconds?.takeIf { it > 0 }?.toLong()
                    ?: version?.duration?.takeIf { it > 0 }?.toLong()
                    ?: runtimeSeconds()
                    ?: 0L
            ).coerceAtLeast(0L)
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
                        fileId = part.fileId,
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
                    fileId = version.fileId,
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

    private fun streamUrl(raw: String): String {
        val value = raw.trim()
        val absolute = if (value.startsWith("http://") || value.startsWith("https://")) {
            value
        } else {
            "${serverUrl().trimEnd('/')}${if (value.startsWith("/")) value else "/$value"}"
        }
        val streamUri = runCatching { URI(absolute) }.getOrNull() ?: return absolute
        val serverUri = runCatching { URI(serverUrl()) }.getOrNull() ?: return absolute
        if (streamUri.scheme != serverUri.scheme || streamUri.authority != serverUri.authority) return absolute
        if (!streamUri.path.orEmpty().contains("/stream/")) return absolute
        if (absolute.contains("token=")) return absolute
        val token = currentConnection()?.id?.let { vault.get(CredentialVault.accessTokenKey(it)) }
            ?: vault.get(CredentialVault.KEY_ACCESS_TOKEN)
            ?: return absolute
        val separator = if (absolute.contains("?")) "&" else "?"
        return "$absolute${separator}token=$token"
    }

    private fun apiBaseUrl(): String = "${serverUrl().trimEnd('/')}/api/v2"

    private fun serverUrl(): String =
        currentConnection()?.serverUrl ?: error("No Silo server URL configured")

    private fun connectionKey(): String = currentConnection()?.id.orEmpty()

    private fun currentConnection(): ProviderConnection? {
        val scopedId = ConnectionScope.getConnectionId()
        val connections = connectionRegistry.getConnectionsSync()
        if (scopedId != null) {
            return connections.firstOrNull { it.id == scopedId && it.source == BookSource.SILO }
                ?: error("The selected Silo connection is unavailable")
        }
        return connections.firstOrNull { it.source == BookSource.SILO && it.enabled }
            ?: connections.firstOrNull { it.source == BookSource.SILO }
    }

    private fun ebookFormat(version: SiloFileVersionDto?): String? {
        val container = version?.container?.lowercase()?.takeIf { it.isNotBlank() }
        if (container != null) return container
        return version?.fileName?.substringAfterLast('.', missingDelimiterValue = "")?.lowercase()?.takeIf { it.isNotBlank() }
    }

    private fun sessionKey(book: Book): String = "${book.connectionId.orEmpty()}:${book.id}"

    private fun profileIdKey(connectionId: String) = "silo_profile_id_$connectionId"
    private fun profileUserIdKey(connectionId: String) = "silo_profile_user_id_$connectionId"

    private companion object {
        const val MAX_PAGE_SIZE = 200

        val SUPPORTED_LIBRARY_TYPES = setOf("audiobooks", "audiobook", "ebooks", "ebook", "books")
    }
}

internal fun siloSort(sort: String, dir: String): String? {
    val field = when (sort.lowercase()) {
        "addedon", "added_at", "addedat", "date_added" -> "added_at"
        "title" -> "title"
        "progress" -> "progress"
        "author" -> "author"
        "narrator" -> "narrator"
        "series", "seriesname" -> "series"
        "year", "publisheddate", "published_date" -> "year"
        else -> return null
    }
    val descending = !(dir.equals("asc", true) || dir.equals("ascending", true))
    return if (descending) "-$field" else field
}

internal fun preferredSiloEpubVersion(
    versions: List<SiloFileVersionDto>,
    savedProgressFileId: String? = null,
): SiloFileVersionDto? =
    versions.firstOrNull { version ->
        version.fileId == savedProgressFileId &&
            version.siloReaderFormat() in SILO_READER_FORMATS
    } ?: versions.firstOrNull { it.siloReaderFormat() == "epub" }
        ?: versions.firstOrNull { it.siloReaderFormat() in SILO_READER_FORMATS }

private fun SiloFileVersionDto.siloReaderFormat(): String {
    val name = fileName ?: filePath.orEmpty()
    if (name.endsWith(".fb2.zip", ignoreCase = true)) return "fbz"
    val extension = name.substringAfterLast('.', missingDelimiterValue = "")
    val normalizedContainer = container?.trim()?.lowercase()?.removePrefix(".").orEmpty()
    return if (normalizedContainer.isNotBlank() && normalizedContainer !in setOf("zip", "rar")) {
        normalizedContainer
    } else {
        extension.lowercase().ifBlank { normalizedContainer }
    }
}

private val SILO_READER_FORMATS = setOf("epub")
