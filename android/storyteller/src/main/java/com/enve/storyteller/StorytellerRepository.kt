package com.enve.storyteller

import android.net.Uri
import android.util.Log
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.storyteller.api.StorytellerApi
import com.enve.storyteller.dto.StorytellerAppTokenRequest
import com.enve.storyteller.dto.StorytellerAudioManifestDto
import com.enve.storyteller.dto.StorytellerBookDto
import com.enve.storyteller.dto.StorytellerCollectionDto
import com.enve.storyteller.dto.StorytellerPositionRequest
import com.enve.storyteller.dto.StorytellerPositionResponse
import com.enve.storyteller.dto.StorytellerRatingUpdateRequest
import com.enve.storyteller.dto.StorytellerSeriesDto
import com.enve.storyteller.dto.StorytellerStatusDto
import com.enve.storyteller.dto.StorytellerStatusUpdateRequest
import com.enve.storyteller.dto.StorytellerUserDto
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.serializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

@Singleton
class StorytellerRepository @Inject constructor(
    private val api: StorytellerApi,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
    private val vault: CredentialVault,
) {

    private fun pendingConnectionId(serverUrl: String, username: String): String {
        val normalizedUrl = serverUrl.trim().trimEnd('/')
        val effectiveUsername = username.ifBlank { "token-user" }
        return "${BookSource.STORYTELLER.name}|$normalizedUrl|$effectiveUsername".lowercase()
    }

    private fun installFreshTokenScope(serverUrl: String, username: String, token: String): String {
        val connectionId = pendingConnectionId(serverUrl, username)
        vault.put(CredentialVault.accessTokenKey(connectionId), token)
        if (username.isNotBlank()) {
            vault.put(CredentialVault.usernameKey(connectionId), username)
        }
        return connectionId
    }

    private fun rollbackFreshTokenScope(connectionId: String) {
        vault.remove(CredentialVault.accessTokenKey(connectionId))
        vault.remove(CredentialVault.usernameKey(connectionId))
    }

    private suspend fun stagePendingConnection(
        connectionId: String,
        serverUrl: String,
        username: String,
    ): ProviderConnection? {
        val existing = connectionRegistry.getConnectionsSync().find { it.id == connectionId }
        val pendingConnection = existing?.copy(
            source = BookSource.STORYTELLER,
            serverUrl = serverUrl,
            username = username,
        ) ?: ProviderConnection(
            id = connectionId,
            source = BookSource.STORYTELLER,
            name = "Storyteller",
            serverUrl = serverUrl,
            username = username,
            enabled = false,
            authMode = if (username.isBlank()) ConnectionAuthMode.SSO else ConnectionAuthMode.USERNAME_PASSWORD,
            urlScheme = if (serverUrl.startsWith("http://", ignoreCase = true)) UrlScheme.HTTP else UrlScheme.HTTPS,
        )
        connectionRegistry.upsert(pendingConnection)
        return existing
    }

    private suspend fun restorePendingConnection(
        connectionId: String,
        previousConnection: ProviderConnection?,
    ) {
        if (previousConnection == null) {
            connectionRegistry.remove(connectionId)
        } else {
            connectionRegistry.upsert(previousConnection)
        }
    }

    private data class AuthSnapshot(
        val activeBookSource: BookSource,
        val activeConnectionId: String?,
        val serverUrl: String?,
        val username: String?,
    )

    private fun snapshotAuthState(): AuthSnapshot = AuthSnapshot(
        activeBookSource = prefs.getActiveBookSourceSync(),
        activeConnectionId = prefs.getActiveConnectionIdSync(),
        serverUrl = prefs.getServerUrlSync(),
        username = prefs.getUsernameSync(),
    )

    private suspend fun restoreAuthState(snapshot: AuthSnapshot) {
        prefs.setActiveBookSource(snapshot.activeBookSource)
        prefs.setActiveConnectionId(snapshot.activeConnectionId)
        prefs.saveServerInfo(snapshot.serverUrl.orEmpty(), snapshot.username.orEmpty())
    }
    private fun scopedServerUrl(): String? {
        connectionRegistry.getScopedConnectionSync()?.let { return it.serverUrl }
        return prefs.getServerUrlSync()
    }
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    private inline fun <reified T> decodeListBody(
        body: okhttp3.ResponseBody?,
        label: String,
    ): List<T> {
        val decoded = decodeLenientStorytellerArray<T>(
            json = json,
            payload = body?.string()?.takeIf { it.isNotBlank() } ?: "[]",
        )
        if (decoded.skippedCount > 0) {
            Log.w(TAG, "Storyteller $label skipped ${decoded.skippedCount} malformed record(s)")
        }
        return decoded.values
    }

    private val durationCacheSec = ConcurrentHashMap<String, Long>()
    private val durationFetchSemaphore = Semaphore(permits = 6)

    suspend fun login(serverUrl: String, username: String, password: String): Result<StorytellerUserDto> = runSuspendCatching {
        val normalizedUrl = serverUrl.trimEnd('/')
        val snapshot = snapshotAuthState()
        prefs.setActiveBookSource(BookSource.STORYTELLER)
        prefs.saveServerInfo(normalizedUrl, username)

        val body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("usernameOrEmail", username)
            .addFormDataPart("password", password)
            .build()
        val response = try {
            api.loginAt("$normalizedUrl/api/v2/token", body)
        } catch (e: Throwable) {
            restoreAuthState(snapshot); throw e
        }
        if (!response.isSuccessful) {
            restoreAuthState(snapshot)
            error(formatHttpError("Storyteller login failed", response.code(), response.headers().toMultimap(), response.errorBody()?.string()))
        }
        val token = response.body()?.access_token?.takeIf { it.isNotBlank() }
            ?: run { restoreAuthState(snapshot); error("Storyteller login returned no access token") }
        commitLogin(normalizedUrl, username, token, snapshot)
    }

    suspend fun exchangeAppToken(serverUrl: String, shortToken: String): Result<StorytellerUserDto> = runSuspendCatching {
        val normalizedUrl = serverUrl.trimEnd('/')
        val snapshot = snapshotAuthState()
        val response = api.exchangeAppTokenAt("$normalizedUrl/api/v2/token/app", StorytellerAppTokenRequest(shortToken))
        if (!response.isSuccessful) {
            error(formatHttpError("Storyteller app token exchange failed", response.code(), response.headers().toMultimap(), response.errorBody()?.string()))
        }
        val token = response.body()?.access_token?.takeIf { it.isNotBlank() }
            ?: error("Storyteller app token exchange returned no access token")
        prefs.setActiveBookSource(BookSource.STORYTELLER)
        prefs.saveServerInfo(normalizedUrl, "")
        commitLogin(normalizedUrl, "", token, snapshot)
    }

    suspend fun loginWithToken(serverUrl: String, username: String, accessToken: String): Result<StorytellerUserDto> = runSuspendCatching {
        val normalizedUrl = serverUrl.trimEnd('/')
        val snapshot = snapshotAuthState()
        val exchanged = runSuspendCatching {
            api.exchangeAppTokenAt("$normalizedUrl/api/v2/token/app", StorytellerAppTokenRequest(accessToken))
        }.getOrNull()
        val longToken = if (exchanged?.isSuccessful == true) {
            exchanged.body()?.access_token?.takeIf { it.isNotBlank() } ?: accessToken
        } else {
            accessToken
        }
        prefs.setActiveBookSource(BookSource.STORYTELLER)
        prefs.saveServerInfo(normalizedUrl, username)
        commitLogin(normalizedUrl, username, longToken, snapshot)
    }

    private suspend fun commitLogin(
        serverUrl: String,
        username: String,
        token: String,
        snapshot: AuthSnapshot,
    ): StorytellerUserDto {
        val pendingId = installFreshTokenScope(serverUrl, username, token)
        val previousConnection = stagePendingConnection(pendingId, serverUrl, username)
        prefs.setActiveConnectionId(pendingId)
        return try {
            val user = withContext(ConnectionScope.asContextElement(pendingId)) {
                getCurrentUser().getOrThrow()
            }
            prefs.saveAuth(token, null)
            user
        } catch (e: Throwable) {
            rollbackFreshTokenScope(pendingId)
            restorePendingConnection(pendingId, previousConnection)
            restoreAuthState(snapshot)
            throw e
        }
    }

    suspend fun getCurrentUser(): Result<StorytellerUserDto> = runSuspendCatching {
        val response = api.getCurrentUser()
        if (!response.isSuccessful) {
            error(formatHttpError("Storyteller user validation failed", response.code(), response.headers().toMultimap(), response.errorBody()?.string()))
        }
        response.body() ?: error("Storyteller returned an empty user response")
    }

    private fun formatHttpError(prefix: String, code: Int, headers: Map<String, List<String>>, body: String?): String {
        val parts = mutableListOf("$prefix: HTTP $code")
        headers.entries.firstOrNull { it.key.equals("WWW-Authenticate", ignoreCase = true) }
            ?.value?.firstOrNull()
            ?.takeIf { it.isNotBlank() }
            ?.let { parts += "auth: ${it.take(80)}" }
        body?.trim()?.takeIf { it.isNotBlank() }?.let { raw ->
            val excerpt = raw
                .replace(Regex("\\s+"), " ")
                .take(140)
            parts += "body: $excerpt"
        }
        return parts.joinToString(" · ")
    }

    fun webLoginUrl(serverUrl: String): String = "${serverUrl.trimEnd('/')}/api/v2/token/app"

    suspend fun getLibraries(): Result<List<Library>> = Result.success(
        listOf(
            Library(
                id = STORYTELLER_LIBRARY_ID,
                name = "Storyteller",
                source = BookSource.STORYTELLER,
            )
        )
    )

    suspend fun getBooks(): Result<List<Book>> = runSuspendCatching {
        val response = api.getBooks()
        if (!response.isSuccessful) error("Failed to fetch Storyteller books: HTTP ${response.code()}")
        val books = decodeListBody<StorytellerBookDto>(response.body(), "books")
            .mapNotNull { book -> mapStorytellerBook(book, scopedServerUrl()) }
        enrichWithDurations(books)
    }

    suspend fun getBook(bookId: String): Result<Book> = runSuspendCatching {
        val response = api.getBook(serverBookId(bookId))
        if (!response.isSuccessful) error("Failed to fetch Storyteller book: HTTP ${response.code()}")
        val book = response.body()?.let { item -> mapStorytellerBook(item, scopedServerUrl()) }
            ?: error("Storyteller book could not be decoded")
        enrichWithDurations(listOf(book)).first()
    }

    private suspend fun enrichWithDurations(books: List<Book>): List<Book> {
        val needsFetch = books.filter {
            it.mediaType == AppMediaType.AUDIOBOOK && it.duration <= 0L && !durationCacheSec.containsKey(it.id)
        }
        if (needsFetch.isNotEmpty()) {
            coroutineScope {
                needsFetch.map { book ->
                    async {
                        durationFetchSemaphore.withPermit {
                            runSuspendCatching { fetchManifestDurationSec(book.id) }
                                .getOrNull()
                                ?.takeIf { it > 0L }
                                ?.let { durationCacheSec[book.id] = it }
                        }
                    }
                }.awaitAll()
            }
        }
        return books.map { book ->
            if (book.mediaType == AppMediaType.AUDIOBOOK && book.duration <= 0L) {
                durationCacheSec[book.id]?.let { book.copy(duration = it) } ?: book
            } else {
                book
            }
        }
    }

    private suspend fun fetchManifestDurationSec(bookId: String): Long {
        val serverId = storytellerServerBookIdOrNull(bookId) ?: return 0L
        val response = api.getAudioManifest(serverId)
        if (!response.isSuccessful) return 0L
        val manifest = response.body() ?: return 0L
        val totalMs = manifest.readingOrder.sumOf {
            ((it.duration ?: 0.0) * 1000.0).roundToLong().coerceAtLeast(0L)
        }
        return totalMs / 1000L
    }

    suspend fun getRecentlyAdded(): Result<List<Book>> = getBooks().map { books -> books.sortedByDescending { it.addedOn }.take(20) }

    suspend fun getContinueListening(): Result<List<Book>> = getBooks().map { books ->
        books.filter { it.mediaType == AppMediaType.AUDIOBOOK && it.readProgress > 0f && !it.isFinished }
            .sortedByDescending { it.lastReadTime }
            .take(20)
    }

    suspend fun getContinueReading(): Result<List<Book>> = getBooks().map { books ->
        books.filter { (it.mediaType == AppMediaType.EBOOK || it.readAlongAvailable) && it.readProgress > 0f && !it.isFinished }
            .sortedByDescending { it.lastReadTime }
            .take(20)
    }

    suspend fun getSeriesBooks(seriesName: String): Result<List<Book>> = getBooks().map { books ->
        val byNumber: Comparator<Book> = compareBy(nullsLast<Float>()) { it.seriesNumber?.toFloatOrNull() }
        books.filter { it.seriesName == seriesName }.sortedWith(byNumber.thenBy { it.title })
    }

    suspend fun getCollections(): Result<List<com.enve.core.data.remote.dto.CollectionSummaryDto>> = runSuspendCatching {
        val response = api.getCollections()
        if (!response.isSuccessful) error("Failed to fetch Storyteller collections: HTTP ${response.code()}")
        decodeListBody<StorytellerCollectionDto>(response.body(), "collections").map { c ->
            com.enve.core.data.remote.dto.CollectionSummaryDto(
                id = storytellerCollectionId(c),
                name = c.name.trimToNull() ?: "Unknown Collection",
                bookCount = c.books.orEmpty().count { it.uuid.isNotBlank() },
            )
        }
    }

    suspend fun getCollectionBooks(collectionId: String): Result<List<Book>> = runSuspendCatching {
        val collectionResponse = api.getCollections()
        if (!collectionResponse.isSuccessful) error("Failed to fetch Storyteller collections: HTTP ${collectionResponse.code()}")
        val collection = decodeListBody<StorytellerCollectionDto>(collectionResponse.body(), "collections")
            .firstOrNull { storytellerCollectionId(it) == collectionId }
            ?: return@runSuspendCatching emptyList()
        val targetIds = collection.books.orEmpty()
            .mapNotNull { it.uuid.trimToNull() }
            .toSet()
        if (targetIds.isEmpty()) return@runSuspendCatching emptyList()
        getBooks().getOrThrow().filter { it.id in targetIds }
    }

    suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> = runSuspendCatching {
        val response = api.getSeries()
        if (!response.isSuccessful) error("Failed to fetch Storyteller series: HTTP ${response.code()}")
        decodeListBody<StorytellerSeriesDto>(response.body(), "series").map { series ->
            com.enve.core.data.remote.dto.SeriesSummaryDto(
                name = series.name.trimToNull() ?: "Unknown Series",
                bookCount = series.books.orEmpty().count { it.uuid.isNotBlank() },
                bookIds = series.books.orEmpty().mapNotNull { it.uuid.trimToNull() },
            )
        }
    }

    suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> = getBooks().map { books ->
        books.asSequence()
            .mapNotNull { it.author?.takeIf { author -> author.isNotBlank() } }
            .distinct()
            .map { author -> com.enve.core.data.remote.dto.AuthorSummaryDto(id = author, name = author) }
            .toList()
    }

    suspend fun getEbookDownloadUrl(bookId: String): String? {
        val serverUrl = scopedServerUrl()?.trimEnd('/') ?: return null
        val serverId = storytellerServerBookIdOrNull(bookId) ?: return null
        return "$serverUrl/api/v2/books/$serverId/files?format=ebook"
    }

    suspend fun getReadaloudDownloadUrl(bookId: String): String? {
        val serverUrl = scopedServerUrl()?.trimEnd('/') ?: return null
        val serverId = storytellerServerBookIdOrNull(bookId) ?: return null
        return "$serverUrl/api/v2/books/$serverId/files?format=readaloud"
    }

    suspend fun updateBookStatus(bookId: String, status: String): Result<Unit> = runSuspendCatching {
        val statusesResponse = api.getStatuses()
        if (!statusesResponse.isSuccessful) error("Failed to fetch Storyteller statuses: HTTP ${statusesResponse.code()}")
        val statusUuid = resolveStorytellerStatus(
            status = status,
            statuses = decodeListBody<StorytellerStatusDto>(statusesResponse.body(), "statuses"),
        )
            ?: error("Storyteller server does not expose a matching status for $status")
        val response = api.updateStatus(serverBookId(bookId), StorytellerStatusUpdateRequest(statusUuid))
        if (!response.isSuccessful && response.code() != 204) {
            error("Storyteller status update failed: HTTP ${response.code()}")
        }
    }

    suspend fun updatePersonalRating(bookId: String, rating: Int): Result<Unit> = runSuspendCatching {
        val response = api.updateRating(
            serverBookId(bookId),
            StorytellerRatingUpdateRequest(rating.coerceIn(1, 5)),
        )
        if (!response.isSuccessful && response.code() != 204) {
            error("Storyteller rating update failed: HTTP ${response.code()}")
        }
    }

    suspend fun updateBookMetadata(book: Book, metadata: ProviderMetadataUpdate): Result<Unit> = runSuspendCatching {
        val response = api.updateBook(serverBookId(book.id), metadata.toStorytellerMetadataUpdateBody())
        if (!response.isSuccessful) {
            error("Storyteller metadata update failed: HTTP ${response.code()}")
        }
    }

    suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runSuspendCatching {
        val serverId = serverBookId(book.id)
        val response = api.getAudioManifest(serverId)
        if (!response.isSuccessful) error("Storyteller manifest fetch failed: HTTP ${response.code()}")
        val manifest = response.body() ?: error("Storyteller manifest was empty")
        if (manifest.readingOrder.isEmpty()) error("Storyteller manifest has no audio tracks")

        val serverUrl = scopedServerUrl()?.trimEnd('/').orEmpty()
        val tracks = manifest.toTracks(serverUrl, serverId)
        val chapters = manifest.toChapters(tracks)
        val totalDurationSec = tracks.sumOf { it.durationMs } / 1000.0
        val serverCurrentTimeSec = fetchPosition(serverId).getOrThrow()
            ?.totalProgression()
            ?.let { (it * totalDurationSec).roundToLong() }

        ProviderPlaybackSession(
            sessionId = "storyteller-${book.id}",
            audioTracks = tracks,
            chapters = chapters,
            serverCurrentTimeSec = serverCurrentTimeSec,
        )
    }

    suspend fun syncAudiobookProgress(book: Book, currentTimeSec: Long, progressFraction: Float): Result<Unit> {
        val locator = JsonObject(
            mapOf(
                "href" to JsonPrimitive(""),
                "type" to JsonPrimitive("audio"),
                "locations" to JsonObject(
                    mapOf(
                        "totalProgression" to JsonPrimitive(progressFraction.coerceIn(0f, 1f)),
                        "fragments" to kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("t=$currentTimeSec"))),
                    )
                ),
            )
        )
        return updatePositionWithReconcile(book, locator, progressFraction)
    }

    suspend fun syncEbookProgress(bookId: String, percentage: Float, locator: String?): Result<Unit> {
        val locatorJson = locator?.takeIf { it.isNotBlank() }?.let { raw ->
            runCatching { json.parseToJsonElement(raw) }.getOrNull()
        } ?: JsonObject(
            mapOf(
                "href" to JsonPrimitive(""),
                "type" to JsonPrimitive("application/xhtml+xml"),
                "locations" to JsonObject(mapOf("totalProgression" to JsonPrimitive(percentage.coerceIn(0f, 1f)))),
            )
        )
        return updatePositionWithReconcile(Book(id = bookId, title = bookId, source = BookSource.STORYTELLER, readProgress = percentage), locatorJson, percentage)
    }

    suspend fun fetchAudiobookProgress(book: Book): Result<SyncSnapshot?> {
        val serverId = storytellerServerBookIdOrNull(book.id) ?: return Result.success(null)
        return fetchPosition(serverId).map { position ->
            val pct = position?.totalProgression()?.toFloat() ?: return@map null
            SyncSnapshot(
                percentage = pct,
                positionMs = ((book.duration.takeIf { it > 0L } ?: 0L) * pct * 1000L).roundToLong(),
                source = "Storyteller",
                updatedAt = position.timestamp.takeIf { it > 0L },
            )
        }
    }

    suspend fun fetchEbookProgress(book: Book): Result<SyncSnapshot?> {
        val serverId = storytellerServerBookIdOrNull(book.id) ?: return Result.success(null)
        return fetchPosition(serverId).map { position ->
            val pct = position?.totalProgression()?.toFloat() ?: return@map null
            SyncSnapshot(
                percentage = pct,
                locatorJson = position.ebookLocatorJsonString(),
                source = "Storyteller",
                updatedAt = position.timestamp.takeIf { it > 0L },
            )
        }
    }

    fun invalidateListCaches() = Unit

    private suspend fun fetchPosition(bookId: String): Result<StorytellerPositionResponse?> = runSuspendCatching {
        val response = api.getPosition(bookId)
        if (response.code() == 404 || response.code() == 204) return@runSuspendCatching null
        if (!response.isSuccessful) error("Storyteller position fetch failed: HTTP ${response.code()}")
        response.body()
    }

    private suspend fun updatePositionWithReconcile(book: Book, locator: JsonElement, localProgress: Float): Result<Unit> = runSuspendCatching {
        val serverId = serverBookId(book.id)
        val timestamp = System.currentTimeMillis()
        val response = api.updatePosition(serverId, StorytellerPositionRequest(locator, timestamp))
        if (response.code() == 409) {

            if (localProgress <= 0.005f) {
                forcePositionUpdate(serverId, locator)
            } else {
                reconcilePositionConflict(serverId, localProgress, timestamp, locator)
            }
            return@runSuspendCatching
        }
        if (!response.isSuccessful && response.code() != 204) {
            error("Storyteller progress update failed: HTTP ${response.code()}")
        }
    }

    private suspend fun reconcilePositionConflict(serverId: String, localProgress: Float, localTimestamp: Long, locator: JsonElement) {
        val server = fetchPosition(serverId).getOrThrow() ?: return
        val serverProgress = server.totalProgression()?.toFloat() ?: 0f
        val serverIsFurther = serverProgress > localProgress + 0.005f
        val progressEqual = kotlin.math.abs(serverProgress - localProgress) <= 0.005f
        val serverIsNewerByTime = progressEqual && server.timestamp >= localTimestamp
        if (serverIsFurther || serverIsNewerByTime) return
        val freshTimestamp = maxOf(server.timestamp + 1L, System.currentTimeMillis())
        api.updatePosition(serverId, StorytellerPositionRequest(locator, freshTimestamp))
    }

    private suspend fun forcePositionUpdate(serverId: String, locator: JsonElement) {
        val server = fetchPosition(serverId).getOrThrow()
        val freshTimestamp = maxOf((server?.timestamp ?: 0L) + 1L, System.currentTimeMillis())
        api.updatePosition(serverId, StorytellerPositionRequest(locator, freshTimestamp))
    }

    private fun StorytellerAudioManifestDto.toTracks(serverUrl: String, bookId: String): List<AudioTrack> {
        var cumulativeMs = 0L
        return readingOrder.mapIndexed { index, item ->
            val durationMs = ((item.duration ?: 0.0) * 1000.0).roundToLong().coerceAtLeast(0L)
            val contentUrl = if (item.href.startsWith("http://", true) || item.href.startsWith("https://", true)) {
                item.href
            } else {
                "$serverUrl/api/v2/books/$bookId/listen/${Uri.encode(item.href, "/")}"
            }
            AudioTrack(
                index = index,
                fileName = item.href.substringAfterLast('/').ifBlank { "Track ${index + 1}" },
                title = item.href.substringAfterLast('/').ifBlank { "Track ${index + 1}" },
                durationMs = durationMs,
                cumulativeStartMs = cumulativeMs,
                contentUrl = contentUrl,
            ).also {
                cumulativeMs += durationMs
            }
        }
    }

    private fun StorytellerAudioManifestDto.toChapters(tracks: List<AudioTrack>): List<Chapter> {
        val totalMs = tracks.sumOf { it.durationMs }
        val offsetsByHref = readingOrder.mapIndexed { index, item -> item.href to tracks.getOrNull(index)?.cumulativeStartMs.orZero() }.toMap()
        val fromToc = toc.orEmpty().mapIndexed { index, tocItem ->
            val startMs = tocItem.href?.substringBefore('#')?.let { offsetsByHref[it] }
                ?: if (index == 0) 0L else null
            val nextMs = toc.orEmpty().getOrNull(index + 1)?.href?.substringBefore('#')?.let { offsetsByHref[it] }
                ?: totalMs
            if (startMs == null) null else Chapter(
                index = index,
                title = tocItem.title ?: "Chapter ${index + 1}",
                startTime = startMs / 1000L,
                endTime = maxOf(startMs, nextMs) / 1000L,
            )
        }.filterNotNull()

        val distinctStarts = fromToc.map { it.startTime }.toSet().size
        return if ((fromToc.size < 2 && tracks.size > 1) || (fromToc.size >= 2 && distinctStarts <= 1)) {
            tracks.mapIndexed { index, track ->
                Chapter(
                    index = index,
                    title = "Chapter ${index + 1}",
                    startTime = track.cumulativeStartMs / 1000L,
                    endTime = (track.cumulativeStartMs + track.durationMs) / 1000L,
                )
            }
        } else {
            fromToc
        }
    }

    private fun resolveStorytellerStatus(status: String, statuses: List<StorytellerStatusDto>): String? {
        val candidates = when (status.uppercase()) {
            "READ" -> listOf("Read", "Finished", "Complete", "Completed")
            "IN_PROGRESS" -> listOf("Reading", "In Progress", "Started")
            "UNREAD" -> listOf("Unread", "Not Started", "To Read", "Want to Read")
            "ABANDONED" -> listOf("Abandoned", "Dropped", "Did Not Finish")
            else -> listOf(status)
        }
        return statuses.firstOrNull { item ->
            item.uuid.isNotBlank() && candidates.any { it.equals(item.name, ignoreCase = true) }
        }?.uuid
            ?: statuses.firstOrNull { item ->
                item.uuid.isNotBlank() && status.equals(item.name, ignoreCase = true)
            }?.uuid
            ?: if (status.equals("UNREAD", ignoreCase = true)) {
                statuses.firstOrNull { it.uuid.isNotBlank() && it.isDefault == true }?.uuid
            } else {
                null
            }
    }

    private fun serverBookId(bookId: String): String = storytellerServerBookIdOrThrow(bookId)

    private fun StorytellerPositionResponse.totalProgression(): Double? {
        val element = normalizedLocatorElement() ?: return null
        return runCatching {
            element.jsonObject["locations"]
                ?.jsonObject
                ?.get("totalProgression")
                ?.jsonPrimitive
                ?.doubleOrNull
        }.getOrNull()
    }

    private fun StorytellerPositionResponse.locatorJsonString(): String? = normalizedLocatorElement()?.let { json.encodeToString(it) }

    private fun StorytellerPositionResponse.ebookLocatorJsonString(): String? {
        val element = normalizedLocatorElement() as? JsonObject ?: return null
        val href = element["href"]?.jsonPrimitive?.contentOrNull
        val type = element["type"]?.jsonPrimitive?.contentOrNull?.lowercase()
        if (href.isNullOrBlank()) return null
        if (type != null && (type.startsWith("audio") || type.contains("mpeg") || type.contains("mp3"))) return null
        return json.encodeToString(element)
    }

    private fun StorytellerPositionResponse.normalizedLocatorElement(): JsonElement? {
        val raw = locator ?: return null
        val primitive = raw as? JsonPrimitive
        val content = primitive?.contentOrNull
        return if (content != null && (content.trim().startsWith("{") || content.trim().startsWith("["))) {
            runCatching { json.parseToJsonElement(content) }.getOrNull() ?: raw
        } else {
            raw
        }
    }

    private fun Long?.orZero(): Long = this ?: 0L

    companion object {
        private const val TAG = "StorytellerRepository"
        private const val STORYTELLER_LIBRARY_ID = "storyteller-library"
    }
}

