package com.enve.app.data.reader

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

@Entity(tableName = "epub_bridge_checkpoints")
data class EpubBridgeCheckpointEntity(
    @PrimaryKey val bookKey: String,
    val publicationSha256: String,
    val providerFileId: String?,
    val schemaVersion: Int,
    val revision: Long,
    val writerEpoch: Long,
    val observedAt: Long,
    val checkpointJson: String,
)

@Dao
interface EpubBridgeCheckpointDao {
    @Query("SELECT * FROM epub_bridge_checkpoints WHERE bookKey = :bookKey LIMIT 1")
    suspend fun get(bookKey: String): EpubBridgeCheckpointEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: EpubBridgeCheckpointEntity)
}

data class ReaderCheckpointLease(
    val bookKey: String,
    val publicationSha256: String,
    val providerFileId: String?,
    val writerEpoch: Long,
    val checkpoint: EpubBridgeCheckpoint?,
)

internal fun checkpointWriteIsCurrent(
    currentWriterEpoch: Long,
    currentRevision: Long,
    leaseWriterEpoch: Long,
    expectedRevision: Long,
): Boolean =
    currentWriterEpoch == leaseWriterEpoch && currentRevision == expectedRevision

@Singleton
class EpubBridgeCheckpointStore @Inject constructor(
    private val database: ReaderDatabase,
) {
    private val mutex = Mutex()

    suspend fun beginSession(
        bookKey: String,
        publicationSha256: String,
        providerFileId: String?,
        engine: ReaderEngineKind,
    ): ReaderCheckpointLease = mutex.withLock {
        database.withTransaction {
            val dao = database.epubBridgeCheckpointDao()
            val current = dao.get(bookKey)
            val epoch = (current?.writerEpoch ?: 0L) + 1L
            val checkpoint = current
                ?.let { EpubBridgeCheckpointCodec.decode(it.checkpointJson) }
                ?.forPublication(publicationSha256, providerFileId)
                ?.copy(
                    revision = current.revision,
                    writerEpoch = epoch,
                )
            val stored = checkpoint ?: EpubBridgeCheckpoint(
                publicationSha256 = publicationSha256,
                providerFileId = providerFileId,
                revision = current?.revision ?: 0L,
                writerEpoch = epoch,
                observedAt = current?.observedAt ?: 0L,
                sourceEngine = engine,
            )
            dao.upsert(stored.toEntity(bookKey))
            ReaderCheckpointLease(
                bookKey = bookKey,
                publicationSha256 = publicationSha256,
                providerFileId = providerFileId,
                writerEpoch = epoch,
                checkpoint = checkpoint,
            )
        }
    }

    suspend fun commit(
        lease: ReaderCheckpointLease,
        checkpoint: EpubBridgeCheckpoint,
    ): EpubBridgeCheckpoint? = mutex.withLock {
        database.withTransaction {
            val dao = database.epubBridgeCheckpointDao()
            val current = dao.get(lease.bookKey) ?: return@withTransaction null
            if (
                !checkpointWriteIsCurrent(
                    currentWriterEpoch = current.writerEpoch,
                    currentRevision = current.revision,
                    leaseWriterEpoch = lease.writerEpoch,
                    expectedRevision = checkpoint.revision,
                )
            ) {
                return@withTransaction null
            }
            val committed = checkpoint.copy(
                publicationSha256 = lease.publicationSha256,
                providerFileId = lease.providerFileId,
                schemaVersion = EpubBridgeCheckpoint.CURRENT_SCHEMA_VERSION,
                revision = current.revision + 1L,
                writerEpoch = lease.writerEpoch,
            )
            dao.upsert(committed.toEntity(lease.bookKey))
            committed
        }
    }

    suspend fun checkpoint(bookKey: String): EpubBridgeCheckpoint? =
        database.epubBridgeCheckpointDao()
            .get(bookKey)
            ?.let { EpubBridgeCheckpointCodec.decode(it.checkpointJson) }

    private fun EpubBridgeCheckpoint.toEntity(bookKey: String) =
        EpubBridgeCheckpointEntity(
            bookKey = bookKey,
            publicationSha256 = publicationSha256,
            providerFileId = providerFileId,
            schemaVersion = schemaVersion,
            revision = revision,
            writerEpoch = writerEpoch,
            observedAt = observedAt,
            checkpointJson = EpubBridgeCheckpointCodec.encode(this),
        )
}
