package com.enve.app.data.hardcover

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.di.ApplicationScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.Flow
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

private const val DATABASE_NAME = "hardcover_outbox.db"
private const val BASE_BACKOFF_MS = 30_000L
private const val MAX_BACKOFF_MS = 30 * 60_000L

@Entity(tableName = "hardcover_outbox", indices = [Index("accountKey", "localKey")])
data class HardcoverOutboxEvent(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val accountKey: String,
    val localKey: String,
    val bookId: String,
    val connectionId: String?,
    val mediaType: AppMediaType,
    val title: String,
    val author: String?,
    val isbn10: String?,
    val isbn13: String?,
    val asin: String?,
    val fraction: Float,
    val finished: Boolean,
    val occurredAt: Long,
    val startedAt: Long = occurredAt,
    val initialFraction: Float = fraction,
    val attempts: Int = 0,
    val nextAttemptAt: Long = 0,
    val waitingForNetwork: Boolean = false,
    val failed: Boolean = false,
    val lastError: String? = null,
)

@Dao
interface HardcoverOutboxDao {
    @Insert
    suspend fun insert(event: HardcoverOutboxEvent): Long

    @Query("SELECT * FROM hardcover_outbox WHERE accountKey = :accountKey ORDER BY id")
    suspend fun forAccount(accountKey: String): List<HardcoverOutboxEvent>

    @Query("SELECT * FROM hardcover_outbox WHERE accountKey = :accountKey ORDER BY id")
    fun observe(accountKey: String): Flow<List<HardcoverOutboxEvent>>

    @Query("SELECT * FROM hardcover_outbox WHERE accountKey = :accountKey AND localKey = :localKey ORDER BY id")
    suspend fun forBook(accountKey: String, localKey: String): List<HardcoverOutboxEvent>

    @Query("DELETE FROM hardcover_outbox WHERE id IN (:ids)")
    suspend fun delete(ids: List<Long>)

    @Query(
        "UPDATE hardcover_outbox SET attempts = :attempts, nextAttemptAt = :nextAttemptAt, " +
            "waitingForNetwork = :waitingForNetwork, lastError = :error WHERE id = :id",
    )
    suspend fun defer(id: Long, attempts: Int, nextAttemptAt: Long, waitingForNetwork: Boolean, error: String)

    @Query("UPDATE hardcover_outbox SET failed = 1, lastError = :error WHERE id = :id")
    suspend fun fail(id: Long, error: String)

    @Query(
        "UPDATE hardcover_outbox SET failed = 0, attempts = 0, nextAttemptAt = 0, waitingForNetwork = 0, lastError = NULL " +
            "WHERE accountKey = :accountKey AND failed = 1",
    )
    suspend fun retryFailed(accountKey: String)

    @Query(
        "UPDATE hardcover_outbox SET failed = 0, attempts = 0, nextAttemptAt = 0, waitingForNetwork = 0, lastError = NULL " +
            "WHERE accountKey = :accountKey AND localKey = :localKey AND failed = 1",
    )
    suspend fun retryBook(accountKey: String, localKey: String)

    @Query("DELETE FROM hardcover_outbox WHERE accountKey = :accountKey AND failed = 1")
    suspend fun discardFailed(accountKey: String)

    @Query("DELETE FROM hardcover_outbox WHERE localKey = :localKey")
    suspend fun deleteBook(localKey: String)

    @Query("UPDATE hardcover_outbox SET nextAttemptAt = :now WHERE accountKey = :accountKey AND waitingForNetwork = 1 AND failed = 0")
    suspend fun networkRestored(accountKey: String, now: Long)

    @Query("DELETE FROM hardcover_outbox")
    suspend fun clear()

    @Transaction
    suspend fun enqueue(event: HardcoverOutboxEvent): Long {
        val tail = forBook(event.accountKey, event.localKey).lastOrNull()
        if (tail == null || tail.finished != event.finished || tail.failed) return insert(event)
        if (event.finished) return tail.id
        delete(listOf(tail.id))
        return insert(event.copy(
            startedAt = tail.startedAt,
            initialFraction = tail.initialFraction,
            attempts = tail.attempts,
            nextAttemptAt = tail.nextAttemptAt,
            waitingForNetwork = tail.waitingForNetwork,
            lastError = tail.lastError,
        ))
    }
}

@Database(entities = [HardcoverOutboxEvent::class], version = 1, exportSchema = false)
abstract class HardcoverOutboxDatabase : RoomDatabase() {
    abstract fun outboxDao(): HardcoverOutboxDao
}

@Singleton
class HardcoverOutbox @Inject constructor(
    @ApplicationContext private val context: Context,
    private val locations: ProfileStorageLocations,
    @ApplicationScope private val scope: CoroutineScope,
) {
    val dao: HardcoverOutboxDao by lazy {
        val directory = checkNotNull(locations.readerDatabaseFile.parentFile).apply { mkdirs() }
        val database = Room.databaseBuilder(context, HardcoverOutboxDatabase::class.java, File(directory, DATABASE_NAME).absolutePath)
            .build()
        scope.coroutineContext[Job]?.invokeOnCompletion { database.close() }
        database.outboxDao()
    }
}

internal data class HardcoverOutboxSchedule(val ready: HardcoverOutboxEvent?, val wakeAt: Long?)

internal fun hardcoverOutboxSchedule(
    events: List<HardcoverOutboxEvent>,
    now: Long,
    lastSentAt: Map<String, Long>,
    progressIntervalMs: Long,
): HardcoverOutboxSchedule {
    val heads = events.sortedBy { it.id }.distinctBy { it.localKey }.filterNot { it.failed }
    fun readyAt(event: HardcoverOutboxEvent): Long =
        if (event.finished) event.nextAttemptAt
        else maxOf(event.nextAttemptAt, lastSentAt[event.localKey]?.plus(progressIntervalMs) ?: 0L)
    val ready = heads.firstOrNull { readyAt(it) <= now }
    return HardcoverOutboxSchedule(ready, if (ready == null) heads.minOfOrNull(::readyAt) else null)
}

internal fun hardcoverBackoffMs(attempts: Int): Long =
    (BASE_BACKOFF_MS shl (attempts - 1).coerceIn(0, 6)).coerceAtMost(MAX_BACKOFF_MS)

data class HardcoverQueueFailure(val id: Long, val title: String, val message: String)

data class HardcoverQueueSummary(
    val pending: Int = 0,
    val failed: List<HardcoverQueueFailure> = emptyList(),
    val storageError: String? = null,
)

internal fun hardcoverQueueSummary(events: List<HardcoverOutboxEvent>, storageError: String?): HardcoverQueueSummary =
    HardcoverQueueSummary(
        pending = events.count { !it.failed },
        failed = events.filter { it.failed }.map { HardcoverQueueFailure(it.id, it.title, it.lastError ?: "Hardcover rejected this update.") },
        storageError = storageError,
    )