internal data class LenientStorytellerArray<T>(
    val values: List<T>,
    val skippedCount: Int,
)

internal inline fun <reified T> decodeLenientStorytellerArray(
    json: Json,
    payload: String,
): LenientStorytellerArray<T> {
    val root = json.parseToJsonElement(payload.ifBlank { "[]" })
    val items = root as? JsonArray ?: error("Storyteller response was not a JSON array")
    val values = ArrayList<T>(items.size)
    var skippedCount = 0
    items.forEach { item ->
        val decoded = runCatching { json.decodeFromJsonElement(serializer<T>(), item) }.getOrNull()
        if (decoded != null) {
            values += decoded
        } else {
            skippedCount += 1
        }
    }
    return LenientStorytellerArray(values = values, skippedCount = skippedCount)
}

internal fun mapStorytellerBook(
    book: StorytellerBookDto,
    serverUrl: String?,
): Book? {
    val hasAudiobook = book.audiobook != null
    val hasEbook = book.ebook != null
    val hasReadaloudEntry = book.readaloud != null
    val isReadaloudReady = book.readaloud?.isReady == true
    if (!hasAudiobook && !hasEbook) return null

    val mediaType = when {
        hasReadaloudEntry -> AppMediaType.EBOOK
        hasEbook && !hasAudiobook -> AppMediaType.EBOOK
        else -> AppMediaType.AUDIOBOOK
    }

    val resolvedTitle = resolveStorytellerTitle(book)
    val progress = book.position?.totalProgression()?.toFloat()?.coerceIn(0f, 1f) ?: 0f
    val createdAtMs = parseStorytellerDate(book.createdAt)
    val publishedYear = book.publicationDate?.take(4)?.toIntOrNull()
    val categories = book.tags.orEmpty()
        .mapNotNull { it.name.trimToNull() }
    val seriesRelation = book.series.orEmpty().firstOrNull { it.name.isNotBlank() || it.uuid.isNotBlank() }
    val resolvedId = storytellerResolvedBookId(book)
    val coverServerId = storytellerServerBookIdOrNull(resolvedId)

    return Book(
        id = resolvedId,
        title = resolvedTitle,
        subtitle = book.subtitle.trimToNull(),
        author = book.authors.orEmpty().firstNotNullOfOrNull { it.name.trimToNull() },
        narrator = book.narrators.orEmpty().firstNotNullOfOrNull { it.name.trimToNull() },
        description = book.description.trimToNull(),
        coverUrl = storytellerCoverUrl(serverUrl, coverServerId, hasAudiobook),
        source = BookSource.STORYTELLER,
        mediaType = mediaType,
        readProgress = progress,
        epubProgress = if (mediaType == AppMediaType.EBOOK || isReadaloudReady) progress else null,
        epubLocator = book.position?.ebookLocatorJsonString(json = storytellerJson),
        readAlongAvailable = isReadaloudReady,
        hasEbook = hasEbook || isReadaloudReady,
        hasAudio = hasAudiobook || isReadaloudReady,
        isFinished = book.status?.name?.equals("Read", ignoreCase = true) == true,
        libraryId = STORYTELLER_LIBRARY_ID,
        addedOn = createdAtMs,
        lastReadTime = book.position?.timestamp ?: 0L,
        seriesName = seriesRelation?.name?.trimToNull() ?: inferredStorytellerSeriesName(book, resolvedTitle),
        seriesNumber = seriesRelation?.position?.let { pos ->
            if (pos % 1.0 == 0.0) pos.toInt().toString() else pos.toString()
        },
        categories = categories,
        personalRating = book.rating?.toFloat(),
        publishedDate = book.publicationDate.trimToNull() ?: publishedYear?.toString(),
        language = book.language.trimToNull(),
        primaryFileType = if (hasEbook) {
            "EPUB"
        } else {
            book.audiobook?.filepath?.substringAfterLast('.', "")?.uppercase().orEmpty().ifBlank { null }
        },
    )
}

