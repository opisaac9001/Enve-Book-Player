package com.enve.wear.listening

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

class WatchLibraryStore private constructor(context: Context) {
    private val root = File(context.filesDir, "watch-books").apply { mkdirs() }
    private val file = AtomicFile(File(root, "library.json"))
    private val json = Json { ignoreUnknownKeys = true }
    private val mutable = MutableStateFlow(if (file.baseFile.exists()) json.decodeFromString<WatchLibrary>(file.readFully().decodeToString()) else WatchLibrary())
    val state = mutable.asStateFlow()

    fun directory(key: String): File {
        require(key.matches(Regex("[0-9a-f]{64}")))
        return File(root, key).apply { mkdirs() }
    }

    @Synchronized
    fun saveBook(book: WatchBook) = save(mutable.value.copy(books = mutable.value.books.filterNot { it.key == book.key } + book))

    @Synchronized
    fun savePosition(
        key: String,
        positionMs: Long,
        updatedAt: Long = System.currentTimeMillis(),
    ) {
        val old = mutable.value.positions[key] ?: WatchPosition()
        if (updatedAt < old.updatedAt) return
        val position = old.copy(positionMs = positionMs, updatedAt = updatedAt)
        val book = mutable.value.books.firstOrNull { it.key == key }
        val baseline = mutable.value.progressBaselines[key]
        val pending = if (book != null) {
            mutable.value.pendingProgress + (key to WatchPendingProgress(
                account = book.account,
                bookId = book.id,
                positionMs = positionMs,
                updatedAt = updatedAt,
                baselinePositionMs = baseline?.positionMs,
                baselineUpdatedAt = baseline?.updatedAt,
            ))
        } else {
            mutable.value.pendingProgress
        }
        save(mutable.value.copy(
            positions = mutable.value.positions + (key to position),
            pendingProgress = pending,
        ))
    }

    @Synchronized
    fun applyRemoteProgress(key: String, remote: WatchRemoteProgress) {
        if (mutable.value.pendingProgress.containsKey(key)) return
        val old = mutable.value.positions[key] ?: WatchPosition()
        save(mutable.value.copy(
            positions = mutable.value.positions + (key to old.copy(positionMs = remote.positionMs, updatedAt = System.currentTimeMillis())),
            progressBaselines = mutable.value.progressBaselines + (key to WatchProgressBaseline(remote.positionMs, remote.updatedAt)),
            progressConflicts = mutable.value.progressConflicts - key,
        ))
    }

    @Synchronized
    fun recordProgressConflict(key: String, pending: WatchPendingProgress, remote: WatchRemoteProgress) {
        save(mutable.value.copy(progressConflicts = mutable.value.progressConflicts + (key to WatchProgressConflict(
            localPositionMs = pending.positionMs,
            localUpdatedAt = pending.updatedAt,
            remotePositionMs = remote.positionMs,
            remoteUpdatedAt = remote.updatedAt,
        ))))
    }

    @Synchronized
    fun acceptRemoteProgress(key: String) {
        val conflict = mutable.value.progressConflicts[key] ?: return
        val old = mutable.value.positions[key] ?: WatchPosition()
        save(mutable.value.copy(
            positions = mutable.value.positions + (key to old.copy(positionMs = conflict.remotePositionMs, updatedAt = System.currentTimeMillis())),
            progressBaselines = mutable.value.progressBaselines + (key to WatchProgressBaseline(conflict.remotePositionMs, conflict.remoteUpdatedAt)),
            pendingProgress = mutable.value.pendingProgress - key,
            progressConflicts = mutable.value.progressConflicts - key,
        ))
    }

    @Synchronized
    fun acceptLocalProgress(key: String) {
        val conflict = mutable.value.progressConflicts[key] ?: return
        val pending = mutable.value.pendingProgress[key] ?: return
        save(mutable.value.copy(
            progressBaselines = mutable.value.progressBaselines + (key to WatchProgressBaseline(conflict.remotePositionMs, conflict.remoteUpdatedAt)),
            pendingProgress = mutable.value.pendingProgress + (key to pending.copy(
                baselinePositionMs = conflict.remotePositionMs,
                baselineUpdatedAt = conflict.remoteUpdatedAt,
            )),
            progressConflicts = mutable.value.progressConflicts - key,
        ))
    }

    @Synchronized
    fun completeProgressPush(key: String, pushed: WatchPendingProgress, remote: WatchRemoteProgress) {
        val current = mutable.value.pendingProgress[key] ?: return
        val baseline = WatchProgressBaseline(remote.positionMs, remote.updatedAt)
        val pending = if (current.updatedAt == pushed.updatedAt && current.positionMs == pushed.positionMs) {
            mutable.value.pendingProgress - key
        } else {
            mutable.value.pendingProgress + (key to current.copy(
                baselinePositionMs = baseline.positionMs,
                baselineUpdatedAt = baseline.updatedAt,
            ))
        }
        save(mutable.value.copy(
            progressBaselines = mutable.value.progressBaselines + (key to baseline),
            pendingProgress = pending,
            progressConflicts = mutable.value.progressConflicts - key,
        ))
    }

    @Synchronized
    fun bookmark(key: String, positionMs: Long) {
        val old = mutable.value.positions[key] ?: WatchPosition()
        save(mutable.value.copy(positions = mutable.value.positions + (key to old.copy(bookmarks = (old.bookmarks + positionMs).distinct().sorted()))))
    }

    @Synchronized
    fun removeDownload(key: String) {
        val old = mutable.value.books.firstOrNull { it.key == key } ?: return
        saveBook(old.copy(downloaded = false, tracks = emptyList()))
        directory(key).deleteRecursively()
    }

    private fun save(value: WatchLibrary) {
        val output = file.startWrite()
        try {
            output.write(json.encodeToString(value).toByteArray())
            file.finishWrite(output)
            mutable.value = value
        } catch (error: Exception) {
            file.failWrite(output)
            throw error
        }
    }

    companion object {
        @Volatile private var instance: WatchLibraryStore? = null
        fun get(context: Context): WatchLibraryStore = instance ?: synchronized(this) {
            instance ?: WatchLibraryStore(context.applicationContext).also { instance = it }
        }
    }
}
