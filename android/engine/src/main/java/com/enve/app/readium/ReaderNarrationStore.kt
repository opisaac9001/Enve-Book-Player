package com.enve.app.readium

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import android.util.Log
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.core.data.model.BookSource
import com.enve.core.reader.MediaOverlayTimeline
import com.enve.core.reader.ReaderNarrationKey
import com.enve.core.reader.ReaderNarrationSource
import dagger.Binds
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.io.File
import java.io.IOException
import java.security.MessageDigest
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
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) : ReaderNarrationSource {
    private val narrationTimes = ConcurrentHashMap<ReaderNarrationKey, Double>()
    private val timelineMutex = Mutex()
    private var cachedTimeline: Pair<String, MediaOverlayTimeline?>? = null

    fun recordNarration(key: ReaderNarrationKey, timeSec: Double) {
        narrationTimes[key] = timeSec
    }

    fun clearNarration(key: ReaderNarrationKey) {
        narrationTimes.remove(key)
    }

    override fun narrationTime(key: ReaderNarrationKey): Double? = narrationTimes[key]

    override fun existingReaderAsset(key: ReaderNarrationKey): File? {
        offlineStorage.getDownloadedFile(offlineDownloadKey(key.source, key.connectionId, key.bookId))
            ?.takeIf { it.extension.equals("epub", ignoreCase = true) }
            ?.let { return it }
        val safeName = key.bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        return cachedEbookDirectory(key).listFiles()
            ?.filter { it.isFile && it.name.startsWith("$safeName.") && it.name.endsWith(".epub") && it.length() > 0L }
            ?.maxByOrNull(File::lastModified)
    }

    private fun cachedEbookDirectory(key: ReaderNarrationKey): File {
        val root = File(locations.cacheDirectory, "ebooks")
        if (key.source == BookSource.LOCAL) return root
        val identity = "${key.source.name}|${key.connectionId.orEmpty()}"
        val digest = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray())
            .joinToString("") { "%02x".format(it) }
        return File(root, digest)
    }

    override suspend fun overlayTimeline(key: ReaderNarrationKey): MediaOverlayTimeline? {
        val file = existingReaderAsset(key) ?: return null
        val fileKey = "${file.path}|${file.length()}|${file.lastModified()}"
        return timelineMutex.withLock {
            cachedTimeline?.takeIf { it.first == fileKey }?.let { return@withLock it.second }
            val timeline = withContext(Dispatchers.IO) {
                try {
                    MediaOverlayTimeline.load(file)
                } catch (e: IOException) {
                    Log.w(TAG, "Could not read the media overlay timeline", e)
                    null
                }
            }
            cachedTimeline = fileKey to timeline
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