internal fun storytellerResolvedBookId(book: StorytellerBookDto): String =
    book.uuid.trimToNull() ?: storytellerSyntheticId(
        kind = "book",
        book.audiobook?.filepath,
        book.ebook?.filepath,
        book.readaloud?.filepath,
        book.title,
        book.subtitle,
        book.createdAt,
        book.publicationDate,
    )

internal fun storytellerServerBookIdOrNull(bookId: String): String? {
    val trimmed = bookId.trim()
    if (trimmed.isBlank()) return null
    if (trimmed.startsWith(STORYTELLER_SYNTHETIC_ID_PREFIX)) return null
    return trimmed.removePrefix("storyalign_").takeIf { it.isNotBlank() }
}

private fun storytellerServerBookIdOrThrow(bookId: String): String =
    storytellerServerBookIdOrNull(bookId) ?: error("Storyteller book is missing its server id")

private fun storytellerCollectionId(collection: StorytellerCollectionDto): String =
    collection.uuid.trimToNull() ?: storytellerSyntheticId(
        kind = "collection",
        collection.name,
        collection.description,
    )

private fun storytellerCoverUrl(
    serverUrl: String?,
    bookId: String?,
    audiobook: Boolean,
): String? {
    val normalizedServerUrl = serverUrl?.trimEnd('/').takeIf { !it.isNullOrBlank() } ?: return null
    val resolvedBookId = bookId?.takeIf { it.isNotBlank() } ?: return null
    val audioParam = if (audiobook) "&audio=true" else ""
    return "$normalizedServerUrl/api/v2/books/$resolvedBookId/cover?w=400$audioParam"
}

