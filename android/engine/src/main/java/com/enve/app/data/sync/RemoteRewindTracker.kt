package com.enve.app.data.sync

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.abs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray

private const val EQUAL_EPSILON = 0.005f
private const val ADVANCE_EPSILON = 0.005f
private const val NEAR_ZERO_PERCENTAGE = 0.01f
private const val POSITION_ECHO_TOLERANCE_MS = 2_000L
private const val CLOCK_SKEW_MS = 60_000L
private const val WRITE_RETENTION_MS = 30 * 60 * 1000L
private const val MAX_WRITES_PER_BOOK = 4
private const val MAX_TRACKED_KEYS = 128
private const val MIN_HIGHLIGHT_ANCHOR = 8

private fun domainKeyOf(mediaType: AppMediaType): String =
    if (mediaType == AppMediaType.EBOOK) "ebook" else "audiobook"

data class RemoteProgressWriteKey(
    val bookId: String,
    val domainKey: String,
    val connectionId: String,
) {
    companion object {
        fun of(book: Book): RemoteProgressWriteKey = RemoteProgressWriteKey(
            bookId = book.id,
            domainKey = domainKeyOf(book.mediaType),
            connectionId = book.connectionId ?: book.source.name,
        )
    }
}

data class RemoteProgressScope(
    val bookId: String,
    val domainKey: String,
    val connectionId: String,
    val source: String,
) {
    val writeKey: RemoteProgressWriteKey
        get() = RemoteProgressWriteKey(bookId, domainKey, connectionId)

    companion object {
        fun of(book: Book, source: String): RemoteProgressScope {
            val key = RemoteProgressWriteKey.of(book)
            return RemoteProgressScope(
                bookId = key.bookId,
                domainKey = key.domainKey,
                connectionId = key.connectionId,
                source = source,
            )
        }
    }
}

data class RemoteProgressObservation(
    val percentage: Float,
    val positionMs: Long? = null,
    val locatorJson: String? = null,
    val observedAt: Long? = null,
)

enum class RemoteRewindVerdict { NOT_REWIND, ECHO, DISMISSED, UNCONFIRMED, CONFIRMED }

@Singleton
class RemoteRewindTracker @Inject constructor() {

    private class ScopeState {
        var candidate: RemoteProgressObservation? = null
        var confirmed: RemoteProgressObservation? = null
        var userKeptLocal = false
        var touchedAt = 0L
    }

    private class OutboundWrite(
        val percentage: Float,
        val positionMs: Long?,
        val locatorJson: String?,
        val writtenAt: Long,
    )

    private class WriteLedger {
        val writes = ArrayDeque<OutboundWrite>()
        var touchedAt = 0L
    }

    private val lock = Any()
    private val scopes = HashMap<RemoteProgressScope, ScopeState>()
    private val ledgers = HashMap<RemoteProgressWriteKey, WriteLedger>()

    fun assess(
        scope: RemoteProgressScope,
        observation: RemoteProgressObservation,
        localPercentage: Float,
        nowMs: Long = System.currentTimeMillis(),
    ): RemoteRewindVerdict = synchronized(lock) {
        val state = scopes.getOrPut(scope) { ScopeState() }
        state.touchedAt = nowMs
        evict(scopes) { it.touchedAt }

        if (isEcho(scope.writeKey, observation, nowMs)) return@synchronized RemoteRewindVerdict.ECHO

        if (observation.percentage >= localPercentage - EQUAL_EPSILON) {
            state.candidate = null
            state.confirmed = null
            state.userKeptLocal = false
            return@synchronized RemoteRewindVerdict.NOT_REWIND
        }

        if (observation == state.confirmed) return@synchronized RemoteRewindVerdict.CONFIRMED

        if (state.userKeptLocal) return@synchronized RemoteRewindVerdict.DISMISSED

        val observedAt = observation.observedAt ?: return@synchronized RemoteRewindVerdict.UNCONFIRMED

        val candidate = state.candidate
        val candidateAt = candidate?.observedAt
        if (candidate != null && candidateAt != null &&
            observedAt > candidateAt &&
            candidate.percentage > NEAR_ZERO_PERCENTAGE &&
            hasPrecisePosition(candidate) &&
            observation.percentage > candidate.percentage + ADVANCE_EPSILON &&
            observation.percentage > NEAR_ZERO_PERCENTAGE &&
            hasPrecisePosition(observation)
        ) {
            state.candidate = null
            state.confirmed = observation
            return@synchronized RemoteRewindVerdict.CONFIRMED
        }

        if (candidateAt == null || (observedAt > candidateAt && observation.percentage < candidate.percentage)) {
            state.candidate = observation
        }
        RemoteRewindVerdict.UNCONFIRMED
    }

