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
import com.enve.app.data.remote.GrimmoryApi
import com.enve.app.data.remote.dto.*
import com.enve.core.data.remote.dto.*
import com.enve.core.data.sync.CfiLocatorConverter
import com.enve.app.data.sync.DeviceIdentity
import com.enve.app.data.sync.KosyncClient
import com.enve.app.data.sync.KosyncHttpException
import com.enve.app.data.sync.KosyncProgressRequest
import com.enve.app.data.sync.PartialMd5
import com.enve.app.data.repository.grimmory.grimmoryServerBookId
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.File
import java.time.Instant
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

data class RemoteSyncResult(
    val percentage: Float,
    val cfi: String? = null,
    val positionMs: Long? = null,
    val source: String,
)

enum class SkipReason {
    NoLocalProgress,
    NoFileHash,
    NoKosyncCreds,
    NoGrimmoryBookId,
    GrimmoryNotLoggedIn,
}

sealed interface SourceOutcome<out T> {
    data class Ok<T>(val value: T?) : SourceOutcome<T>
    data class Skipped(val reason: SkipReason) : SourceOutcome<Nothing>
    data class Failure(val error: Throwable) : SourceOutcome<Nothing>
}

data class PushResult(
    val grimmory: SourceOutcome<Unit>,
    val kosync: SourceOutcome<Unit>,
) {
    val anySucceeded: Boolean get() = grimmory is SourceOutcome.Ok || kosync is SourceOutcome.Ok
    val anyFailed: Boolean get() = grimmory is SourceOutcome.Failure || kosync is SourceOutcome.Failure

    val firstError: Throwable?
        get() = listOfNotNull(
            (grimmory as? SourceOutcome.Failure)?.error,
            (kosync as? SourceOutcome.Failure)?.error,
        ).firstOrNull()

    companion object {
        val NothingToPush = PushResult(
            grimmory = SourceOutcome.Skipped(SkipReason.NoLocalProgress),
            kosync = SourceOutcome.Skipped(SkipReason.NoLocalProgress),
        )
    }
}

data class SyncResult(
    val synced: Int = 0,
    val pulled: Int = 0,
    val pushed: Int = 0,
    val errors: Int = 0,
)