private fun resolveStorytellerTitle(book: StorytellerBookDto): String {
    val cleanTitle = book.title.trimToNull()
    val titleIsGeneric = cleanTitle == null || cleanTitle.lowercase() in GENERIC_FILE_TITLES
    if (titleIsGeneric) {
        storytellerAncestorFolderNames(book)
            .firstOrNull { it.lowercase() !in GENERIC_FILE_TITLES }
            ?.let { return it }
        return storytellerFolderNameTitle(book) ?: cleanTitle ?: "Unknown"
    }
    return cleanTitle
}

private fun storytellerAncestorFolderNames(book: StorytellerBookDto): Sequence<String> {
    val filepath = book.audiobook?.filepath ?: book.ebook?.filepath ?: return emptySequence()
    val segments = filepath.trim('/').split('/').dropLast(1).mapNotNull { it.trimToNull() }
    return segments.asReversed().asSequence()
}

private fun inferredStorytellerSeriesName(book: StorytellerBookDto, resolvedTitle: String): String? {
    val parent = storytellerParentFolderName(book)
    val rawTitle = book.title.trimToNull() ?: return null
    return if (parent != null && rawTitle == parent && resolvedTitle != rawTitle) rawTitle else null
}

private fun storytellerParentFolderName(book: StorytellerBookDto): String? {
    val filepath = book.audiobook?.filepath ?: book.ebook?.filepath ?: return null
    val trimmed = filepath.trim('/').substringBeforeLast('/', missingDelimiterValue = "")
    return trimmed.substringAfterLast('/').trimToNull()
}

