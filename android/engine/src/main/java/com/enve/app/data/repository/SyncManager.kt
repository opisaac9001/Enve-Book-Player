package com.enve.app.data.repository

import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.local.PendingProgressPushDao
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.repository.grimmory.grimmoryServerBookId
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.core.data.util.runSuspendCatching
import kotlinx.coroutines.CancellationException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SyncManager @Inject constructor(
    private val repository: GrimmoryRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    private val pendingProgressDao: PendingProgressPushDao,
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
) {
    private data class QueueTarget(val source: BookSource, val connectionKey: String)

    suspend fun pushEbookProgress(bookId: String, percentage: Float, cfi: String? = null) {
        if (!serverSync.isEnabled || percentage <= 0f) return
        if (currentSource() != BookSource.GRIMMORY || accessTokenForCurrentConnection().isNullOrBlank()) return
        if (bookId.grimmoryServerBookId().toLongOrNull() == null) return
        val target = queueTarget()
        val requestStartedAt = System.currentTimeMillis()
        val result = repository.syncEbookProgress(bookId, percentage, cfi)
        result.exceptionOrNull()?.let { if (it is CancellationException) throw it }
        reconcilePending(bookId, AppMediaType.EBOOK, percentage, target, result, requestStartedAt)
    }

    private suspend fun reconcilePending(
        bookId: String,
        mediaType: AppMediaType,
        percentage: Float,
        queueTarget: QueueTarget,
        outcome: Result<Unit>,
        requestStartedAt: Long,
    ) {
        if (!serverSync.accepts(requestStartedAt)) return
        runSuspendCatching {
            if (outcome.isSuccess) {
                val queued = pendingProgressDao.get(bookId, queueTarget.source.name, queueTarget.connectionKey)
                if (queued != null && queued.createdAt <= requestStartedAt) {
                    pendingProgressDao.deleteIfUnchanged(
                        bookId, queued.source, queued.connectionKey, queued.createdAt, queued.percentage,
                    )
                }
            } else {
                val now = System.currentTimeMillis()
                val existing = pendingProgressDao.get(
                    bookId = bookId,
                    source = queueTarget.source.name,
                    connectionKey = queueTarget.connectionKey,
                )
                if (existing != null && existing.createdAt > requestStartedAt) return@runSuspendCatching
                pendingProgressDao.upsert(
                    PendingProgressPush(
                        bookId = bookId,
                        source = queueTarget.source.name,
                        connectionKey = queueTarget.connectionKey,
                        mediaType = mediaType.name,
                        percentage = percentage,
                        isFinished = percentage >= FINISHED_PROGRESS_THRESHOLD,
                        createdAt = maxOf(now, (existing?.createdAt ?: 0L) + 1L),
                        attempts = (existing?.attempts ?: 0) + 1,
                        lastAttemptAt = now,
                        lastError = outcome.exceptionOrNull()?.message?.take(200),
                    )
                )
            }
        }
    }

    private fun queueTarget(): QueueTarget {
        val connection = currentConnection()
        return QueueTarget(
            source = connection?.source ?: prefs.getActiveBookSourceSync(),
            connectionKey = connection?.id.orEmpty(),
        )
    }

    private fun currentConnection(): ProviderConnection? {
        val connectionId = ConnectionScope.getConnectionId() ?: prefs.getActiveConnectionIdSync()
        if (connectionId.isNullOrBlank()) return null
        return connectionRegistry.getConnectionsSync().firstOrNull { it.id == connectionId }
    }

    private fun currentSource(): BookSource {
        return currentConnection()?.source ?: prefs.getActiveBookSourceSync()
    }

    private fun accessTokenForCurrentConnection(): String? {
        val connectionId = currentConnection()?.id
        val token = connectionId?.let { vault.get(CredentialVault.accessTokenKey(it)) }
            ?: prefs.getAccessTokenSync()
        return token?.takeIf { it.isNotBlank() }
    }
}
