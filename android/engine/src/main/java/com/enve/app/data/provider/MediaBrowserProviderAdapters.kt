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
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.SyncCapability
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import retrofit2.Response
import javax.inject.Inject
import javax.inject.Singleton

private data class ProviderRequestContext(
    val serverUrl: String,
    val token: String,
)

abstract class MediaBrowserProviderAdapter(
    private val repository: GrimmoryRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
) : ProviderAdapter {

    protected abstract val providerSource: BookSource
    override val source: BookSource get() = providerSource
    override val syncCapability: SyncCapability = SyncCapability.READ_WRITE

    protected abstract suspend fun currentUserId(): String?
    protected abstract suspend fun audioChildren(userId: String, parentId: String): Response<JsonObject>

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

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        val ctx = requestContext()
        val userId = currentUserId() ?: return@runCatching singleTrack(book, ctx)
        val response = audioChildren(userId, book.id)
        val children = response.body()?.array("Items").orEmpty()
        if (children.isEmpty()) return@runCatching singleTrack(book, ctx)

        var cumulativeStartMs = 0L
        children.mapIndexedNotNull { index, element ->
            val item = element.obj() ?: return@mapIndexedNotNull null
            val id = item.string("Id") ?: return@mapIndexedNotNull null
            val durationMs = ((item.long("RunTimeTicks") ?: 0L) / 10_000L).coerceAtLeast(0L)
            AudioTrack(
                index = index,
                fileName = item.string("Name") ?: "Track ${index + 1}",
                title = item.string("Name"),
                durationMs = durationMs,
                fileSizeBytes = item.long("Size") ?: 0L,
                cumulativeStartMs = cumulativeStartMs,
                contentUrl = streamUrl(ctx, id),
            ).also {
                cumulativeStartMs += durationMs
            }
        }.ifEmpty { singleTrack(book, ctx) }
    }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runCatching {
        val tracks = getAudioTracks(book).getOrThrow()
        val durationSec = when {
            book.duration > 0 -> book.duration
            tracks.sumOf { it.durationMs } > 0L -> tracks.sumOf { it.durationMs } / 1000L
            else -> 0L
        }
        ProviderPlaybackSession(
            sessionId = "${source.name.lowercase()}-${book.id}",
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
    private val api: GrimmoryApi,
    prefs: PreferencesManager,
    vault: CredentialVault,
    connectionRegistry: ConnectionRegistry,
) : MediaBrowserProviderAdapter(repository, prefs, vault, connectionRegistry) {
    override val providerSource: BookSource = BookSource.JELLYFIN

    override suspend fun currentUserId(): String? =
        api.jellyfinMe().takeIf { it.isSuccessful }?.body()?.string("Id")

    override suspend fun audioChildren(userId: String, parentId: String): Response<JsonObject> =
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
    private val api: GrimmoryApi,
    prefs: PreferencesManager,
    vault: CredentialVault,
    connectionRegistry: ConnectionRegistry,
) : MediaBrowserProviderAdapter(repository, prefs, vault, connectionRegistry) {
    override val providerSource: BookSource = BookSource.EMBY

    override suspend fun currentUserId(): String? {
        val username = requestUsername() ?: return null
        val response = api.embyUsers()
        if (!response.isSuccessful) return null
        return response.body()
            ?.mapNotNull { it.obj() }
            ?.firstOrNull { it.string("Name").equals(username, ignoreCase = true) }
            ?.string("Id")
    }

    override suspend fun audioChildren(userId: String, parentId: String): Response<JsonObject> =
        api.embyItems(
            userId = userId,
            parentId = parentId,
            includeItemTypes = "Audio",
            recursive = false,
            limit = 1000,
        )
}

private fun JsonElement.obj(): JsonObject? = runCatching { jsonObject }.getOrNull()
private fun JsonObject.string(key: String): String? =
    this[key]?.jsonPrimitive?.contentOrNull?.takeIf { it.isNotBlank() }
private fun JsonObject.long(key: String): Long? =
    this[key]?.jsonPrimitive?.longOrNull
private fun JsonObject.array(key: String): JsonArray? =
    runCatching { this[key]?.jsonArray }.getOrNull()
