package com.enve.app.hearth

import android.content.Context
import android.util.Log
import androidx.core.content.FileProvider
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.sync.SyncCoordinator
import com.enve.app.playback.AudioPlaybackManager
import com.enve.app.playback.AutoMediaBrowserHelper
import com.enve.app.playback.PlaybackChapterStore
import com.enve.app.playback.ambient.AmbientAudioService
import com.enve.app.playback.clips.AudiobookClipService
import com.enve.app.playback.clips.AudiobookClipStore
import com.enve.app.playback.sleep.AutoSleepService
import com.enve.app.playback.sleep.ShakeDetectionService
import com.enve.app.playback.sleep.SleepAutomationStore
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.di.ApplicationScope
import com.enve.engine.playback.AmbientAudioState
import com.enve.engine.playback.AudiobookClip
import com.enve.engine.playback.AudiobookClipException
import com.enve.engine.playback.ClipShare
import com.enve.engine.playback.ClipTranscriptionModel
import com.enve.engine.playback.PlayerExtrasFacade
import com.enve.engine.playback.PlayerSessionFacade
import com.enve.engine.playback.SleepAutomationSettings
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@OptIn(ExperimentalCoroutinesApi::class)
@Singleton
class PlayerExtrasFacadeImpl @Inject constructor(
    @ApplicationContext private val context: Context,
    private val clipStore: AudiobookClipStore,
    private val clipService: AudiobookClipService,
    private val sleepStore: SleepAutomationStore,
    private val shakeDetection: ShakeDetectionService,
    private val ambientAudio: AmbientAudioService,
    private val session: PlayerSessionFacade,
    private val audioManager: AudioPlaybackManager,
    private val chapterStore: PlaybackChapterStore,
    private val annotations: AnnotationRepository,
    private val sync: SyncCoordinator,
    private val bookCache: BookCacheDao,
    private val offline: OfflineDownloadManager,
    autoSleep: AutoSleepService,
    @ApplicationScope parentScope: CoroutineScope,
) : PlayerExtrasFacade {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.Default)

    private val playingBook: StateFlow<Book?> =
        combine(
            audioManager.currentBookIdFlow,
            audioManager.state.map { it.mediaId?.let(AutoMediaBrowserHelper::cacheKeyFrom) },
        ) { bookId, cacheKey -> bookId to cacheKey }
            .distinctUntilChanged()
            .mapLatest { (bookId, cacheKey) ->
                if (bookId == null || cacheKey == null) null
                else bookCache.getByCacheKey(cacheKey)?.toBook()?.takeIf { it.id == bookId }
            }
            .stateIn(scope, SharingStarted.Eagerly, null)

    override val clips: StateFlow<List<AudiobookClip>> =
        combine(clipStore.clips, playingBook, session.bookmarks) { clips, book, bookmarks ->
            val bookmarkIds = bookmarks.mapTo(mutableSetOf()) { it.id }
            clips.filter { it.bookKey == book?.uniqueKey && it.bookmarkId in bookmarkIds }
        }.stateIn(scope, SharingStarted.WhileSubscribed(5_000), emptyList())

    override val clipBookKey: StateFlow<String?> =
        combine(playingBook, offline.downloadedKeys) { book, _ -> book }
            .mapLatest { book -> book?.takeIf { clipService.hasLocalAudio(it) }?.uniqueKey }
            .stateIn(scope, SharingStarted.WhileSubscribed(5_000), null)

    override val transcriptionModel: StateFlow<ClipTranscriptionModel> = clipService.transcriptionModel

    override val sleepAutomation: StateFlow<SleepAutomationSettings> = sleepStore.settings
    override val shakeAvailable: Boolean get() = shakeDetection.isAvailable

    override val ambient: StateFlow<AmbientAudioState> = ambientAudio.state

    init {
        autoSleep.start()
        scope.launch {
            try {
                clipStore.load()
            } catch (error: IOException) {
                Log.w(TAG, "Audiobook clips are unreadable", error)
                return@launch
            }
            combine(playingBook, session.bookmarks) { book, bookmarks -> book to bookmarks }
                .collectLatest { (book, bookmarks) ->
                    if (book == null) return@collectLatest
                    try {
                        pruneDeletedBookmarkClips(book, bookmarks.mapTo(mutableSetOf()) { it.id })
                    } catch (error: IOException) {
                        Log.w(TAG, "Couldn't remove clips for deleted bookmarks", error)
                    }
                }
        }
    }

    override suspend fun saveClip(bookKey: String, bookmarkId: String?, anchorMs: Long, startMs: Long, endMs: Long, note: String?) =
        clipStorage {
            val book = requireBook(bookKey)
            if (endMs <= startMs || startMs < 0) throw AudiobookClipException("The clip range is invalid.")
            if (endMs - startMs > AudiobookClip.MAX_DURATION_MS) throw AudiobookClipException("Clips are limited to one hour.")
            if (!clipService.hasLocalAudio(book)) throw AudiobookClipException("Download “${book.title}” before cutting clips from it.")
            val trimmedNote = note?.trim().orEmpty()
            val id = if (bookmarkId != null) {
                val row = requireBookmark(book, bookmarkId)
                clipStore.clip(bookmarkId)?.let { existing -> if (existing.bookKey != book.uniqueKey) throw staleClip() }
                if (row.note != trimmedNote) {
                    sync.registerBook(book)
                    annotations.update(row, note = trimmedNote)
                }
                row.id
            } else {
                val chapterTitle = chapterStore.snapshot.value.takeIf { it.cacheKey == book.uniqueKey }
                    ?.let { snapshot -> snapshot.chapters.getOrNull(snapshot.chapterIndexAt(anchorMs / 1000))?.title }
                sync.registerBook(book)
                annotations.create(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    kind = AnnotationKind.BOOKMARK,
                    media = AnnotationMedia.AUDIOBOOK,
                    colorHex = "#F5921A",
                    audioPositionMs = anchorMs / 1000 * 1000,
                    chapterId = chapterTitle,
                    selectedText = chapterTitle.orEmpty(),
                    note = trimmedNote,
                    providerSource = book.source.name.lowercase(),
                ).id
            }
            val existing = clipStore.clip(id)
            clipStore.upsert(
                AudiobookClip(
                    bookmarkId = id,
                    bookKey = book.uniqueKey,
                    startMs = startMs,
                    endMs = endMs,
                    createdAtMs = existing?.createdAtMs ?: System.currentTimeMillis(),
                    transcript = existing?.transcript?.takeIf { existing.startMs == startMs && existing.endMs == endMs },
                ),
            )
        }

    override suspend fun deleteClip(bookKey: String, bookmarkId: String) = clipStorage {
        requireClip(bookKey, bookmarkId)
        clipStore.delete(setOf(bookmarkId))
    }

    override suspend fun exportClip(bookKey: String, bookmarkId: String): ClipShare = clipStorage {
        val book = requireBook(bookKey)
        val clip = requireClip(bookKey, bookmarkId)
        val title = requireBookmark(book, bookmarkId).displayTitle()
        val file = clipService.export(book, clip, title)
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        ClipShare(uri = uri.toString(), mimeType = "audio/mp4", title = title)
    }

    override suspend fun transcribeClip(bookKey: String, bookmarkId: String): String = clipStorage {
        val book = requireBook(bookKey)
        val clip = requireClip(bookKey, bookmarkId)
        requireBookmark(book, bookmarkId)
        clip.transcript?.takeIf { it.isNotBlank() } ?: clipService.transcribe(book, clip)
    }

    override suspend fun installTranscriptionModel() = clipService.installTranscriptionModel()

    override suspend fun updateSleepAutomation(settings: SleepAutomationSettings) = sleepStore.update(settings)

    override fun attachAmbientPreset(presetId: String) = ambientAudio.attachPreset(presetId)
    override suspend fun attachAmbientTrack(uri: String) = ambientAudio.attachTrack(uri)
    override fun removeAmbient() = ambientAudio.remove()
    override fun setAmbientVolume(volume: Float) = ambientAudio.setVolume(volume)
    override fun clearAmbientError() = ambientAudio.clearError()

    private suspend fun <T> clipStorage(block: suspend () -> T): T = try {
        block()
    } catch (_: IOException) {
        throw AudiobookClipException("Clips couldn't be read or saved on this device.")
    }

    private suspend fun requireBook(bookKey: String): Book =
        bookCache.getByCacheKey(bookKey)?.toBook()?.takeIf { it.uniqueKey == bookKey }
            ?: throw AudiobookClipException("This book is no longer in your library.")

    private suspend fun requireBookmark(book: Book, bookmarkId: String): ReaderAnnotation =
        annotations.byId(bookmarkId)?.takeIf {
            it.deletedAt == null &&
                it.bookId == book.id &&
                it.connectionId == book.connectionId &&
                AnnotationKind.parse(it.kind) == AnnotationKind.BOOKMARK
        } ?: throw AudiobookClipException("The clip's bookmark no longer exists.")

    private suspend fun requireClip(bookKey: String, bookmarkId: String): AudiobookClip =
        clipStore.clip(bookmarkId)?.takeIf { it.bookKey == bookKey } ?: throw staleClip()

    private fun staleClip() = AudiobookClipException("That clip no longer exists.")

    private fun ReaderAnnotation.displayTitle(): String =
        selectedText.takeIf { it.isNotBlank() } ?: chapterId?.takeIf { it.isNotBlank() } ?: "Clip"

    private suspend fun pruneDeletedBookmarkClips(book: Book, liveBookmarkIds: Set<String>) {
        val candidates = clipStore.clips.value.filter { it.bookKey == book.uniqueKey && it.bookmarkId !in liveBookmarkIds }
        val deleted = candidates.filter { clip -> annotations.byId(clip.bookmarkId).let { it == null || it.deletedAt != null } }
        if (deleted.isNotEmpty()) clipStore.delete(deleted.mapTo(mutableSetOf()) { it.bookmarkId })
    }

    private companion object {
        const val TAG = "PlayerExtras"
    }
}
