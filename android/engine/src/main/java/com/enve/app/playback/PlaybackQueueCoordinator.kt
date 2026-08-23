package com.enve.app.playback

import android.util.Log
import com.enve.app.data.offline.BookCompletionHandler
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.playback.PlaybackQueueItem
import com.enve.engine.playback.PlaybackQueueOrigin
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import javax.inject.Inject
import javax.inject.Singleton

internal object PlaybackQueuePolicy {
    fun manualCandidates(books: List<Book>): List<Book> = books
        .filter { it.mediaType == AppMediaType.AUDIOBOOK || it.mediaType == AppMediaType.PODCAST || it.hasAudio }
        .distinctBy(Book::uniqueKey)

    fun playAllCandidates(books: List<Book>): List<Book> {
        val playable = manualCandidates(books)
        val unfinished = playable.filterNot(::isFinished)
        return unfinished.ifEmpty { playable }
    }

    fun isFinished(book: Book): Boolean =
        book.isFinished || book.progress >= 0.99f ||
            book.serverReadStatus?.uppercase() in setOf("READ", "COMPLETED", "FINISHED")

    fun seriesAutoAdvanceCandidates(current: Book, books: List<Book>): List<Book> {
        val series = current.seriesName?.trim()?.takeIf(String::isNotEmpty) ?: return emptyList()
        val currentSequence = current.seriesNumber?.trim()?.toDoubleOrNull() ?: return emptyList()
        return books
            .asSequence()
            .filter { book ->
                book.source == current.source &&
                    book.connectionId == current.connectionId &&
                    book.libraryId == current.libraryId &&
                    book.mediaType == AppMediaType.AUDIOBOOK &&
                    book.seriesName?.trim()?.equals(series, ignoreCase = true) == true
            }
            .mapNotNull { book ->
                book.seriesNumber?.trim()?.toDoubleOrNull()?.let { sequence -> sequence to book }
            }
            .filter { (sequence, book) -> sequence > currentSequence && !isFinished(book) }
            .sortedWith(compareBy<Pair<Double, Book>> { it.first }.thenBy { it.second.title.lowercase() })
            .map { it.second }
            .distinctBy(Book::uniqueKey)
            .toList()
    }
}