private fun storytellerFolderNameTitle(book: StorytellerBookDto): String? {
    val filepath = book.audiobook?.filepath ?: book.ebook?.filepath ?: return null
    var name = filepath.trim('/').substringAfterLast('/').trimToNull() ?: return null
    val suffix = book.suffix.trimToNull().orEmpty()
    if (suffix.isNotEmpty() && name.endsWith(suffix)) {
        name = name.dropLast(suffix.length).trim()
    }
    return name.trimToNull()
}

private fun parseStorytellerDate(raw: String?): Long {
    if (raw.isNullOrBlank()) return 0L
    return runCatching {
        LocalDateTime.parse(raw.replace(' ', 'T')).toInstant(ZoneOffset.UTC).toEpochMilli()
    }.getOrElse {
        runCatching {
            LocalDate.parse(raw.take(10)).atStartOfDay().toInstant(ZoneOffset.UTC).toEpochMilli()
        }.getOrDefault(0L)
    }
}

private fun storytellerSyntheticId(kind: String, vararg fields: String?): String {
    val seed = fields.mapNotNull { it.trimToNull() }.joinToString("|").ifBlank { kind }
    val uuid = UUID.nameUUIDFromBytes("$kind|$seed".toByteArray())
    return "$STORYTELLER_SYNTHETIC_ID_PREFIX$kind-$uuid"
}

