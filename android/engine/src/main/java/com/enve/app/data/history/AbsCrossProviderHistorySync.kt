package com.enve.app.data.history

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.audiobookshelf.listening.AbsCrossProviderHistory
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.repository.GrimmoryRepository
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
internal data class AbsHistoryLink(
    val sourceBookKey: String,
    val sourceConnectionId: String,
    val sourceUsername: String,
    val sourceAccountId: String,
    val sourceServerUrl: String,
    val targetBookKey: String,
    val targetConnectionId: String,
    val targetAccountId: String,
    val targetServerUrl: String,
    val confirmedAtMs: Long,
    val includePast: Boolean = false,
)

internal fun AbsHistoryLink.accepts(session: HistorySession): Boolean =
    session.bookKey == sourceBookKey && session.connectionId == sourceConnectionId &&
        (includePast || session.startTimeMs >= confirmedAtMs)

@Singleton
class AbsCrossProviderHistorySync @Inject constructor(
    @ApplicationContext context: Context,
    private val connections: ConnectionRegistry,
    private val books: BookCacheDao,
    private val history: HistorySessionStore,
    private val abs: AudiobookshelfRepository,
    private val grimmory: GrimmoryRepository,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore = com.enve.core.data.local.ProfileServerSyncStore(context, locations),
) {
    private val prefs = context.getSharedPreferences(if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "abs_cross_provider_history" else "abs_cross_provider_history_profile_${locations.profileId}", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(AbsHistoryLink.serializer())
    private val mutex = Mutex()

    suspend fun link(source: Book, target: Book, includePast: Boolean): Boolean = mutex.withLock {
        if (source.source != BookSource.GRIMMORY || source.mediaType != AppMediaType.AUDIOBOOK ||
            target.source != BookSource.AUDIOBOOKSHELF || target.mediaType != AppMediaType.AUDIOBOOK ||
            target.episodeId != null || source.connectionId.isNullOrBlank() || target.connectionId.isNullOrBlank() ||
            source.connectionId == target.connectionId
        ) return@withLock false
        val sourceConnection = connections.getConnectionsSync().firstOrNull {
            it.id == source.connectionId && it.enabled && it.source == BookSource.GRIMMORY
        } ?: return@withLock false
        val targetConnection = connections.getConnectionsSync().firstOrNull {
            it.id == target.connectionId && it.enabled && it.source == BookSource.AUDIOBOOKSHELF
        } ?: return@withLock false
        if (books.getByCacheKey(source.uniqueKey)?.toBook()?.id != source.id ||
            books.getByCacheKey(target.uniqueKey)?.toBook()?.id != target.id
        ) return@withLock false
        val sourceAccountId = withContext(ConnectionScope.asContextElement(sourceConnection.id)) {
            grimmory.currentUserId().getOrNull()
        } ?: return@withLock false
        val accountId = withContext(ConnectionScope.asContextElement(targetConnection.id)) {
            abs.verifiedHistoryAccountAndItem(target).getOrNull()
        } ?: return@withLock false
        val link = AbsHistoryLink(
            source.uniqueKey, sourceConnection.id, sourceConnection.username, sourceAccountId, sourceConnection.serverUrl,
            target.uniqueKey, targetConnection.id, accountId, targetConnection.serverUrl,
            System.currentTimeMillis(), includePast,
        )
        val current = load()
        val updated = current.filterNot { it.sourceBookKey == source.uniqueKey } + link
        if (!prefs.edit().putString("links", json.encodeToString(serializer, updated)).commit()) return@withLock false
        if (current.any { it.sourceBookKey == source.uniqueKey && it.targetBookKey != target.uniqueKey }) {
            abs.removePendingCrossProviderHistory(source.uniqueKey)
        }
        try {
            sync(link)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
        }
        true
    }

    suspend fun unlink(source: Book): Boolean = mutex.withLock {
        val current = load()
        val updated = current.filterNot { it.sourceBookKey == source.uniqueKey }
        if (current.size == updated.size) return@withLock false
        if (!prefs.edit().putString("links", json.encodeToString(serializer, updated)).commit()) return@withLock false
        abs.removePendingCrossProviderHistory(source.uniqueKey)
        true
    }

    fun linkedTargetKey(source: Book): String? = load().firstOrNull { it.sourceBookKey == source.uniqueKey }?.targetBookKey

    suspend fun onSession(session: HistorySession) = mutex.withLock {
        if (!serverSync.accepts(session.startTimeMs)) return@withLock
        val link = load().firstOrNull { it.sourceBookKey == session.bookKey } ?: return@withLock
        sync(link, listOf(session))
    }

    suspend fun syncAll() = mutex.withLock {
        if (!serverSync.isEnabled) return@withLock
        load().forEach { link ->
            try {
                sync(link)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    private suspend fun sync(link: AbsHistoryLink, sessions: List<HistorySession> = history.sessions.value) {
        if (!serverSync.isEnabled) return
        val sourceConnection = connections.getConnectionsSync().firstOrNull {
            it.id == link.sourceConnectionId && it.enabled && it.source == BookSource.GRIMMORY &&
                it.username == link.sourceUsername && it.serverUrl == link.sourceServerUrl
        } ?: return
        val currentSourceAccount = withContext(ConnectionScope.asContextElement(sourceConnection.id)) {
            grimmory.currentUserId().getOrNull()
        }
        if (currentSourceAccount != link.sourceAccountId) {
            if (currentSourceAccount != null) {
                val remaining = load().filterNot { it == link }
                if (prefs.edit().putString("links", json.encodeToString(serializer, remaining)).commit()) {
                    abs.removePendingCrossProviderHistory(link.sourceBookKey)
                }
            }
            return
        }
        val targetConnection = connections.getConnectionsSync().firstOrNull {
            it.id == link.targetConnectionId && it.enabled && it.source == BookSource.AUDIOBOOKSHELF &&
                it.serverUrl == link.targetServerUrl
        } ?: return
        val target = books.getByCacheKey(link.targetBookKey)?.toBook()?.takeIf {
            it.source == BookSource.AUDIOBOOKSHELF && it.connectionId == targetConnection.id &&
                it.mediaType == AppMediaType.AUDIOBOOK && it.episodeId == null
        } ?: return
        withContext(ConnectionScope.asContextElement(targetConnection.id)) {
            if (abs.verifiedHistoryAccountAndItem(target).getOrNull() != link.targetAccountId) return@withContext
            sessions.asSequence()
                .filter(link::accepts)
                .filter { serverSync.accepts(it.startTimeMs) }
                .forEach { source ->
                    val converted = AbsCrossProviderHistory.session(
                        source, targetConnection.id, link.targetAccountId, target.id,
                        target.title, target.author, target.duration, 0.0,
                        historicalBackfill = source.startTimeMs < link.confirmedAtMs,
                    ) ?: return@forEach
                    abs.enqueueCrossProviderHistory(converted)
                }
            abs.uploadLocalListening().getOrThrow()
        }
    }

    private fun load(): List<AbsHistoryLink> = prefs.getString("links", null)
        ?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() }
        .orEmpty()
}
