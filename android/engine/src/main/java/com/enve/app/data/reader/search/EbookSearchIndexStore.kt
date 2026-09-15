package com.enve.app.data.reader.search

import android.content.Context
import android.database.sqlite.SQLiteException
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.CancellationException

private const val DIRECTORY = "ebook-search-index"
private const val SUFFIX = ".db"
private const val MAX_CACHE_BYTES = 150L * 1024L * 1024L
private val SIDECARS = listOf("-wal", "-shm", "-journal")

class EbookSearchIndexHandle(
    val database: EbookSearchIndexDatabase,
    val indexMutex: Mutex,
)

@Singleton
class EbookSearchIndexStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val lock = Mutex()
    private val open = HashMap<String, OpenIndex>()

    suspend fun acquire(fingerprint: String): EbookSearchIndexHandle = lock.withLock {
        open[fingerprint]?.let {
            it.refCount++
            return@withLock it.handle
        }
        val directory = File(context.cacheDir, DIRECTORY).apply { mkdirs() }
        trim(directory, open.keys + fingerprint)
        val file = File(directory, "$fingerprint$SUFFIX")
        val database = try {
            openVerified(file, fingerprint)
        } catch (error: CancellationException) {
            throw error
        } catch (_: SQLiteException) {
            delete(file)
            openVerified(file, fingerprint)
        } catch (_: IllegalStateException) {
            delete(file)
            openVerified(file, fingerprint)
        }
        val handle = EbookSearchIndexHandle(database, Mutex())
        file.setLastModified(System.currentTimeMillis())
        open[fingerprint] = OpenIndex(handle)
        handle
    }

    suspend fun release(fingerprint: String) = lock.withLock {
        val entry = open[fingerprint] ?: return@withLock
        entry.refCount--
        if (entry.refCount > 0) return@withLock
        open.remove(fingerprint)
        entry.handle.database.close()
        trim(File(context.cacheDir, DIRECTORY), open.keys)
    }

    private suspend fun openVerified(file: File, fingerprint: String): EbookSearchIndexDatabase {
        var database = build(file)
        try {
            val stored = database.searchDao().meta(META_FINGERPRINT)
            if (stored != null && stored != fingerprint) {
                database.close()
                delete(file)
                database = build(file)
            }
            if (database.searchDao().meta(META_FINGERPRINT) == null) {
                database.searchDao().putMeta(SearchMetaEntity(META_FINGERPRINT, fingerprint))
            }
            return database
        } catch (error: Exception) {
            database.close()
            throw error
        }
    }

    private fun build(file: File): EbookSearchIndexDatabase =
        Room.databaseBuilder(context, EbookSearchIndexDatabase::class.java, file.absolutePath)
            .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
            .addCallback(object : RoomDatabase.Callback() {
                override fun onOpen(db: SupportSQLiteDatabase) {
                    db.execSQL("PRAGMA synchronous = NORMAL")
                }
            })
            .build()

    private fun trim(directory: File, keep: Set<String>) {
        val databases = directory.listFiles()
            ?.filter { it.isFile && it.name.endsWith(SUFFIX) }
            ?: return
        var total = databases.sumOf(::sizeOf)
        if (total <= MAX_CACHE_BYTES) return
        for (file in databases.sortedBy { it.lastModified() }) {
            if (total <= MAX_CACHE_BYTES) return
            if (file.name.removeSuffix(SUFFIX) in keep) continue
            total -= sizeOf(file)
            delete(file)
        }
    }

    private fun sizeOf(file: File): Long =
        file.length() + SIDECARS.sumOf { File(file.path + it).length() }

    private fun delete(file: File) {
        file.delete()
        SIDECARS.forEach { File(file.path + it).delete() }
    }

    private class OpenIndex(val handle: EbookSearchIndexHandle) {
        var refCount = 1
    }
}