@Singleton
class SyncManager @Inject constructor(
    private val api: GrimmoryApi,
    private val repository: GrimmoryRepository,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
    private val kosyncClient: KosyncClient,
    private val deviceIdentity: DeviceIdentity,
    private val pendingProgressDao: PendingProgressPushDao,
) {
    private val pendingMaxAgeMs = TimeUnit.DAYS.toMillis(7)
    private data class QueueTarget(val source: BookSource, val connectionKey: String)

    suspend fun pushEbookProgress(
        bookId: String,
        percentage: Float,
        cfi: String? = null,
        localFile: File? = null,
    ): PushResult = coroutineScope {
        if (percentage <= 0f) return@coroutineScope PushResult.NothingToPush
        val queueTarget = queueTarget()

        val grimmoryDeferred = async { pushEbookToGrimmory(bookId, percentage, cfi) }
        val kosyncDeferred = async { pushEbookToKosync(bookId, percentage, cfi, localFile) }

        val grimmoryOutcome = grimmoryDeferred.await()
        reconcilePending(bookId, AppMediaType.EBOOK, percentage, queueTarget, grimmoryOutcome)
        PushResult(grimmory = grimmoryOutcome, kosync = kosyncDeferred.await())
    }

    suspend fun pushAudiobookProgress(
        bookId: String,
        percentage: Float,
        positionMs: Long,
        trackIndex: Int,
    ): PushResult = coroutineScope {
        if (percentage <= 0f) return@coroutineScope PushResult.NothingToPush
        val queueTarget = queueTarget()

        val grimmoryDeferred = async { pushAudiobookToGrimmory(bookId, percentage, positionMs, trackIndex) }

        val kosyncOutcome = SourceOutcome.Skipped(SkipReason.NoFileHash)

        val grimmoryOutcome = grimmoryDeferred.await()
        reconcilePending(bookId, AppMediaType.AUDIOBOOK, percentage, queueTarget, grimmoryOutcome)
        PushResult(grimmory = grimmoryOutcome, kosync = kosyncOutcome)
    }

    private suspend fun reconcilePending(
        bookId: String,
        mediaType: AppMediaType,
        percentage: Float,
        queueTarget: QueueTarget,
        outcome: SourceOutcome<Unit>,
    ) {
        runCatching {
            when (outcome) {
                is SourceOutcome.Ok -> pendingProgressDao.delete(
                    bookId = bookId,
                    source = queueTarget.source.name,
                    connectionKey = queueTarget.connectionKey,
                )
                is SourceOutcome.Failure -> {
                    val now = System.currentTimeMillis()
                    val existing = pendingProgressDao.get(
                        bookId = bookId,
                        source = queueTarget.source.name,
                        connectionKey = queueTarget.connectionKey,
                    )
                    pendingProgressDao.upsert(
                        PendingProgressPush(
                            bookId = bookId,
                            source = queueTarget.source.name,
                            connectionKey = queueTarget.connectionKey,
                            mediaType = mediaType.name,
                            percentage = percentage,
                            isFinished = percentage >= 0.99f,
                            createdAt = existing?.createdAt ?: now,
                            attempts = (existing?.attempts ?: 0) + 1,
                            lastAttemptAt = now,
                            lastError = outcome.error.message?.take(200),
                        )
                    )
                }
                is SourceOutcome.Skipped -> Unit
            }
        }
    }

    suspend fun flushPendingPushes(): Int {
        runCatching {
            pendingProgressDao.pruneOlderThan(System.currentTimeMillis() - pendingMaxAgeMs)
        }
        val pending = runCatching { pendingProgressDao.getAll() }.getOrDefault(emptyList())
        if (pending.isEmpty()) return 0

        var flushed = 0
        for (entry in pending) {
            val queueTarget = QueueTarget(
                source = runCatching { BookSource.valueOf(entry.source) }.getOrDefault(BookSource.GRIMMORY),
                connectionKey = entry.connectionKey,
            )
            val mediaType = runCatching { AppMediaType.valueOf(entry.mediaType) }.getOrNull()
                ?: continue
            val outcome = if (queueTarget.source != BookSource.GRIMMORY) {
                SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
            } else if (entry.connectionKey.isBlank()) {
                flushPendingEntry(entry)
            } else {
                withContext(ConnectionScope.asContextElement(entry.connectionKey)) {
                    flushPendingEntry(entry)
                }
            }
            reconcilePending(entry.bookId, mediaType, entry.percentage, queueTarget, outcome)
            if (outcome is SourceOutcome.Ok) flushed++
        }
        return flushed
    }

    suspend fun pullBestProgress(
        bookId: String,
        localFile: File? = null,
    ): RemoteSyncResult? = coroutineScope {
        if (currentSource() != BookSource.GRIMMORY || accessTokenForCurrentConnection().isNullOrBlank()) {
            return@coroutineScope null
        }

        val grimmoryDeferred = async { pullFromGrimmory(bookId) }
        val kosyncDeferred = async { pullFromKosync(bookId, localFile) }

        val outcomes = listOf(grimmoryDeferred.await(), kosyncDeferred.await())
        outcomes
            .filterIsInstance<SourceOutcome.Ok<RemoteSyncResult>>()
            .mapNotNull { it.value }
            .maxByOrNull { it.percentage }
    }

    suspend fun fullSync(): SyncResult {
        var synced = 0
        var pulled = 0
        var pushed = 0
        var errors = 0

        return try {
            pushed = runCatching { flushPendingPushes() }.getOrDefault(0)
            val books = repository.getBooks(size = 500).getOrDefault(emptyList())
            for (book in books) {
                try {
                    val remote = pullBestProgress(book.id)
                    if (remote != null && remote.percentage > 0f) pulled++
                    synced++
                } catch (_: Exception) {
                    errors++
                }
            }
            prefs.setLastSyncTime(System.currentTimeMillis())
            SyncResult(synced = synced, pulled = pulled, pushed = pushed, errors = errors)
        } catch (_: Exception) {
            SyncResult(errors = 1)
        }
    }

    private suspend fun flushPendingEntry(entry: PendingProgressPush): SourceOutcome<Unit> {
        if (currentSource() != BookSource.GRIMMORY) {
            return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
        }
        return when (entry.mediaType) {
            AppMediaType.EBOOK.name -> pushEbookToGrimmory(entry.bookId, entry.percentage, cfi = null)
            AppMediaType.AUDIOBOOK.name -> pushAudiobookToGrimmory(
                entry.bookId,
                entry.percentage,
                positionMs = 0,
                trackIndex = 0,
            )
            else -> SourceOutcome.Skipped(SkipReason.NoGrimmoryBookId)
        }
    }

    private suspend fun pushEbookToGrimmory(
        bookId: String,
        percentage: Float,
        @Suppress("UNUSED_PARAMETER") cfi: String?,
    ): SourceOutcome<Unit> {
        if (currentSource() != BookSource.GRIMMORY) return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
        val token = accessTokenForCurrentConnection()
        if (token.isNullOrBlank()) return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
        val numericBookId = bookId.grimmoryServerBookId().toLongOrNull()
            ?: return SourceOutcome.Skipped(SkipReason.NoGrimmoryBookId)

        return runCatching {
            val request = GrimmoryProgressRequest(
                bookId = numericBookId,
                fileProgress = GrimmoryProgressFileProgress(
                    bookFileId = numericBookId,
                    progressPercent = (percentage.toDouble() * 100.0).coerceIn(0.0, 100.0),
                ),
                dateFinished = if (percentage >= 0.99f) Instant.now().toString() else null,
            )
            val response = api.postBookProgress(request)
            if (!response.isSuccessful) error("Grimmory progress update failed: ${response.code()}")
        }.fold(
            onSuccess = { SourceOutcome.Ok(Unit) },
            onFailure = { SourceOutcome.Failure(it) },
        )
    }

    private suspend fun pushAudiobookToGrimmory(
        bookId: String,
        percentage: Float,
        @Suppress("UNUSED_PARAMETER") positionMs: Long,
        @Suppress("UNUSED_PARAMETER") trackIndex: Int,
    ): SourceOutcome<Unit> {
        if (currentSource() != BookSource.GRIMMORY) return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
        val token = accessTokenForCurrentConnection()
        if (token.isNullOrBlank()) return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
        val numericBookId = bookId.grimmoryServerBookId().toLongOrNull()
            ?: return SourceOutcome.Skipped(SkipReason.NoGrimmoryBookId)

        return runCatching {
            val request = GrimmoryProgressRequest(
                bookId = numericBookId,
                fileProgress = GrimmoryProgressFileProgress(
                    bookFileId = numericBookId,
                    progressPercent = (percentage.toDouble() * 100.0).coerceIn(0.0, 100.0),
                ),
                dateFinished = if (percentage >= 0.99f) Instant.now().toString() else null,
            )
            val response = api.postBookProgress(request)
            if (!response.isSuccessful) error("Grimmory audio progress update failed: ${response.code()}")
        }.fold(
            onSuccess = { SourceOutcome.Ok(Unit) },
            onFailure = { SourceOutcome.Failure(it) },
        )
    }

    private suspend fun pushEbookToKosync(
        bookId: String,
        percentage: Float,
        cfi: String?,
        localFile: File?,
    ): SourceOutcome<Unit> {
        if (localFile == null) return SourceOutcome.Skipped(SkipReason.NoFileHash)

        val creds = resolveKosyncCreds()
            ?: return SourceOutcome.Skipped(SkipReason.NoKosyncCreds)

        return runCatching {
            val hash = PartialMd5.compute(localFile)
            val positionData = cfi?.let { CfiLocatorConverter.buildLocatorJson(it) } ?: ""
            val request = KosyncProgressRequest(
                document = hash,
                positionData = positionData,
                percentage = percentage,
                device = deviceIdentity.deviceName,
                deviceId = deviceIdentity.deviceId,
            )
            kosyncClient.pushProgress(creds.serverUrl, creds.username, creds.password, request).getOrThrow()
        }.recoverKosync404(localFile) { freshHash ->
            val refreshed = resolveKosyncCreds() ?: return@recoverKosync404 null
            val positionData = cfi?.let { CfiLocatorConverter.buildLocatorJson(it) } ?: ""
            kosyncClient.pushProgress(
                refreshed.serverUrl, refreshed.username, refreshed.password,
                KosyncProgressRequest(freshHash, positionData, percentage, deviceIdentity.deviceName, deviceIdentity.deviceId),
            ).getOrThrow()
        }.fold(
            onSuccess = { SourceOutcome.Ok(Unit) },
            onFailure = { SourceOutcome.Failure(it) },
        )
    }

    private suspend fun pullFromGrimmory(bookId: String): SourceOutcome<RemoteSyncResult> {
        if (currentSource() != BookSource.GRIMMORY) return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)
        val token = accessTokenForCurrentConnection()
        if (token.isNullOrBlank()) return SourceOutcome.Skipped(SkipReason.GrimmoryNotLoggedIn)

        return runCatching {
            val response = api.getAppBookProgress(bookId.grimmoryServerBookId())
            val progress = response.body() ?: return SourceOutcome.Skipped(SkipReason.NoLocalProgress)

            val pct = progress.epubProgress?.percentage?.div(100f)
                ?: progress.koreaderProgress?.percentage
                ?: progress.readProgress?.div(100f)
                ?: return SourceOutcome.Ok(null)

            if (pct <= 0f) return SourceOutcome.Ok(null)

            RemoteSyncResult(
                percentage = pct,
                cfi = progress.epubProgress?.cfi,
                source = progress.koreaderProgress?.device ?: "Grimmory",
            )
        }.fold(
            onSuccess = { SourceOutcome.Ok(it) },
            onFailure = { SourceOutcome.Failure(it) },
        )
    }

    private suspend fun pullFromKosync(
        bookId: String,
        localFile: File?,
    ): SourceOutcome<RemoteSyncResult> {
        if (localFile == null) return SourceOutcome.Skipped(SkipReason.NoFileHash)

        val creds = resolveKosyncCreds()
            ?: return SourceOutcome.Skipped(SkipReason.NoKosyncCreds)

        return runCatching {
            val hash = PartialMd5.compute(localFile)
            val response = kosyncClient.pullProgress(creds.serverUrl, creds.username, creds.password, hash).getOrThrow()
            if (response == null || (response.percentage ?: 0f) <= 0f) return SourceOutcome.Ok(null)

            RemoteSyncResult(
                percentage = response.percentage!!,
                cfi = response.positionData?.let { CfiLocatorConverter.extractCfi(it) },
                source = response.device ?: "KOReader",
            )
        }.fold(
            onSuccess = { SourceOutcome.Ok(it) },
            onFailure = { e ->
                if ((e as? KosyncHttpException)?.statusCode == 404)
                    SourceOutcome.Skipped(SkipReason.NoFileHash)
                else
                    SourceOutcome.Failure(e)
            },
        )
    }

    private data class KosyncCreds(val serverUrl: String, val username: String, val password: String)

    private fun resolveKosyncCreds(): KosyncCreds? {
        currentConnection()?.let { connection ->
            if (connection.source != BookSource.GRIMMORY) return null
            val serverUrl = connection.serverUrl.trimEnd('/')
            val username = vault.get(CredentialVault.kosyncUsernameKeyForConnection(connection.id))
                ?: vault.get(CredentialVault.kosyncUsernameKey(serverUrl))
                ?: return null
            val password = vault.get(CredentialVault.kosyncPasswordKeyForConnection(connection.id))
                ?: vault.get(CredentialVault.kosyncPasswordKey(serverUrl))
                ?: return null
            if (username.isBlank() || password.isBlank()) return null
            return KosyncCreds(serverUrl, username, password)
        }

        val serverUrl = prefs.getServerUrlSync()?.trimEnd('/') ?: return null
        val username = vault.get(CredentialVault.kosyncUsernameKey(serverUrl)) ?: return null
        val password = vault.get(CredentialVault.kosyncPasswordKey(serverUrl)) ?: return null
        if (username.isBlank() || password.isBlank()) return null
        return KosyncCreds(serverUrl, username, password)
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

    private suspend fun Result<Unit>.recoverKosync404(
        file: File,
        retry: suspend (freshHash: String) -> Unit?,
    ): Result<Unit> {
        val err = exceptionOrNull() as? KosyncHttpException ?: return this
        if (err.statusCode != 404) return this
        return runCatching {

            val freshHash = PartialMd5.compute(file)
            retry(freshHash)
        }
    }
}