private fun String?.trimToNull(): String? = this?.trim()?.takeIf { it.isNotEmpty() }

private fun StorytellerPositionResponse.totalProgression(): Double? {
    val element = normalizedLocatorElement() ?: return null
    return runCatching {
        element.jsonObject["locations"]
            ?.jsonObject
            ?.get("totalProgression")
            ?.jsonPrimitive
            ?.doubleOrNull
    }.getOrNull()
}

private fun StorytellerPositionResponse.ebookLocatorJsonString(json: Json): String? {
    val element = normalizedLocatorElement() as? JsonObject ?: return null
    val href = element["href"]?.jsonPrimitive?.contentOrNull
    val type = element["type"]?.jsonPrimitive?.contentOrNull?.lowercase()
    if (href.isNullOrBlank()) return null
    if (type != null && (type.startsWith("audio") || type.contains("mpeg") || type.contains("mp3"))) return null
    return json.encodeToString(element)
}

private fun StorytellerPositionResponse.normalizedLocatorElement(): JsonElement? {
    val raw = locator ?: return null
    val primitive = raw as? JsonPrimitive
    val content = primitive?.contentOrNull
    return if (content != null && (content.trim().startsWith("{") || content.trim().startsWith("["))) {
        runCatching { storytellerJson.parseToJsonElement(content) }.getOrNull() ?: raw
    } else {
        raw
    }
}

