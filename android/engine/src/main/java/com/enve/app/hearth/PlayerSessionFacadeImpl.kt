package com.enve.app.hearth

import com.enve.app.playback.AudioPlaybackManager
import com.enve.app.playback.PlaybackChapterStore
import com.enve.app.playback.PlayerBookmarkService
import com.enve.app.playback.PlayerSleepTimerService
import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.sync.SyncCoordinator
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.BookExtrasDao
import com.enve.core.data.local.decodeChapters
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.AudiobookBookmark
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.playback.PlayerSessionFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.ceil

@Singleton
class PlayerSessionFacadeImpl @Inject constructor(
    private val chapterStore: PlaybackChapterStore,
    private val legacyBookmarkService: PlayerBookmarkService,
    private val annotations: AnnotationRepository,
    private val sync: SyncCoordinator,
    private val sleepTimerService: PlayerSleepTimerService,
    private val audioManager: AudioPlaybackManager,
    private val bookCache: BookCacheDao,
    private val bookExtras: BookExtrasDao,
) : PlayerSessionFacade {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    override val chapters: StateFlow<List<Chapter>> =
        chapterStore.snapshot.map { it.chapters }
            .stateIn(scope, SharingStarted.WhileSubscribed(5000), emptyList())

    override val currentChapterIndex: StateFlow<Int> =
        combine(chapterStore.snapshot, audioManager.state) { snap, s ->
            if (snap.usesMediaItemIndexes(s.mediaItemCount)) {
                s.currentMediaItemIndex.coerceIn(0, snap.chapters.lastIndex)
            } else {
                snap.chapterIndexAt(s.currentPositionMs / 1000)
            }
        }.stateIn(scope, SharingStarted.WhileSubscribed(5000), -1)

    private val _bookmarks = MutableStateFlow<List<AudiobookBookmark>>(emptyList())
    override val bookmarks: StateFlow<List<AudiobookBookmark>> = _bookmarks.asStateFlow()
    private val migratedLegacyBookIds = mutableSetOf<String>()

    private val _sleepRemaining = MutableStateFlow<Long?>(null)
    override val sleepRemainingSec: StateFlow<Long?> = _sleepRemaining.asStateFlow()
    private var sleepJob: Job? = null

    init {
        scope.launch {
            audioManager.currentBookIdFlow.collectLatest { bookId ->
                if (bookId == null) {
                    _bookmarks.value = emptyList()
                    return@collectLatest
                }
                val book = bookCache.getById(bookId)?.toBook()
                if (book != null) {
                    hydrateChapters(book)
                    migrateLegacyBookmarks(book)
                }
                annotations.byBookAndKind(bookId, AnnotationKind.BOOKMARK).collect { rows ->
                    _bookmarks.value = rows
                        .filter { AnnotationMedia.parse(it.media) == AnnotationMedia.AUDIOBOOK && it.audioPositionMs != null }
                        .map { it.toAudiobookBookmark() }
                        .sortedBy { it.position }
                }
            }
        }
    }

    private suspend fun hydrateChapters(book: Book) {
        val active = chapterStore.snapshot.value
        if (active.bookId == book.id && active.chapters.isNotEmpty()) return
        val chapters = bookExtras.get(book.uniqueKey)?.decodeChapters()?.takeIf { it.isNotEmpty() } ?: return
        chapterStore.set(
            cacheKey = book.uniqueKey,
            bookId = book.id,
            chapters = chapters,
            title = book.title,
            author = book.author,
            coverUrl = book.coverUrl,
        )
    }

    override fun seekToChapter(chapter: Chapter) {
        val snapshot = chapterStore.snapshot.value
        val playback = audioManager.state.value
        if (snapshot.usesMediaItemIndexes(playback.mediaItemCount)) {
            snapshot.chapters.indexOf(chapter)
                .takeIf { it >= 0 }
                ?.let { audioManager.seekToMediaItem(it) }
        } else {
            audioManager.seekTo(chapter.startTime * 1000)
        }
    }

    override fun nextChapter() {
        val snapshot = chapterStore.snapshot.value
        val playback = audioManager.state.value
        if (snapshot.usesMediaItemIndexes(playback.mediaItemCount)) {
            (playback.currentMediaItemIndex + 1)
                .takeIf { it in snapshot.chapters.indices }
                ?.let { audioManager.seekToMediaItem(it) }
        } else {
            snapshot.nextChapterStart(currentPositionSec())?.let { audioManager.seekTo(it * 1000) }
        }
    }

    override fun previousChapter() {
        val snapshot = chapterStore.snapshot.value
        val playback = audioManager.state.value
        if (snapshot.usesMediaItemIndexes(playback.mediaItemCount)) {
            val currentIndex = playback.currentMediaItemIndex.coerceIn(0, snapshot.chapters.lastIndex)
            val targetIndex = if (playback.currentPositionMs > 3_000L) currentIndex else (currentIndex - 1).coerceAtLeast(0)
            audioManager.seekToMediaItem(targetIndex)
        } else {
            snapshot.previousChapterStart(currentPositionSec())?.let { audioManager.seekTo(it * 1000) }
        }
    }

    override fun addBookmark(note: String?) {
        val bookId = audioManager.currentBookId ?: return
        scope.launch {
            val book = bookCache.getById(bookId)?.toBook() ?: return@launch
            val chapterTitle = chapters.value.getOrNull(currentChapterIndex.value)?.title
            sync.registerBook(book)
            val positionSec = currentPositionSec()
            annotations.create(
                bookId = book.id,
                kind = AnnotationKind.BOOKMARK,
                media = AnnotationMedia.AUDIOBOOK,
                colorHex = "#F5921A",
                audioPositionMs = positionSec * 1000,
                chapterId = chapterTitle,
                selectedText = chapterTitle.orEmpty(),
                note = note.orEmpty(),
                providerSource = book.source.name.lowercase(),
            )
        }
    }

    override fun deleteBookmark(bookmark: AudiobookBookmark) {
        scope.launch {
            bookCache.getById(bookmark.bookId)?.toBook()?.let(sync::registerBook)
            annotations.delete(bookmark.id)
        }
    }

    override fun seekToBookmark(bookmark: AudiobookBookmark) = audioManager.seekTo(bookmark.position * 1000)

    override fun startSleepTimer(minutes: Int) {
        sleepJob?.cancel()
        audioManager.setVolume(1f)
        sleepJob = sleepTimerService.startSeconds(
            scope = scope,
            seconds = minutes.coerceAtLeast(0) * 60L,
            isFadeEnabled = { true },
            onTick = { remaining -> _sleepRemaining.value = remaining },
            onFade = { volume -> audioManager.setVolume(volume) },
            onFinished = ::finishSleepTimer,
        )
    }

    override fun startChapterSleepTimer(endPositionSec: Long) {
        sleepJob?.cancel()
        audioManager.setVolume(1f)
        val targetPositionMs = endPositionSec.coerceAtLeast(0L) * 1000L
        sleepJob = sleepTimerService.startUntil(
            scope = scope,
            remainingSeconds = {
                val playback = audioManager.state.value
                chapterSleepRemainingSeconds(targetPositionMs, playback.currentPositionMs, playback.playbackSpeed)
            },
            isFadeEnabled = { true },
            onTick = { remaining -> _sleepRemaining.value = remaining },
            onFade = { volume -> audioManager.setVolume(volume) },
            onFinished = ::finishSleepTimer,
        )
    }

    override fun cancelSleepTimer() {
        sleepJob?.cancel()
        audioManager.setVolume(1f)
        _sleepRemaining.value = null
    }

    private fun finishSleepTimer() {
        if (audioManager.state.value.isPlaying) audioManager.togglePlayPause()
        audioManager.setVolume(1f)
        _sleepRemaining.value = null
    }

    private fun currentPositionSec(): Long = audioManager.state.value.currentPositionMs / 1000

    private fun ReaderAnnotation.toAudiobookBookmark(): AudiobookBookmark {
        val positionSec = (audioPositionMs ?: 0L) / 1000
        val title = selectedText.takeIf { it.isNotBlank() }
            ?: chapterId?.takeIf { it.isNotBlank() }
            ?: "Bookmark at ${AudiobookBookmark.formatTime(positionSec)}"
        return AudiobookBookmark(
            id = id,
            bookId = bookId,
            position = positionSec,
            title = title,
            note = note.takeIf { it.isNotBlank() },
            timestamp = createdAt,
            locator = locatorJson,
            mediaType = AppMediaType.AUDIOBOOK,
            chapterTitle = chapterId,
        )
    }

    private suspend fun migrateLegacyBookmarks(book: Book) {
        if (!migratedLegacyBookIds.add(book.id)) return
        val legacy = legacyBookmarkService.loadBookmarks(book)
        if (legacy.isEmpty()) return

        val existing = annotations.forBook(book.id)
            .filter { AnnotationKind.parse(it.kind) == AnnotationKind.BOOKMARK }
            .filter { AnnotationMedia.parse(it.media) == AnnotationMedia.AUDIOBOOK }
            .toMutableList()
        sync.registerBook(book)
        legacy.forEach { bookmark ->
            val positionMs = bookmark.position * 1000
            val alreadyMigrated = existing.any { row ->
                row.audioPositionMs?.let { kotlin.math.abs(it - positionMs) <= 1000L } == true &&
                    row.note == bookmark.note.orEmpty()
            }
            if (!alreadyMigrated) {
                existing += annotations.create(
                    bookId = book.id,
                    kind = AnnotationKind.BOOKMARK,
                    media = AnnotationMedia.AUDIOBOOK,
                    colorHex = "#F5921A",
                    audioPositionMs = positionMs,
                    chapterId = bookmark.chapterTitle,
                    selectedText = bookmark.chapterTitle?.takeIf { it.isNotBlank() } ?: bookmark.title,
                    note = bookmark.note.orEmpty(),
                    providerSource = book.source.name.lowercase(),
                )
            }
        }
    }
}

internal fun chapterSleepRemainingSeconds(targetPositionMs: Long, currentPositionMs: Long, playbackSpeed: Float): Long {
    val remainingMediaMs = (targetPositionMs - currentPositionMs).coerceAtLeast(0L)
    if (remainingMediaMs == 0L) return 0L
    return ceil(remainingMediaMs / 1000.0 / playbackSpeed.coerceAtLeast(0.1f)).toLong()
}
