package com.enve.app.data.opds

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Index
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.PrimaryKey
import androidx.room.Query
import androidx.room.Transaction
import com.enve.app.data.repository.OpdsAcquisition
import com.enve.app.data.repository.OpdsAcquisitionKind
import com.enve.app.data.repository.OpdsAvailability
import com.enve.app.data.repository.OpdsCopies
import com.enve.app.data.repository.OpdsDrm
import com.enve.app.data.repository.OpdsFormat
import com.enve.app.data.repository.OpdsHolds
import com.enve.app.data.repository.OpdsIndirectAcquisition
import com.enve.app.data.repository.OpdsPrice
import com.enve.core.data.util.stringLiteralOrNull
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import javax.inject.Inject
import javax.inject.Singleton

@Entity(
    tableName = "opds_acquisition",
    indices = [Index("bookKey")],
)
data class OpdsAcquisitionEntity(
    @PrimaryKey val rowKey: String,
    val bookKey: String,
    val position: Int,
    val kind: String,
    val href: String,
    val mediaType: String,
    val format: String,
    val drm: String,
    val title: String?,
    val requiresIndirectFetch: Boolean,
    val indirectJson: String,
    val priceCurrency: String?,
    val priceValue: Double?,
    val availabilityState: String?,
    val availabilitySince: String?,
    val availabilityUntil: String?,
    val copiesTotal: Int?,
    val copiesAvailable: Int?,
    val holdsTotal: Int?,
    val holdsPosition: Int?,
    val updatedAt: Long,
)

@Dao
interface OpdsAcquisitionDao {
    @Query("SELECT * FROM opds_acquisition WHERE bookKey = :bookKey ORDER BY position ASC")
    suspend fun forBook(bookKey: String): List<OpdsAcquisitionEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(rows: List<OpdsAcquisitionEntity>)

    @Query("DELETE FROM opds_acquisition WHERE bookKey = :bookKey")
    suspend fun delete(bookKey: String)

    @Transaction
    suspend fun replaceAll(rowsByBookKey: Map<String, List<OpdsAcquisitionEntity>>) {
        rowsByBookKey.forEach { (bookKey, rows) ->
            delete(bookKey)
            if (rows.isNotEmpty()) insert(rows)
        }
    }
}

@Singleton
class OpdsAcquisitionStore @Inject constructor(
    private val dao: OpdsAcquisitionDao,
) {

    suspend fun acquisitions(connectionId: String, bookId: String): List<OpdsAcquisition> =
        dao.forBook(bookKey(connectionId, bookId)).map { it.toAcquisition() }

    suspend fun saveAll(connectionId: String, acquisitionsByBookId: Map<String, List<OpdsAcquisition>>) {
        if (acquisitionsByBookId.isEmpty()) return
        val nowMs = System.currentTimeMillis()
        dao.replaceAll(
            acquisitionsByBookId.entries.associate { (bookId, acquisitions) ->
                val key = bookKey(connectionId, bookId)
                key to acquisitions.mapIndexed { index, it -> it.toEntity(key, index, nowMs) }
            },
        )
    }

    private fun bookKey(connectionId: String, bookId: String): String = "$connectionId:$bookId"
}

internal fun OpdsAcquisition.toEntity(bookKey: String, position: Int, nowMs: Long) = OpdsAcquisitionEntity(
    rowKey = "$bookKey|$position",
    bookKey = bookKey,
    position = position,
    kind = kind.name,
    href = href,
    mediaType = mediaType,
    format = format.name,
    drm = drm.name,
    title = title,
    requiresIndirectFetch = requiresIndirectFetch,
    indirectJson = encodeIndirect(indirect),
    priceCurrency = price?.currency,
    priceValue = price?.value,
    availabilityState = availability?.state,
    availabilitySince = availability?.since,
    availabilityUntil = availability?.until,
    copiesTotal = copies?.total,
    copiesAvailable = copies?.available,
    holdsTotal = holds?.total,
    holdsPosition = holds?.position,
    updatedAt = nowMs,
)

internal fun OpdsAcquisitionEntity.toAcquisition() = OpdsAcquisition(
    kind = enumValueOrNull<OpdsAcquisitionKind>(kind) ?: OpdsAcquisitionKind.GENERIC,
    href = href,
    mediaType = mediaType,
    format = enumValueOrNull<OpdsFormat>(format) ?: OpdsFormat.UNKNOWN,
    drm = enumValueOrNull<OpdsDrm>(drm) ?: OpdsDrm.NONE,
    title = title,
    requiresIndirectFetch = requiresIndirectFetch,
    indirect = decodeIndirect(indirectJson),
    price = priceValue?.let { OpdsPrice(currency = priceCurrency, value = it) },
    availability = availabilityState?.let {
        OpdsAvailability(state = it, since = availabilitySince, until = availabilityUntil)
    },
    copies = if (copiesTotal == null && copiesAvailable == null) null else {
        OpdsCopies(total = copiesTotal, available = copiesAvailable)
    },
    holds = if (holdsTotal == null && holdsPosition == null) null else {
        OpdsHolds(total = holdsTotal, position = holdsPosition)
    },
)

private inline fun <reified T : Enum<T>> enumValueOrNull(name: String): T? =
    enumValues<T>().firstOrNull { it.name == name }

internal fun encodeIndirect(indirect: List<OpdsIndirectAcquisition>): String =
    buildJsonArray {
        indirect.forEach { node ->
            add(
                buildJsonObject {
                    put("type", node.type)
                    if (node.children.isNotEmpty()) {
                        put("children", acquisitionJson.parseToJsonElement(encodeIndirect(node.children)))
                    }
                },
            )
        }
    }.toString()

internal fun decodeIndirect(payload: String): List<OpdsIndirectAcquisition> =
    runCatching {
        (acquisitionJson.parseToJsonElement(payload) as JsonArray).mapNotNull { element ->
            val node = element as? JsonObject ?: return@mapNotNull null
            val type = node["type"].stringLiteralOrNull()
                ?: return@mapNotNull null
            OpdsIndirectAcquisition(
                type = type,
                children = node["children"]?.let { decodeIndirect(it.toString()) }.orEmpty(),
            )
        }
    }.getOrDefault(emptyList())

private val acquisitionJson = Json { ignoreUnknownKeys = true }
