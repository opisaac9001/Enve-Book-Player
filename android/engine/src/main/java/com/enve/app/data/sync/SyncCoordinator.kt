package com.enve.app.data.sync

import com.enve.core.di.ApplicationScope
import com.enve.core.data.util.runSuspendCatching
import android.util.Log
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncCapabilityFlag
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.provider.ProviderAdapter
import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.repository.AggregatorRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

private const val TAG = "SyncCoordinator"

@Singleton
class SyncCoordinator @Inject constructor(
    private val koreaderSink: BookloreKoreaderSink,
    private val koreaderHub: KOReaderHubService,
    private val annotationRepo: AnnotationRepository,
    private val bookCacheDao: com.enve.core.data.local.BookCacheDao,
    private val aggregatorRepository: AggregatorRepository,
    private val rewindTracker: RemoteRewindTracker,

    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
    @ApplicationScope parentScope: CoroutineScope =
        CoroutineScope(SupervisorJob() + Dispatchers.Default),
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)

    private val debounceJobs = ConcurrentHashMap<String, Job>()

    private val annotationDebounceJobs = ConcurrentHashMap<String, Job>()

    private val bookMutexes = ConcurrentHashMap<String, Mutex>()

    private val knownBooks = ConcurrentHashMap<String, Book>()

    init {
        annotationRepo.setChangeListener { bookId ->
            scheduleAnnotationsPush(bookId)
        }
    }

    fun registerBook(book: Book) {
        knownBooks[book.id] = book
    }

    suspend fun pullOnOpen(book: Book): SyncSnapshot? {
        if (!serverSync.isEnabled) return null
        registerBook(book)

        scope.launch {
            try {
                pullAnnotations(book)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
        return try {
            fetchSnapshot(book)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "pullOnOpen failed for ${book.id}", e)
            null
        }
    }

    suspend fun pullAnnotations(book: Book): List<ReaderAnnotation> {
        val merged = mutableListOf<ReaderAnnotation>()
        var authoritativeSource: String? = null

        for (adapter in adapters) {
            if (adapter.source != book.source) continue
            if (!adapter.syncCapability.supports(SyncCapabilityFlag.PULL_ANNOTATIONS)) continue
            adapter.fetchAnnotations(book).getOrNull()?.let { remote ->
                merged += remote
                if (adapter.annotationsAreAuthoritative) {
                    authoritativeSource = adapter.source.name.lowercase()
                }
            }
        }

        val deduped = merged
            .groupBy { it.id }
            .map { (_, candidates) -> candidates.maxByOrNull { it.updatedAt }!! }
        val authoritative = authoritativeSource
        if (authoritative != null) {
            annotationRepo.applyAuthoritativeRemote(book.id, authoritative, deduped)
        } else if (deduped.isNotEmpty()) {
            annotationRepo.applyRemote(deduped)
        }
        return merged
    }

    fun scheduleAnnotationsPush(bookId: String, debounceMs: Long = 2_000) {
        annotationDebounceJobs[bookId]?.cancel()
        annotationDebounceJobs[bookId] = scope.launch {
            delay(debounceMs)
            performAnnotationsPush(bookId)
        }
    }

    fun flushAnnotations(bookId: String) {
        scope.launch { performAnnotationsPush(bookId) }
    }

    private suspend fun performAnnotationsPush(bookId: String) {
        val book = knownBooks[bookId]
        if (book == null) {
            Log.w(TAG, "Annotation push skipped because $bookId is not registered")
            return
        }
        val mutex = bookMutexes.getOrPut(bookId) { Mutex() }
        mutex.withLock {
            val dirty = annotationRepo.dirtyForBook(bookId)
            if (dirty.isEmpty()) return@withLock

            for (adapter in adapters) {
                if (adapter.source != book.source) continue
                if (!adapter.syncCapability.supports(SyncCapabilityFlag.PUSH_ANNOTATIONS)) continue
                val result = adapter.pushAnnotations(book, dirty)
                result.exceptionOrNull()?.let {
                    Log.w(TAG, "Annotation push failed for ${book.id} via ${adapter.source}", it)
                }
                val pushResult = result.getOrNull() ?: continue
                if (pushResult.rejected.isNotEmpty()) {
                    Log.w(
                        TAG,
                        "Annotation push rejected ${pushResult.rejected.size} item(s) for ${book.id}",
                    )
                }
                pushResult.accepted.forEach { acc ->
                    annotationRepo.markClean(acc.id, acc.etag, acc.serverId)
                }
                pushResult.conflicts.forEach { remote ->
                    val local = dirty.firstOrNull { it.id == remote.id }
                    if (local != null && remote.updatedAt > local.updatedAt) {
                        annotationRepo.applyRemote(listOf(remote))
                    }
                }
            }
        }
    }

    suspend fun fetchSnapshot(book: Book): SyncSnapshot? {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return null
        val snapshots = mutableListOf<SyncSnapshot>()

        if (book.source == BookSource.GRIMMORY) {
            val koreaderCreds = koreaderSink.credentialsForBook(book)
            if (koreaderCreds != null && koreaderCreds.enabled) {
                val snap = runSuspendCatching {
                    koreaderSink.pull(book)
                }.getOrNull()
                if (snap != null) snapshots += snap
            }
        }

        if (book.mediaType == AppMediaType.EBOOK) {
            runSuspendCatching { koreaderHub.snapshotFor(book) }.getOrNull()?.let { snapshots += it }
        }

        for (adapter in adapters) {
            if (adapter.source != book.source) continue
            if (!adapter.syncCapability.supports(SyncCapabilityFlag.PULL_PROGRESS)) continue
            val result = when (book.mediaType) {
                AppMediaType.AUDIOBOOK, AppMediaType.PODCAST -> aggregatorRepository.fetchAudiobookProgress(book)
                AppMediaType.EBOOK -> aggregatorRepository.fetchEbookProgress(book)
            }
            result.getOrNull()?.let { snapshots += it }
        }

        if (!serverSync.accepts(syncStartedAt)) return null
        return ProgressResolutionPolicy.bestSnapshot(snapshots)
    }

    fun pushProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
        forceImmediate: Boolean = false,
    ) {
        val requestedAt = System.currentTimeMillis()
        val syncKey = progressSyncKey(book)
        if (forceImmediate) {
            scope.launch { performPush(book, currentTimeSec, progressFraction, requestedAt) }
            return
        }
        debounceJobs[syncKey]?.cancel()
        debounceJobs[syncKey] = scope.launch {
            delay(2_000)
            performPush(book, currentTimeSec, progressFraction, requestedAt)
        }
    }

    fun pushFinished(book: Book) {
        val requestedAt = System.currentTimeMillis()
        scope.launch { performPush(book, book.currentTime, 1f, requestedAt) }
    }

    sealed class OpenSyncResult {
        data class Apply(
            val snapshot: SyncSnapshot?,
            val useRemote: Boolean,
            val allowRemoteCheckpoint: Boolean = true,
        ) : OpenSyncResult()
        data class Conflict(
            val local: ProgressOption,
            val remote: ProgressOption,
            val remoteSource: String,
        ) : OpenSyncResult()
    }

    data class ProgressOption(
        val percentage: Float,
        val updatedAt: Long?,
        val locatorJson: String?,
        val positionMs: Long?,
    )

    suspend fun pullOnOpenResolved(
        book: Book,
        localPercentage: Float,
        localUpdatedAt: Long?,
        localLocatorJson: String? = null,
    ): OpenSyncResult = resolveFetchedSnapshot(
        book = book,
        snapshot = pullOnOpen(book),
        localPercentage = localPercentage,
        localUpdatedAt = localUpdatedAt,
        localLocatorJson = localLocatorJson,
    )

    fun resolveFetchedSnapshot(
        book: Book,
        snapshot: SyncSnapshot?,
        localPercentage: Float,
        localUpdatedAt: Long?,
        localLocatorJson: String? = null,
    ): OpenSyncResult {
        if (!serverSync.isEnabled) return OpenSyncResult.Apply(null, useRemote = false, allowRemoteCheckpoint = false)
        if (snapshot == null) return OpenSyncResult.Apply(null, useRemote = false)
        return when (ProgressResolutionPolicy.resolve(localPercentage, localUpdatedAt, snapshot, localLocatorJson)) {
            ProgressResolutionPolicy.Decision.NONE -> OpenSyncResult.Apply(snapshot, useRemote = false)
            ProgressResolutionPolicy.Decision.PULL -> OpenSyncResult.Apply(snapshot, useRemote = true)
            ProgressResolutionPolicy.Decision.PUSH -> OpenSyncResult.Apply(snapshot, useRemote = false, allowRemoteCheckpoint = false)
            ProgressResolutionPolicy.Decision.CONFLICT -> {
                val verdict = rewindTracker.assess(
                    scope = RemoteProgressScope.of(book, snapshot.source),
                    observation = RemoteProgressObservation(
                        percentage = snapshot.percentage,
                        positionMs = snapshot.positionMs,
                        locatorJson = snapshot.locatorJson,
                        observedAt = snapshot.updatedAt,
                    ),
                    localPercentage = localPercentage,
                )
                when (verdict) {
                    RemoteRewindVerdict.CONFIRMED -> OpenSyncResult.Apply(snapshot, useRemote = true)
                    RemoteRewindVerdict.ECHO,
                    RemoteRewindVerdict.DISMISSED -> OpenSyncResult.Apply(snapshot, useRemote = false, allowRemoteCheckpoint = false)
                    RemoteRewindVerdict.NOT_REWIND,
                    RemoteRewindVerdict.UNCONFIRMED -> {
                        val localPositionMs =
                            if (book.duration > 0L) (book.duration * localPercentage * 1000L).toLong() else null
                        OpenSyncResult.Conflict(
                            local = ProgressOption(
                                percentage = localPercentage,
                                updatedAt = localUpdatedAt,
                                locatorJson = localLocatorJson,
                                positionMs = localPositionMs,
                            ),
                            remote = ProgressOption(
                                percentage = snapshot.percentage,
                                updatedAt = snapshot.updatedAt,
                                locatorJson = snapshot.locatorJson,
                                positionMs = snapshot.positionMs,
                            ),
                            remoteSource = snapshot.source,
                        )
                    }
                }
            }
        }
    }

    fun recordConflictResolution(book: Book, remoteSource: String, acceptedRemote: Boolean) {
        rewindTracker.recordUserResolution(RemoteProgressScope.of(book, remoteSource), acceptedRemote)
    }

    private suspend fun performPush(book: Book, currentTimeSec: Long, progressFraction: Float, requestedAt: Long) {
        val mutex = bookMutexes.getOrPut(progressSyncKey(book)) { Mutex() }
        mutex.withLock {
            try {
                val normalizedProgress = progressFraction.coerceIn(0f, 1f)

                if (book.mediaType !in setOf(AppMediaType.AUDIOBOOK, AppMediaType.PODCAST)) try {
                    bookCacheDao.updateUnifiedProgress(
                        bookId = book.id,
                        connectionId = book.connectionId,
                        progress = normalizedProgress,
                        currentTimeSec = currentTimeSec,
                        locatorJson = null,
                        nowMs = System.currentTimeMillis(),
                    )
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {

                }
                if (!serverSync.accepts(requestedAt)) return@withLock
                if (book.mediaType !in setOf(AppMediaType.AUDIOBOOK, AppMediaType.PODCAST) && normalizedProgress <= 0.001f && !book.isFinished) {
                    return@withLock
                }
                val ebookLocator = if (book.mediaType == AppMediaType.EBOOK) {
                    try {
                        bookCacheDao.getByIdAndConnection(book.id, book.connectionId)?.epubLocator
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        null
                    } ?: book.epubLocator
                } else {
                    null
                }
                var remoteWritten = false
                val adapter = adapters.firstOrNull { it.source == book.source }
                if (adapter != null && adapter.syncCapability.supports(SyncCapabilityFlag.PUSH_PROGRESS)) {
                    val result = when (book.mediaType) {
                        AppMediaType.AUDIOBOOK, AppMediaType.PODCAST -> aggregatorRepository.syncAudiobookProgress(
                            book = book,
                            currentTimeSec = currentTimeSec,
                            progressFraction = normalizedProgress,
                        )
                        AppMediaType.EBOOK -> aggregatorRepository.syncEbookProgress(
                            bookId = book.id,
                            source = book.source,
                            percentage = normalizedProgress,
                            locator = ebookLocator,
                            connectionId = book.connectionId,
                        )
                    }
                    result.getOrThrow()
                    remoteWritten = true
                }

                if (book.source == BookSource.GRIMMORY && book.mediaType == AppMediaType.EBOOK) {
                    val creds = koreaderSink.credentialsForBook(book)
                    if (creds != null && creds.enabled) {
                        try {
                            koreaderSink.push(book, null, normalizedProgress)
                        } catch (e: kotlinx.coroutines.CancellationException) {
                            throw e
                        } catch (_: Exception) {
                        }
                    }
                }

                if (book.mediaType == AppMediaType.EBOOK) {
                    try {
                        koreaderHub.pushIfConfigured(book, normalizedProgress, ebookLocator)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (_: Exception) {
                    }
                }

                if (remoteWritten && book.mediaType !in setOf(AppMediaType.AUDIOBOOK, AppMediaType.PODCAST)) {
                    rewindTracker.recordOutboundWrite(
                        key = RemoteProgressWriteKey.of(book),
                        percentage = normalizedProgress,
                        positionMs = null,
                        locatorJson = ebookLocator,
                    )
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "performPush failed for ${book.id}", e)
            }
        }
    }

    private fun progressSyncKey(book: Book): String = book.uniqueKey
}
