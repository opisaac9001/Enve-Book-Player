package com.enve.app.data.sync

import com.enve.core.data.sync.SyncSnapshot
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

object ProgressResolutionPolicy {
    enum class Decision { NONE, PULL, PUSH, CONFLICT }

    private const val ZERO_EPSILON = 0.001f
    private const val EQUAL_TOLERANCE = 0.005f
    private const val SKEW_MS = 1_000L

    fun resolve(
        localPercentage: Float,
        localUpdatedAt: Long?,
        remote: SyncSnapshot,
        localLocatorJson: String? = null,
    ): Decision {
        val localPct = localPercentage.coerceIn(0f, 1f)
        val remotePct = remote.percentage.coerceIn(0f, 1f)

        if (localPct <= ZERO_EPSILON && remotePct <= ZERO_EPSILON) return Decision.NONE
        if (localPct <= ZERO_EPSILON) return Decision.PULL
        if (remotePct <= ZERO_EPSILON) return Decision.PUSH
        if (kotlin.math.abs(remotePct - localPct) < EQUAL_TOLERANCE) {
            return sentenceDecision(localLocatorJson, localUpdatedAt, remote) ?: Decision.NONE
        }

        val remoteUpdatedAt = remote.updatedAt
        if (remoteUpdatedAt == null || localUpdatedAt == null) {
            return if (remotePct > localPct) Decision.PULL else Decision.PUSH
        }

        val localIsNewer = localUpdatedAt > remoteUpdatedAt + SKEW_MS
        val remoteIsNewer = remoteUpdatedAt > localUpdatedAt + SKEW_MS

        if (remoteIsNewer && remotePct >= localPct) return Decision.PULL
        if (localIsNewer && localPct >= remotePct) return Decision.PUSH

        if (remoteIsNewer || localIsNewer) return Decision.CONFLICT

        return if (remotePct > localPct) Decision.PULL else Decision.PUSH
    }

    private fun sentenceDecision(localLocatorJson: String?, localUpdatedAt: Long?, remote: SyncSnapshot): Decision? {
        val localSentence = narratedSentence(localLocatorJson)
        val remoteSentence = narratedSentence(remote.locatorJson)
        val remoteUpdatedAt = remote.updatedAt
        if (localSentence == remoteSentence || localUpdatedAt == null || remoteUpdatedAt == null) return null
        return when {
            remoteSentence != null && remoteUpdatedAt > localUpdatedAt + SKEW_MS -> Decision.PULL
            localSentence != null && localUpdatedAt > remoteUpdatedAt + SKEW_MS -> Decision.PUSH
            else -> null
        }
    }

    private val json = Json { ignoreUnknownKeys = true }

    internal fun narratedSentence(locatorJson: String?): String? {
        val root = locatorJson?.trim()?.takeIf { it.startsWith("{") }
            ?.let { runCatching { json.parseToJsonElement(it).jsonObject }.getOrNull() } ?: return null
        val href = root["href"]?.jsonPrimitive?.contentOrNull?.substringBefore('#') ?: return null
        val locations = root["locations"] as? JsonObject
        val fragment = (locations?.get("fragments") as? JsonArray)
            ?.mapNotNull { it.jsonPrimitive.contentOrNull }
            ?.firstOrNull { !it.startsWith("t=") && !it.startsWith("epubcfi(") }
        if (fragment != null) return "$href#$fragment"
        val domRange = (locations?.get("domRange") ?: root["domRange"]) as? JsonObject
        val selector = (domRange?.get("start") as? JsonObject)?.get("cssSelector")?.jsonPrimitive?.contentOrNull
        return selector
            ?.takeIf { it.length > 1 && it.startsWith("#") && it.drop(1).none { c -> c in " >.:[" } }
            ?.let { "$href$it" }
    }

    fun bestSnapshot(snapshots: List<SyncSnapshot>): SyncSnapshot? {
        if (snapshots.isEmpty()) return null
        val timestamped = snapshots.filter { it.updatedAt != null }
        return if (timestamped.isNotEmpty()) {
            timestamped.maxWithOrNull(compareBy<SyncSnapshot> { it.updatedAt!! }.thenBy { it.percentage })
        } else {
            snapshots.maxByOrNull { it.percentage }
        }
    }
}
