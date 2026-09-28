package com.enve.bookorbit

import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.reader.EpubBridgeCheckpointCodec
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal fun bookOrbitFoliateCfi(locator: String?): String? =
    EpubBridgeCheckpointCodec.foliateCfi(locator)

internal fun bookOrbitEpubLocator(cfi: String?, percentage: Float): String = buildJsonObject {
    put("href", "")
    put("type", "application/xhtml+xml")
    put("locations", buildJsonObject {
        put("totalProgression", percentage.coerceIn(0f, 1f))
        cfi?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)?.let {
            put("cfi", it)
            put("enveSourceEngine", "foliate")
        }
    })
}.toString()

internal fun bookOrbitEbookSnapshot(
    rawCfi: String?,
    percentagePercent: Double?,
    updatedAt: Long?,
): SyncSnapshot {
    val cfi = rawCfi?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
    val percentage = ((percentagePercent ?: 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
    return SyncSnapshot(
        percentage = percentage,
        locatorJson = cfi?.let { bookOrbitEpubLocator(it, percentage) },
        epubCfi = cfi,
        updatedAt = updatedAt,
        source = BookSource.BOOKORBIT.displayName,
    )
}
