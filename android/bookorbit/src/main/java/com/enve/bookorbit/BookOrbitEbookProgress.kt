package com.enve.bookorbit

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