private val storytellerJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
    encodeDefaults = true
}

private const val STORYTELLER_LIBRARY_ID = "storyteller-library"
private const val STORYTELLER_SYNTHETIC_ID_PREFIX = "storyteller-missing-"

private val GENERIC_FILE_TITLES = setOf(
    "audio",
    "audiobook",
    "ebook",
    "readalong",
    "read-along",
    "book",
    "books",
    "library",
    "media",
)

internal fun ProviderMetadataUpdate.toStorytellerMetadataUpdateBody(): RequestBody {
    val titleValue = title.clean()
        ?: throw IllegalArgumentException("Storyteller title cannot be blank")
    val builder = MultipartBody.Builder().setType(MultipartBody.FORM)

    builder.addJsonScalar("title", titleValue)
    builder.addJsonScalar("subtitle", subtitle.clean())
    builder.addJsonScalar("language", language.clean())
    builder.addJsonScalar("description", description.clean())
    builder.addJsonScalar("publicationDate", publishedDate.toStorytellerPublicationDate())
    builder.addJsonList("authors", author.toNameList())
    builder.addJsonList("narrators", narrator.toNameList())
    builder.addJsonList("tags", categories.mapNotNull { it.clean() })
    builder.addJsonList(
        "series",
        seriesName.clean()?.let { name ->
            listOf(
                buildJsonObject(
                    "name" to name,
                    "position" to seriesNumber.clean()?.toDoubleOrNull(),
                )
            )
        }.orEmpty(),
    )

    return builder.build()
}

