package com.enve.app.readium

import android.content.Context
import android.util.Log
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.core.reader.MediaOverlayTimeline
import com.enve.core.reader.ReaderNarrationSource
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.io.File
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

@Singleton
class ReaderNarrationStore @Inject constructor(
    @ApplicationContext private val context: Context,
    private val offlineStorage: ComicOfflineStorage,
) : ReaderNarrationSource {
    private val narrationTimes = ConcurrentHashMap<String, Double>()
    private val timelineMutex = Mutex()
    private var cachedTimeline: Pair<String, MediaOverlayTimeline?>? = null

    fun recordNarration(bookId: String, timeSec: Double) {
        narrationTimes[bookId] = timeSec
    }

    fun clearNarration(bookId: String) {
        narrationTimes.remove(bookId)
    }

    override fun narrationTime(bookId: String): Double? = narrationTimes[bookId]

    override fun existingReaderAsset(bookId: String): File? {
        offlineStorage.getDownloadedFile(bookId)?.takeIf { it.extension.equals("epub", ignoreCase = true) }?.let { return it }
        val safeName = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        return File(context.cacheDir, "ebooks").listFiles()
            ?.filter { it.isFile && it.name.startsWith("$safeName.") && it.name.endsWith(".epub") && it.length() > 0L }
            ?.maxByOrNull(File::lastModified)
    }

    override suspend fun overlayTimeline(bookId: String): MediaOverlayTimeline? {
        val file = existingReaderAsset(bookId) ?: return null
        val key = "${file.path}|${file.length()}|${file.lastModified()}"
        return timelineMutex.withLock {
            cachedTimeline?.takeIf { it.first == key }?.let { return@withLock it.second }
            val timeline = withContext(Dispatchers.IO) {
                try {
                    MediaOverlayTimeline.load(file)
                } catch (e: IOException) {
                    Log.w(TAG, "Could not read the media overlay timeline", e)
                    null
                }
            }
            cachedTimeline = key to timeline
            timeline
        }
    }

    private companion object {
        const val TAG = "ReaderNarrationStore"
    }
}

@Module
@InstallIn(SingletonComponent::class)
abstract class ReaderNarrationModule {
    @Binds
    abstract fun bindReaderNarrationSource(store: ReaderNarrationStore): ReaderNarrationSource
}
