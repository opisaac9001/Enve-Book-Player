package com.enve.core.data.sync

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

object CfiLocatorConverter {

    private const val TAG = "CfiLocatorConverter"

    fun extractCfi(locatorJson: String): String? = runCatching {
        val json = JSONObject(locatorJson)
        val locations = json.optJSONObject("locations") ?: return@runCatching null

        locations.optJSONArray("fragments")?.takeIf { it.length() > 0 }?.let { frags ->
            return@runCatching frags.getString(0)
                .removePrefix("epubcfi(")
                .removeSuffix(")")
                .ifBlank { null }
        }
        locations.optString("progression").ifBlank { null }
    }.onFailure {
        Log.w(TAG, "extractCfi failed", it)
    }.getOrNull()

    fun buildLocatorJson(
        cfi: String,
        selectedText: String? = null,
        chapterTitle: String? = null,
    ): String {
        val normalized = if (cfi.startsWith("epubcfi(")) cfi else "epubcfi($cfi)"
        val locations = JSONObject().put("fragments", JSONArray().put(normalized))
        val text = JSONObject().apply { if (!selectedText.isNullOrEmpty()) put("highlight", selectedText) }
        return JSONObject().apply {
            put("href", "")
            put("type", "application/xhtml+xml")
            put("locations", locations)
            if (text.length() > 0) put("text", text)
            if (!chapterTitle.isNullOrEmpty()) put("title", chapterTitle)
        }.toString()
    }

    fun extractTitle(locatorJson: String): String? = runCatching {
        JSONObject(locatorJson).optString("title").ifBlank { null }
    }.getOrNull()
}