@Singleton
class PlaybackQueueCoordinator @Inject constructor(
    private val store: PlaybackQueueStore,
    private val bookCache: BookCacheDao,
    private val starter: PlaybackStarter,
    private val audioManager: AudioPlaybackManager,
    private val progressService: PlayerProgressService,
    private val sessionService: PlayerSessionService,
    private val completionHandler: BookCompletionHandler,
    private val preferences: PreferencesManager,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private var completedBookKey: String? = null

    val queue: StateFlow<List<PlaybackQueueItem>> = store.entries
        .map { entries ->
            if (entries.isEmpty()) return@map emptyList()
            val cachedByKey = bookCache.getByCacheKeys(entries.map(PlaybackQueueEntry::bookKey))
                .associateBy { it.cacheKey }
            entries.mapNotNull { entry ->
                cachedByKey[entry.bookKey]?.toBook()?.let { book ->
                    PlaybackQueueItem(
                        book = book,
                        origin = runCatching { PlaybackQueueOrigin.valueOf(entry.origin) }
                            .getOrDefault(PlaybackQueueOrigin.MANUAL),
                        groupKey = entry.groupKey,
                    )
                }
            }
        }
        .stateIn(scope, SharingStarted.Eagerly, emptyList())

    suspend fun open(book: Book, positionMs: Long? = null): Boolean = mutex.withLock {
        finalizeCurrent()
        store.clear()
        start(book, positionMs)
    }

    suspend fun playAll(books: List<Book>, groupKey: String?): Boolean = mutex.withLock {
        val candidates = PlaybackQueuePolicy.playAllCandidates(books)
        if (candidates.isEmpty()) return@withLock false

        finalizeCurrent()
        store.replace(
            bookKeys = candidates.drop(1).map(Book::uniqueKey),
            origin = PlaybackQueueOrigin.PLAY_ALL,
            groupKey = groupKey,
        )
        if (start(candidates.first())) return@withLock true
        startNextQueued()
    }

    suspend fun addNext(book: Book): Boolean = mutex.withLock {
        if (!isPlayable(book)) return@withLock false
        if (!hasActivePlayback()) {
            store.remove(book.uniqueKey)
            return@withLock start(book)
        }
        if (currentBookKey() == book.uniqueKey) return@withLock true
        store.addNext(book.uniqueKey)
        true
    }

    suspend fun addLast(book: Book): Boolean = mutex.withLock {
        if (!isPlayable(book)) return@withLock false
        if (!hasActivePlayback()) {
            store.remove(book.uniqueKey)
            return@withLock start(book)
        }
        if (currentBookKey() == book.uniqueKey) return@withLock true
        store.addLast(book.uniqueKey)
        true
    }

    suspend fun addLast(books: List<Book>): Boolean = mutex.withLock {
        val candidates = PlaybackQueuePolicy.manualCandidates(books)
        if (candidates.isEmpty()) return@withLock false

        if (!hasActivePlayback()) {
            store.remove(candidates.first().uniqueKey)
            if (!start(candidates.first())) return@withLock false
            store.addLast(candidates.drop(1).map(Book::uniqueKey))
            return@withLock true
        }

        val currentKey = currentBookKey()
        store.addLast(candidates.map(Book::uniqueKey).filterNot { it == currentKey })
        true
    }

    suspend fun playQueued(bookKey: String): Boolean = mutex.withLock {
        val selected = bookCache.getByCacheKey(bookKey)?.toBook() ?: run {
            store.remove(bookKey)
            return@withLock false
        }
        val previous = finalizeCurrent()
        store.remove(bookKey)
        if (previous != null && previous.uniqueKey != bookKey && !PlaybackQueuePolicy.isFinished(previous)) {
            store.addNext(previous.uniqueKey)
        }
        start(selected)
    }

    suspend fun remove(bookKey: String) = mutex.withLock { store.remove(bookKey) }

    suspend fun move(bookKey: String, delta: Int) = mutex.withLock {
        store.move(bookKey, delta)
    }

    suspend fun clear() = mutex.withLock { store.clear() }

    suspend fun onPlaybackCompleted(mediaId: String?) = mutex.withLock {
        val cacheKey = mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom)
        completedBookKey = cacheKey
        val finished = cacheKey?.let { bookCache.getByCacheKey(it)?.toBook() }
        if (finished != null) {
            try {
                completionHandler.onBookFinished(finished)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Completion actions failed for ${finished.uniqueKey}", e)
            }
        }

        audioManager.clearCompletionFlag()
        if (!preferences.continuousPlayback.first()) return@withLock
        if (startNextQueued()) return@withLock
        if (!preferences.autoPlayNextInSeries.first() || finished == null) return@withLock
        startNextInSeries(finished)
    }

    private suspend fun startNextQueued(): Boolean {
        while (true) {
            val entry = store.takeNext() ?: return false
            val book = bookCache.getByCacheKey(entry.bookKey)?.toBook() ?: continue
            if (!isPlayable(book)) continue
            if (start(book)) return true
        }
    }

    private suspend fun startNextInSeries(current: Book): Boolean {
        val series = current.seriesName?.trim()?.takeIf(String::isNotEmpty) ?: return false
        val candidates = bookCache.audiobooksInSeries(
            seriesName = series,
            source = current.source.name,
            connectionId = current.connectionId,
            libraryId = current.libraryId,
        ).map { it.toBook() }
        for (book in PlaybackQueuePolicy.seriesAutoAdvanceCandidates(current, candidates)) {
            if (start(book)) return true
        }
        return false
    }

    private suspend fun start(book: Book, positionMs: Long? = null): Boolean {
        val started = try {
            starter.start(book)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.e(TAG, "Couldn't start ${book.uniqueKey}", e)
            false
        }
        if (started) completedBookKey = null
        if (started && positionMs != null) audioManager.seekTo(positionMs.coerceAtLeast(0L))
        return started
    }

    private suspend fun finalizeCurrent(): Book? {
        val state = audioManager.state.value
        val cacheKey = state.mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom)
        val current = cacheKey?.let { bookCache.getByCacheKey(it) }
            ?: audioManager.currentBookId?.let { bookCache.getById(it) }
        val persisted = progressService.persistPlayback(
            mediaId = state.mediaId,
            bookId = audioManager.currentBookId,
            positionMs = state.currentPositionMs,
            durationMs = state.durationMs,
            force = true,
        )
        if (persisted != null) {
            progressService.syncImmediate(
                book = persisted.book,
                currentTimeSec = persisted.currentTimeSec,
                progressFraction = persisted.progressFraction,
            )
        }
        sessionService.close(
            positionSec = state.currentPositionMs.coerceAtLeast(0L) / 1000L,
            durationSec = state.durationMs.coerceAtLeast(0L) / 1000L,
        )
        return persisted?.book ?: current?.toBook()
    }

    private fun currentBookKey(): String? =
        audioManager.state.value.mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom)

    private fun hasActivePlayback(): Boolean {
        if (audioManager.currentBookId == null) return false
        val currentKey = currentBookKey()
        return currentKey == null || currentKey != completedBookKey
    }

    private fun isPlayable(book: Book): Boolean =
        book.mediaType == AppMediaType.AUDIOBOOK || book.mediaType == AppMediaType.PODCAST || book.hasAudio

    private companion object {
        const val TAG = "PlaybackQueue"
    }
}
