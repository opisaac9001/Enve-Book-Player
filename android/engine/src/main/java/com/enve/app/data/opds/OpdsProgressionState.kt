package com.enve.app.data.opds

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Transaction
import com.enve.core.data.util.stringLiteralOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

@Entity(tableName = "opds_progression_state")
data class OpdsProgressionStateEntity(
    @PrimaryKey val bookKey: String,
    val unhandledReferences: String,
    val updatedAt: Long,
    val authenticateUrl: String? = null,
    val additionalMembers: String? = null,
)

data class OpdsProgressionAuthenticateHint(val bookKey: String, val url: String)

@Dao
interface OpdsProgressionStateDao {
    @Query("SELECT * FROM opds_progression_state WHERE bookKey = :bookKey LIMIT 1")
    suspend fun get(bookKey: String): OpdsProgressionStateEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: OpdsProgressionStateEntity)

    @Query("DELETE FROM opds_progression_state WHERE bookKey = :bookKey")
    suspend fun delete(bookKey: String)

    @Query("UPDATE opds_progression_state SET authenticateUrl = :url WHERE bookKey = :bookKey")
    suspend fun setAuthenticateUrl(bookKey: String, url: String?): Int

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insertIfAbsent(entity: OpdsProgressionStateEntity): Long

    @Transaction
    suspend fun saveAuthenticateHints(hints: List<OpdsProgressionAuthenticateHint>, nowMs: Long) {
        hints.forEach { hint ->
            if (setAuthenticateUrl(hint.bookKey, hint.url) > 0) return@forEach
            insertIfAbsent(
                OpdsProgressionStateEntity(
                    bookKey = hint.bookKey,
                    unhandledReferences = EMPTY_REFERENCES,
                    updatedAt = nowMs,
                    authenticateUrl = hint.url,
                ),
            )
        }
    }
}

data class OpdsProgressionCarryover(
    val references: List<String> = emptyList(),
    val additionalMembers: JsonObject = JsonObject(emptyMap()),
)

@Singleton
class OpdsProgressionStateStore @Inject constructor(
    private val dao: OpdsProgressionStateDao,
) {

    suspend fun carryover(connectionId: String, bookId: String): OpdsProgressionCarryover {
        val row = dao.get(bookKey(connectionId, bookId)) ?: return OpdsProgressionCarryover()
        return OpdsProgressionCarryover(
            references = decodeReferences(row.unhandledReferences),
            additionalMembers = decodeMembers(row.additionalMembers),
        )
    }

    suspend fun save(
        connectionId: String,
        bookId: String,
        references: List<String>,
        additionalMembers: JsonObject,
    ) {
        val key = bookKey(connectionId, bookId)
        val authenticateUrl = dao.get(key)?.authenticateUrl
        if (references.isEmpty() && additionalMembers.isEmpty() && authenticateUrl == null) {
            dao.delete(key)
            return
        }
        dao.upsert(
            OpdsProgressionStateEntity(
                bookKey = key,
                unhandledReferences = encodeReferences(references),
                updatedAt = System.currentTimeMillis(),
                authenticateUrl = authenticateUrl,
                additionalMembers = additionalMembers.takeIf { it.isNotEmpty() }?.toString(),
            ),
        )
    }

    suspend fun authenticateUrl(connectionId: String, bookId: String): String? =
        dao.get(bookKey(connectionId, bookId))?.authenticateUrl

    suspend fun saveAuthenticateUrls(connectionId: String, urlsByBookId: Map<String, String>) {
        if (urlsByBookId.isEmpty()) return
        dao.saveAuthenticateHints(
            urlsByBookId.map { (bookId, url) -> OpdsProgressionAuthenticateHint(bookKey(connectionId, bookId), url) },
            System.currentTimeMillis(),
        )
    }

    private fun bookKey(connectionId: String, bookId: String): String = "$connectionId:$bookId"
}

internal fun encodeReferences(references: List<String>): String =
    JsonArray(references.map(::JsonPrimitive)).toString()

internal fun decodeReferences(payload: String): List<String> =
    runCatching {
        (stateJson.parseToJsonElement(payload) as JsonArray).mapNotNull {
            it.stringLiteralOrNull()
        }
    }.getOrDefault(emptyList())

internal fun decodeMembers(payload: String?): JsonObject {
    val text = payload?.takeIf { it.isNotBlank() } ?: return JsonObject(emptyMap())
    return runCatching { stateJson.parseToJsonElement(text) as JsonObject }.getOrDefault(JsonObject(emptyMap()))
}

internal const val EMPTY_REFERENCES = "[]"

private val stateJson = Json { ignoreUnknownKeys = true }
