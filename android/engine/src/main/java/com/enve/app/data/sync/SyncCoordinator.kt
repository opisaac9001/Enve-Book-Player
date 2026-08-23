package com.enve.app.data.sync

import android.util.Log
import com.enve.core.data.sync.SyncCapability
import com.enve.core.data.sync.SyncCapabilityFlag
import com.enve.core.data.sync.SyncEvent
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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.filter
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

    private val adapters: Set<@JvmSuppressWildcards ProviderAdapter>,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

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

    private val _events = MutableSharedFlow<SyncEvent>(extraBufferCapacity = 32)
    val events: Flow<SyncEvent> = _events.asSharedFlow()

    fun subscribe(bookId: String): Flow<SyncEvent> =
        events.filter { event ->
            when (event) {
                is SyncEvent.Syncing -> event.bookId == bookId
                is SyncEvent.Synced -> event.bookId == bookId
                is SyncEvent.Failed -> event.bookId == bookId
                is SyncEvent.ConflictDetected -> event.bookId == bookId
                is SyncEvent.AnnotationsPulled -> event.bookId == bookId
                is SyncEvent.AnnotationsPushed -> event.bookId == bookId
                is SyncEvent.AnnotationConflict -> event.bookId == bookId
            }
        }

    suspend fun pullOnOpen(book: Book): SyncSnapshot? {
        registerBook(book)
        _events.emit(SyncEvent.Syncing(book.id))

        scope.launch {
            try {
                pullAnnotations(book)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
        return try {
            val snapshot = fetchSnapshot(book)
            if (snapshot != null) {
                _events.emit(SyncEvent.Synced(book.id, snapshot.percentage, snapshot.source))
            }
            snapshot
        } catch (e: Exception) {
            Log.e(TAG, "pullOnOpen failed for ${book.id}", e)
            _events.emit(SyncEvent.Failed(book.id, e))
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
            _events.emit(SyncEvent.AnnotationsPulled(book.id, deduped.size, authoritative))
        } else if (deduped.isNotEmpty()) {
            annotationRepo.applyRemote(deduped)
            _events.emit(SyncEvent.AnnotationsPulled(book.id, deduped.size, "remote"))
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

            var totalAccepted = 0
            var totalRejected = 0

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
                    if (local != null) {
                        _events.emit(SyncEvent.AnnotationConflict(
                            bookId = bookId,
                            annotationId = remote.id,
                            remoteUpdatedAt = remote.updatedAt,
                            localUpdatedAt = local.updatedAt,
                        ))

                        if (remote.updatedAt > local.updatedAt) {
                            annotationRepo.applyRemote(listOf(remote))
                        }
                    }
                }
                totalAccepted += pushResult.accepted.size
                totalRejected += pushResult.rejected.size
            }

            _events.emit(SyncEvent.AnnotationsPushed(bookId, totalAccepted, totalRejected))
        }
    }

    suspend fun fetchSnapshot(book: Book): SyncSnapshot? {
        val snapshots = mutableListOf<SyncSnapshot>()

        if (book.source == BookSource.GRIMMORY) {
            val koreaderCreds = koreaderSink.credentialsForBook(book)
            if (koreaderCreds != null && koreaderCreds.enabled) {
                val snap = runCatching {
                    koreaderSink.pull(book)
                }.getOrNull()
                if (snap != null) snapshots += snap
            }
        }

        if (book.mediaType == AppMediaType.EBOOK) {
            runCatching { koreaderHub.snapshotFor(book) }.getOrNull()?.let { snapshots += it }
        }

        for (adapter in adapters) {
            if (adapter.source != book.source) continue
            if (!adapter.syncCapability.supports(SyncCapabilityFlag.PULL_PROGRESS)) continue
            val result = when (book.mediaType) {
                AppMediaType.AUDIOBOOK -> aggregatorRepository.fetchAudiobookProgress(book)
                AppMediaType.EBOOK -> aggregatorRepository.fetchEbookProgress(book)
                else -> continue
            }
            result.getOrNull()?.let { snapshots += it }
        }

        return ProgressResolutionPolicy.bestSnapshot(snapshots)
    }

    fun pushProgress(
        book: Book,
        currentTimeSec: Long,
        progressFraction: Float,
        forceImmediate: Boolean = false,
    ) {
        val syncKey = progressSyncKey(book)
        if (forceImmediate) {
            scope.launch { performPush(book, currentTimeSec, progressFraction) }
            return
        }
        debounceJobs[syncKey]?.cancel()
        debounceJobs[syncKey] = scope.launch {
            delay(2_000)
            performPush(book, currentTimeSec, progressFraction)
        }
    }

    fun pushFinished(book: Book) {
        scope.launch { performPush(book, book.currentTime, 1f) }
    }

    enum class ProgressResolution { NONE, PULL, PUSH }

    fun resolveProgress(
        localPercentage: Float,
        localUpdatedAt: Long?,
        remote: SyncSnapshot,
    ): ProgressResolution {
        return when (ProgressResolutionPolicy.resolve(localPercentage, localUpdatedAt, remote)) {
            ProgressResolutionPolicy.Decision.NONE,
            ProgressResolutionPolicy.Decision.CONFLICT -> ProgressResolution.NONE
            ProgressResolutionPolicy.Decision.PULL -> ProgressResolution.PULL
            ProgressResolutionPolicy.Decision.PUSH -> ProgressResolution.PUSH
        }
    }

    suspend fun applySnapshot(
        book: Book,
        snapshot: SyncSnapshot,
        localPercentage: Float,
    ): Long? {
        val localUpdatedAt = book.lastReadTime.takeIf { it > 0 }
        return when (resolveProgress(localPercentage, localUpdatedAt, snapshot)) {
            ProgressResolution.NONE, ProgressResolution.PUSH -> null
            ProgressResolution.PULL -> snapshot.positionMs
                ?: (book.duration * snapshot.percentage * 1000).toLong().takeIf { book.duration > 0 }
        }
    }

    sealed class OpenSyncResult {
        data class Apply(val snapshot: SyncSnapshot?, val useRemote: Boolean) : OpenSyncResult()
        data class Conflict(
            val local: ProgressOption,
            val remote: ProgressOption,
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
    ): OpenSyncResult {
        val snapshot = pullOnOpen(book) ?: return OpenSyncResult.Apply(null, useRemote = false)
        return when (ProgressResolutionPolicy.resolve(localPercentage, localUpdatedAt, snapshot)) {
            ProgressResolutionPolicy.Decision.NONE -> OpenSyncResult.Apply(snapshot, useRemote = false)
            ProgressResolutionPolicy.Decision.PULL -> OpenSyncResult.Apply(snapshot, useRemote = true)
            ProgressResolutionPolicy.Decision.PUSH -> OpenSyncResult.Apply(snapshot, useRemote = false)
            ProgressResolutionPolicy.Decision.CONFLICT -> {
                val localPositionMs = if (book.duration > 0L) (book.duration * localPercentage * 1000L).toLong() else null
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
                )
            }
        }
    }

    private suspend fun performPush(book: Book, currentTimeSec: Long, progressFraction: Float) {
        val mutex = bookMutexes.getOrPut(progressSyncKey(book)) { Mutex() }
        mutex.withLock {
            try {
                val normalizedProgress = progressFraction.coerceIn(0f, 1f)

                try {
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
                if (normalizedProgress <= 0.001f && !book.isFinished) {
                    return@withLock
                }
                val adapter = adapters.firstOrNull { it.source == book.source }
                if (adapter != null && adapter.syncCapability.supports(SyncCapabilityFlag.PUSH_PROGRESS)) {
                    val result = when (book.mediaType) {
                        AppMediaType.AUDIOBOOK -> aggregatorRepository.syncAudiobookProgress(
                            book = book,
                            currentTimeSec = currentTimeSec,
                            progressFraction = normalizedProgress,
                        )
                        AppMediaType.EBOOK -> aggregatorRepository.syncEbookProgress(
                            bookId = book.id,
                            source = book.source,
                            percentage = normalizedProgress,
                            locator = null,
                            connectionId = book.connectionId,
                        )
                        else -> Result.success(Unit)
                    }
                    result.getOrThrow()
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
                    val locator = try {
                        bookCacheDao.getByIdAndConnection(book.id, book.connectionId)?.epubLocator
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (_: Exception) {
                        null
                    } ?: book.epubLocator
                    try {
                        koreaderHub.pushIfConfigured(book, normalizedProgress, locator)
                    } catch (e: kotlinx.coroutines.CancellationException) {
                        throw e
                    } catch (_: Exception) {
                    }
                }
                _events.emit(SyncEvent.Synced(book.id, normalizedProgress, book.source.name))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "performPush failed for ${book.id}", e)
                _events.emit(SyncEvent.Failed(book.id, e))
            }
        }
    }

    private fun progressSyncKey(book: Book): String = book.uniqueKey
}
