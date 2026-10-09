package com.enve.wear.listening

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException

class WatchProgressSyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val vault = CredentialVault(applicationContext)
        val providers = WatchProviderRegistry(vault)
        val store = WatchLibraryStore.get(applicationContext)
        val requestedKey = inputData.getString(KEY_BOOK)
        try {
            store.state.value.books
                .filter { it.downloaded && (requestedKey == null || it.key == requestedKey) }
                .forEach { book ->
                    val account = vault.read(book.account) ?: return@forEach
                    val provider = providers.providerOrNull(account) ?: return@forEach
                    if (provider.capabilities.progress) syncBook(provider, account, store, book)
                }
            Result.success()
        } catch (error: CancellationException) {
            throw error
        } catch (error: IOException) {
            if (runAttemptCount < 5) Result.retry() else Result.failure()
        } catch (_: Exception) {
            Result.failure()
        }
    }

    private suspend fun syncBook(
        provider: WatchAudiobookProvider,
        account: WatchAccount,
        store: WatchLibraryStore,
        book: WatchBook,
    ) {
        val before = store.state.value
        val pending = before.pendingProgress[book.key]
        val remote = provider.fetchProgress(account, book.id)
        when (progressSyncDecision(pending, remote)) {
            WatchProgressSyncDecision.PULL_REMOTE -> {
                if (WatchPlaybackService.state.value.book?.key == book.key) return
                store.applyRemoteProgress(book.key, checkNotNull(remote))
                return
            }
            WatchProgressSyncDecision.CONFLICT -> {
                store.recordProgressConflict(book.key, checkNotNull(pending), checkNotNull(remote))
                return
            }
            WatchProgressSyncDecision.NOTHING -> return
            WatchProgressSyncDecision.COMPLETE_LOCAL -> {
                store.completeProgressPush(book.key, checkNotNull(pending), checkNotNull(remote))
                return
            }
            WatchProgressSyncDecision.PUSH_LOCAL -> Unit
        }
        checkNotNull(pending)
        provider.pushProgress(account, book, pending.positionMs)
        provider.fetchProgress(account, book.id)?.let { store.completeProgressPush(book.key, pending, it) }
    }

    companion object {
        private const val KEY_BOOK = "book"

        fun enqueue(context: Context, bookKey: String? = null) {
            val data = if (bookKey == null) androidx.work.Data.EMPTY else androidx.work.workDataOf(KEY_BOOK to bookKey)
            val request = OneTimeWorkRequestBuilder<WatchProgressSyncWorker>()
                .setInputData(data)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .addTag("watch-progress-sync")
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                if (bookKey == null) "watch-progress-sync" else "watch-progress-sync-$bookKey",
                ExistingWorkPolicy.KEEP,
                request,
            )
        }
    }
}

enum class WatchProgressSyncDecision {
    NOTHING,
    PULL_REMOTE,
    PUSH_LOCAL,
    COMPLETE_LOCAL,
    CONFLICT,
}

fun progressSyncDecision(
    pending: WatchPendingProgress?,
    remote: WatchRemoteProgress?,
): WatchProgressSyncDecision {
    if (pending == null) return if (remote == null) WatchProgressSyncDecision.NOTHING else WatchProgressSyncDecision.PULL_REMOTE
    if (remote == null) return WatchProgressSyncDecision.PUSH_LOCAL
    if (kotlin.math.abs(remote.positionMs - pending.positionMs) <= 1_000L) return WatchProgressSyncDecision.COMPLETE_LOCAL
    val baselinePosition = pending.baselinePositionMs
    val baselineUpdated = pending.baselineUpdatedAt
    if (baselinePosition == null || baselineUpdated == null) {
        return WatchProgressSyncDecision.CONFLICT
    }
    val remoteChanged = kotlin.math.abs(remote.positionMs - baselinePosition) > 1_000L
    return if (remoteChanged) WatchProgressSyncDecision.CONFLICT else WatchProgressSyncDecision.PUSH_LOCAL
}
