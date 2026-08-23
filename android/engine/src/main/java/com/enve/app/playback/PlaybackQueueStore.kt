package com.enve.app.playback

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.engine.playback.PlaybackQueueOrigin
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

@Entity(
    tableName = "playback_queue",
    indices = [Index(value = ["position"], unique = true)],
)
data class PlaybackQueueEntry(
    @PrimaryKey val bookKey: String,
    val position: Int,
    val origin: String,
    val groupKey: String?,
    val enqueuedAt: Long,
)

@Dao
interface PlaybackQueueDao {
    @Query("SELECT * FROM playback_queue ORDER BY position")
    fun observeAll(): Flow<List<PlaybackQueueEntry>>

    @Query("SELECT * FROM playback_queue ORDER BY position")
    suspend fun getAll(): List<PlaybackQueueEntry>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(entries: List<PlaybackQueueEntry>)

    @Query("DELETE FROM playback_queue WHERE bookKey = :bookKey")
    suspend fun delete(bookKey: String)

    @Query("DELETE FROM playback_queue")
    suspend fun clear()
}

@Singleton
class PlaybackQueueStore @Inject constructor(
    private val database: ReaderDatabase,
) {
    private val dao = database.playbackQueueDao()

    val entries: Flow<List<PlaybackQueueEntry>> = dao.observeAll()

    suspend fun snapshot(): List<PlaybackQueueEntry> = dao.getAll()

    suspend fun replace(
        bookKeys: List<String>,
        origin: PlaybackQueueOrigin,
        groupKey: String? = null,
    ) {
        val now = System.currentTimeMillis()
        val entries = bookKeys.distinct().mapIndexed { index, bookKey ->
            PlaybackQueueEntry(bookKey, index, origin.name, groupKey, now + index)
        }
        replaceEntries(entries)
    }

    suspend fun addNext(bookKey: String, origin: PlaybackQueueOrigin = PlaybackQueueOrigin.MANUAL) {
        mutate { current ->
            listOf(newEntry(bookKey, origin)) + current.filterNot { it.bookKey == bookKey }
        }
    }

    suspend fun addLast(bookKey: String, origin: PlaybackQueueOrigin = PlaybackQueueOrigin.MANUAL) {
        mutate { current ->
            current.filterNot { it.bookKey == bookKey } + newEntry(bookKey, origin)
        }
    }

    suspend fun addLast(bookKeys: List<String>, origin: PlaybackQueueOrigin = PlaybackQueueOrigin.MANUAL) {
        val pending = bookKeys.distinct()
        if (pending.isEmpty()) return
        val pendingKeys = pending.toSet()
        mutate { current ->
            current.filterNot { it.bookKey in pendingKeys } + pending.map { newEntry(it, origin) }
        }
    }

    suspend fun remove(bookKey: String) {
        mutate { current -> current.filterNot { it.bookKey == bookKey } }
    }

    suspend fun move(bookKey: String, delta: Int) {
        mutate { current ->
            val mutable = current.toMutableList()
            val index = mutable.indexOfFirst { it.bookKey == bookKey }
            val target = index + delta
            if (index == -1 || target !in mutable.indices) return@mutate current
            val entry = mutable.removeAt(index)
            mutable.add(target, entry)
            mutable
        }
    }

    suspend fun takeNext(): PlaybackQueueEntry? = database.withTransaction {
        val next = dao.getAll().firstOrNull() ?: return@withTransaction null
        dao.delete(next.bookKey)
        replaceEntriesLocked(dao.getAll())
        next
    }

    suspend fun clear() = dao.clear()

    private suspend fun mutate(transform: (List<PlaybackQueueEntry>) -> List<PlaybackQueueEntry>) {
        database.withTransaction {
            replaceEntriesLocked(transform(dao.getAll()))
        }
    }

    private suspend fun replaceEntries(entries: List<PlaybackQueueEntry>) {
        database.withTransaction { replaceEntriesLocked(entries) }
    }

    private suspend fun replaceEntriesLocked(entries: List<PlaybackQueueEntry>) {
        dao.clear()
        normalize(entries)
    }

    private suspend fun normalize(entries: List<PlaybackQueueEntry>) {
        val normalized = entries.distinctBy(PlaybackQueueEntry::bookKey).mapIndexed { index, entry ->
            entry.copy(position = index)
        }
        if (normalized.isNotEmpty()) dao.insertAll(normalized)
    }

    private fun newEntry(bookKey: String, origin: PlaybackQueueOrigin): PlaybackQueueEntry =
        PlaybackQueueEntry(
            bookKey = bookKey,
            position = 0,
            origin = origin.name,
            groupKey = null,
            enqueuedAt = System.currentTimeMillis(),
        )
}