private fun MultipartBody.Builder.addJsonScalar(field: String, value: String?) {
    addFormDataPart("fields", field)
    addFormDataPart(field, value.toJsonLiteral())
}

private fun MultipartBody.Builder.addJsonList(field: String, values: List<Any?>) {
    addFormDataPart("fields", field)
    values.forEach { value ->
        addFormDataPart(field, value.toJsonLiteral())
    }
}

private fun buildJsonObject(vararg pairs: Pair<String, Any?>): Map<String, Any?> =
    linkedMapOf(*pairs)

private fun Any?.toJsonLiteral(): String = when (this) {
    null -> "null"
    is String -> Json.encodeToString(this)
    is Number -> toString()
    is Boolean -> toString()
    is Map<*, *> -> entries.joinToString(separator = ",", prefix = "{", postfix = "}") { (key, value) ->
        "${Json.encodeToString(key as String)}:${value.toJsonLiteral()}"
    }
    else -> Json.encodeToString(toString())
}

private fun String?.toStorytellerPublicationDate(): String? {
    val value = clean() ?: return null
    return when {
        value.matches(Regex("""\d{4}""")) ->
            LocalDate.of(value.toInt(), 1, 1).atStartOfDay().toInstant(ZoneOffset.UTC).toStorytellerIsoString()
        value.matches(Regex("""\d{4}-\d{2}""")) ->
            "${value}-01".parseStorytellerLocalDate().atStartOfDay().toInstant(ZoneOffset.UTC).toStorytellerIsoString()
        value.matches(Regex("""\d{4}-\d{2}-\d{2}""")) ->
            value.parseStorytellerLocalDate().atStartOfDay().toInstant(ZoneOffset.UTC).toStorytellerIsoString()
        else -> value.parseStorytellerInstant()
    }
}

private fun String.parseStorytellerLocalDate(): LocalDate =
    runCatching { LocalDate.parse(this) }
        .getOrElse { throw IllegalArgumentException("Storyteller publication date must be YYYY, YYYY-MM, YYYY-MM-DD, or ISO-8601") }

private fun String.parseStorytellerInstant(): String {
    return try {
        Instant.parse(this).toStorytellerIsoString()
    } catch (_: DateTimeParseException) {
        try {
            OffsetDateTime.parse(this, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toStorytellerIsoString()
        } catch (_: DateTimeParseException) {
            throw IllegalArgumentException("Storyteller publication date must be YYYY, YYYY-MM, YYYY-MM-DD, or ISO-8601")
        }
    }
}

private fun Instant.toStorytellerIsoString(): String =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'")
        .withZone(ZoneOffset.UTC)
        .format(this)

private fun String?.toNameList(): List<String> =
    clean()
        ?.split(",")
        ?.mapNotNull { it.clean() }
        .orEmpty()

private fun String?.clean(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
