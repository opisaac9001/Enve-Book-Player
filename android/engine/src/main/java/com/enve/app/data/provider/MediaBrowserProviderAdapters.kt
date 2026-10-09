package com.enve.app.data.provider

import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.PlaybackReportEvent
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.util.runSuspendCatching
import com.enve.app.data.remote.dto.MediaBrowserItemsDto
import com.enve.app.data.remote.dto.MediaBrowserPlaybackReport
import com.enve.app.data.remote.dto.MediaBrowserUserDataUpdate
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import java.time.Instant
import kotlinx.coroutines.CancellationException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import com.enve.app.data.repository.durationMs
import retrofit2.Response
import javax.inject.Inject
import javax.inject.Singleton

private const val TICKS_PER_SECOND = 10_000_000L

private data class ProviderRequestContext(
    val serverUrl: String,
    val token: String,
)

abstract class MediaBrowserProviderAdapter(
    private val repository: GrimmoryRepository,
    protected val api: GrimmoryApi,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
) : ProviderAdapter {
    private val userIds = ConcurrentHashMap<String, String>()

    protected abstract val providerSource: BookSource
    override val source: BookSource get() = providerSource
    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE

    protected abstract suspend fun currentUserId(): String?
    protected abstract suspend fun audioChildren(userId: String, parentId: String): Response<MediaBrowserItemsDto>

    override suspend fun getLibraries(): Result<List<Library>> =
        repository.getLibrariesForSource(source)

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = repository.getBooksForSource(source, libraryId, page, size, sort, dir)

    override suspend fun getContinueListening(): Result<List<Book>> =
        repository.getContinueListeningForSource(source)

    override suspend fun getContinueReading(): Result<List<Book>> =
        repository.getContinueReadingForSource(source)

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        repository.getRecentlyAddedForSource(source)

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runSuspendCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runSuspendCatching emptyList()
        val ctx = requestContext()
        val userId = currentUserId() ?: return@runSuspendCatching singleTrack(book, ctx)
        val response = audioChildren(userId, book.id)
        val children = response.body()?.items.orEmpty().filter { it.type == "Audio" }
        if (children.isEmpty()) return@runSuspendCatching singleTrack(book, ctx)

        var cumulativeStartMs = 0L
        children.mapIndexed { index, item ->
            AudioTrack(
                index = index,
                fileName = item.name ?: "Track ${index + 1}",
                title = item.name,
                durationMs = item.durationMs,
                fileSizeBytes = 0L,
                cumulativeStartMs = cumulativeStartMs,
                contentUrl = streamUrl(ctx, item.id),
            ).also {
                cumulativeStartMs += item.durationMs
            }
        }
    }

    override suspend fun syncAudiobookProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
    ): Result<Unit> = runSuspendCatching {
        val finished = progressFraction >= FINISHED_PROGRESS_THRESHOLD
        // Only finishing or resetting changes the played flag, so a played mark set elsewhere isn't cleared mid-listen.
        saveUserData(book.id, currentTimeSec, played = finished.takeIf { it || currentTimeSec <= 1L })
        try {
            saveChildPosition(book.id, currentTimeSec)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            // The book-level position above is the one Enve reads back; the per-file one is a courtesy to other apps.
        }
    }

    private data class ChildSpan(val id: String, val startMs: Long, val durationMs: Long)
    private val childSpans = ConcurrentHashMap<String, List<ChildSpan>>()

    // Other clients resume multi-file books from the file playing, so its own resume point is kept too.
    private suspend fun saveChildPosition(bookId: String, positionSec: Long) {
        val spans = childSpans[bookId] ?: run {
            val userId = cachedUserId() ?: return
            val response = audioChildren(userId, bookId)
            if (!response.isSuccessful) return
            var start = 0L
            response.body()?.items.orEmpty().filter { it.type == "Audio" }
                .map { item -> ChildSpan(item.id, start, item.durationMs).also { start += item.durationMs } }
                .also { childSpans[bookId] = it }
        }
        if (spans.size < 2) return
        val positionMs = positionSec * 1000L
        val span = spans.lastOrNull { positionMs >= it.startMs } ?: spans.first()
        val localSec = ((positionMs - span.startMs).coerceIn(0L, span.durationMs)) / 1000L
        saveUserData(span.id, localSec, played = null)
    }

    override suspend fun reportPlayback(
        book: Book,
        event: PlaybackReportEvent,
        sessionId: String,
        positionSec: Long,
    ): Result<Unit> = runSuspendCatching {
        val report = MediaBrowserPlaybackReport(
            ItemId = book.id,
            PlaySessionId = sessionId,
            PositionTicks = positionSec.coerceAtLeast(0L) * TICKS_PER_SECOND,
            IsPaused = event == PlaybackReportEvent.PAUSED,
            EventName = when (event) {
                PlaybackReportEvent.PAUSED -> "Pause"
                PlaybackReportEvent.RESUMED -> "Unpause"
                PlaybackReportEvent.PROGRESS -> "TimeUpdate"
                else -> null
            },
        )
        val response = when (event) {
            PlaybackReportEvent.STARTED -> api.mediaBrowserPlaybackStarted(report)
            PlaybackReportEvent.STOPPED -> api.mediaBrowserPlaybackStopped(report)
            else -> api.mediaBrowserPlaybackProgress(report)
        }
        if (!response.isSuccessful) error("$source playback report failed: HTTP ${response.code()}")
        // Playstate reports apply the server's resume rules (early audiobook positions reset to 0), so restore Enve's position.
        if (event != PlaybackReportEvent.STARTED) saveUserData(book.id, positionSec, played = null)
    }

    private suspend fun saveUserData(itemId: String, positionSec: Long, played: Boolean?) {
        val userId = cachedUserId() ?: error("$source user unavailable")
        val response = api.mediaBrowserUpdateUserData(
            userId = userId,
            itemId = itemId,
            body = MediaBrowserUserDataUpdate(
                PlaybackPositionTicks = positionSec.coerceAtLeast(0L) * TICKS_PER_SECOND,
                LastPlayedDate = Instant.now().toString(),
                Played = played,
            ),
        )
        if (!response.isSuccessful) error("$source progress update failed: HTTP ${response.code()}")
    }

    private suspend fun cachedUserId(): String? {
        val key = ConnectionScope.getConnectionId().orEmpty()
        userIds[key]?.let { return it }
        return currentUserId()?.also { userIds[key] = it }
    }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val tracks = getAudioTracks(book).getOrThrow()
        val durationSec = when {
            book.duration > 0 -> book.duration
            tracks.sumOf { it.durationMs } > 0L -> tracks.sumOf { it.durationMs } / 1000L
            else -> 0L
        }
        ProviderPlaybackSession(
            sessionId = UUID.randomUUID().toString(),
            audioTracks = tracks,
            chapters = book.chapters.ifEmpty { synthesizeChaptersFromTracks(tracks, durationSec) },
            serverCurrentTimeSec = book.currentTime.takeIf { it > 0L },
        )
    }

    override suspend fun getEbookDownloadUrl(bookId: String): String? {
        val ctx = requestContext()
        return "${ctx.serverUrl.trimEnd('/')}/Items/$bookId/Download?api_key=${ctx.token}"
    }

    override fun invalidateCaches() {
        repository.invalidateListCaches()
    }

    private fun singleTrack(book: Book, ctx: ProviderRequestContext): List<AudioTrack> = listOf(
        AudioTrack(
            index = 0,
            fileName = book.title,
            title = book.title,
            durationMs = book.duration * 1000L,
            fileSizeBytes = 0L,
            cumulativeStartMs = 0L,
            contentUrl = streamUrl(ctx, book.id),
        )
    )

    private fun streamUrl(ctx: ProviderRequestContext, itemId: String): String =
        "${ctx.serverUrl.trimEnd('/')}/Audio/$itemId/stream?static=true&api_key=${ctx.token}"

    private fun requestContext(): ProviderRequestContext {
        val scopedId = ConnectionScope.getConnectionId()
        if (scopedId != null) {
            val connection = connectionRegistry.getConnectionsSync().find { it.id == scopedId }
            if (connection != null) {
                val token = vault.get(CredentialVault.accessTokenKey(scopedId))
                    ?: vault.get(CredentialVault.passwordKey(scopedId))
                    ?: prefs.getAccessTokenSync()
                    ?: ""
                return ProviderRequestContext(connection.serverUrl, token)
            }
        }
        return ProviderRequestContext(
            serverUrl = prefs.getServerUrlSync() ?: "",
            token = prefs.getAccessTokenSync() ?: "",
        )
    }

    protected fun requestUsername(): String? {
        val scopedId = ConnectionScope.getConnectionId()
        if (scopedId != null) {
            connectionRegistry.getConnectionsSync()
                .find { it.id == scopedId }
                ?.username
                ?.let { return it }
        }
        return prefs.getUsernameSync()
    }
}