    fun recordOutboundWrite(
        key: RemoteProgressWriteKey,
        percentage: Float,
        positionMs: Long?,
        locatorJson: String?,
        atMs: Long = System.currentTimeMillis(),
    ) = synchronized(lock) {
        val ledger = ledgers.getOrPut(key) { WriteLedger() }
        ledger.writes.removeAll { atMs - it.writtenAt > WRITE_RETENTION_MS }
        ledger.writes.addLast(OutboundWrite(percentage, positionMs, locatorJson, atMs))
        while (ledger.writes.size > MAX_WRITES_PER_BOOK) ledger.writes.removeFirst()
        ledger.touchedAt = atMs
        evict(ledgers) { it.touchedAt }
    }

    fun recordUserResolution(
        scope: RemoteProgressScope,
        acceptedRemote: Boolean,
        nowMs: Long = System.currentTimeMillis(),
    ) = synchronized(lock) {
        val state = scopes.getOrPut(scope) { ScopeState() }
        state.candidate = null
        state.confirmed = null
        state.userKeptLocal = !acceptedRemote
        state.touchedAt = nowMs
        evict(scopes) { it.touchedAt }
    }

    private fun <K, V> evict(storage: HashMap<K, V>, age: (V) -> Long) {
        if (storage.size <= MAX_TRACKED_KEYS) return
        storage.entries
            .sortedBy { age(it.value) }
            .take(storage.size - MAX_TRACKED_KEYS)
            .map { it.key }
            .forEach { storage.remove(it) }
    }

    private fun isEcho(
        key: RemoteProgressWriteKey,
        observation: RemoteProgressObservation,
        nowMs: Long,
    ): Boolean {
        val ledger = ledgers[key] ?: return false
        return ledger.writes.any { write ->
            val elapsed = (observation.observedAt ?: nowMs) - write.writtenAt
            if (elapsed < -CLOCK_SKEW_MS || elapsed > WRITE_RETENTION_MS) return@any false

            val remoteLocator = observation.locatorJson
            val ourLocator = write.locatorJson
            if (!remoteLocator.isNullOrBlank() && !ourLocator.isNullOrBlank()) {
                return@any remoteLocator == ourLocator
            }
            val remotePosition = observation.positionMs
            val ourPosition = write.positionMs
            if (remotePosition != null && ourPosition != null && remotePosition > 0L && ourPosition > 0L) {
                return@any abs(remotePosition - ourPosition) <= POSITION_ECHO_TOLERANCE_MS
            }
            abs(observation.percentage - write.percentage) <= EQUAL_EPSILON
        }
    }

    private fun hasPrecisePosition(observation: RemoteProgressObservation): Boolean {
        if ((observation.positionMs ?: 0L) > 0L) return true
        return isPreciseLocator(observation.locatorJson)
    }

    private fun isPreciseLocator(locatorJson: String?): Boolean {
        if (locatorJson.isNullOrBlank()) return false
        return try {
            val json = Json.parseToJsonElement(locatorJson).jsonObject
            val highlight = (json["text"] as? JsonObject)?.get("highlight")?.jsonPrimitive?.contentOrNull.orEmpty().trim()
            if (highlight.length >= MIN_HIGHLIGHT_ANCHOR) return true
            val locations = json["locations"] as? JsonObject ?: return false
            val cfi = locations["cfi"]?.jsonPrimitive?.contentOrNull
            if (cfi?.startsWith("epubcfi(") == true && cfi.endsWith(")") && cfi.contains('!')) return true
            val fragments = locations["fragments"] as? JsonArray
            if (fragments?.any {
                    val value = it.jsonPrimitive.contentOrNull.orEmpty()
                    value.startsWith("epubcfi(") && value.endsWith(")") && value.contains('!')
                } == true) return true
            val range = locations["domRange"] as? JsonObject
            val start = range?.get("start") as? JsonObject
            start?.get("cssSelector")?.jsonPrimitive?.contentOrNull?.isNotBlank() == true
        } catch (_: Exception) {
            false
        }
    }
}