@Singleton
class JellyfinProviderAdapter @Inject constructor(
    repository: GrimmoryRepository,
    api: GrimmoryApi,
    prefs: PreferencesManager,
    vault: CredentialVault,
    connectionRegistry: ConnectionRegistry,
) : MediaBrowserProviderAdapter(repository, api, prefs, vault, connectionRegistry) {
    override val providerSource: BookSource = BookSource.JELLYFIN

    override suspend fun currentUserId(): String? =
        api.jellyfinMe().takeIf { it.isSuccessful }?.body()?.Id

    override suspend fun audioChildren(userId: String, parentId: String): Response<MediaBrowserItemsDto> =
        api.jellyfinItems(
            userId = userId,
            parentId = parentId,
            includeItemTypes = "Audio",
            recursive = false,
            limit = 1000,
        )
}

@Singleton
class EmbyProviderAdapter @Inject constructor(
    repository: GrimmoryRepository,
    api: GrimmoryApi,
    prefs: PreferencesManager,
    vault: CredentialVault,
    connectionRegistry: ConnectionRegistry,
) : MediaBrowserProviderAdapter(repository, api, prefs, vault, connectionRegistry) {
    override val providerSource: BookSource = BookSource.EMBY

    override suspend fun currentUserId(): String? {
        val username = requestUsername() ?: return null
        val response = api.embyUsers()
        if (!response.isSuccessful) return null
        return response.body()
            ?.firstOrNull { it.Name.equals(username, ignoreCase = true) }
            ?.Id
    }

    override suspend fun audioChildren(userId: String, parentId: String): Response<MediaBrowserItemsDto> =
        api.embyItems(
            userId = userId,
            parentId = parentId,
            includeItemTypes = "Audio",
            recursive = false,
            limit = 1000,
        )
}

