package com.enve.app.data.sync

import org.json.JSONException
import org.json.JSONObject

object KOReaderXPointerConverter {

    fun locatorJson(forXpointer: String, percentage: Float): String? {
        if (forXpointer.isBlank()) return null
        return try {

            val cfi = xpointerToCfi(forXpointer) ?: return null
            val json = JSONObject().apply {
                put("href", "")
                put("type", "application/epub+zip")
                val locations = JSONObject().apply {
                    put("cfi", cfi)
                    put("progression", percentage)
                }
                put("locations", locations)
            }
            json.toString()
        } catch (_: JSONException) {
            null
        }
    }

    fun xpointer(forLocatorJson: String): String? {
        if (forLocatorJson.isBlank()) return null
        return try {
            val json = JSONObject(forLocatorJson)
            val cfi = json.optJSONObject("locations")?.optString("cfi")
                ?: json.optString("cfi")
            if (cfi.isNullOrBlank()) return null
            cfiToXpointer(cfi)
        } catch (_: JSONException) {
            null
        }
    }

    private fun xpointerToCfi(xpointer: String): String? {

        val clean = xpointer.trim()
        if (clean.isEmpty()) return null

        val docFragmentRegex = Regex("""/DocFragment\[(\d+)\]""")
        val docFragmentIndex = docFragmentRegex.find(clean)?.groupValues?.getOrNull(1)?.toIntOrNull()
            ?: 1

        val offsetRegex = Regex("""\.(\d+)$""")
        val offset = offsetRegex.find(clean)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 0

        val paraRegex = Regex("""/p\[(\d+)\]""")
        val paraIndex = paraRegex.find(clean)?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 1

        val spineStep = docFragmentIndex * 2
        return "epubcfi(/$spineStep!/4/${paraIndex * 2}/1:$offset)"
    }

    private fun cfiToXpointer(cfi: String): String? {
        if (cfi.isBlank()) return null

        val inner = cfi.trim().removePrefix("epubcfi(").removeSuffix(")")
        if (inner.isBlank()) return null

        val parts = inner.split("!")
        if (parts.size < 2) return null

        val spineStep = parts[0].removePrefix("/").toIntOrNull() ?: return null
        val docFragmentIndex = spineStep / 2

        val bodyPart = parts.getOrNull(1) ?: return null
        val bodySteps = bodyPart.split("/").filter { it.isNotBlank() }

        val paraStep = bodySteps.getOrNull(1)?.toIntOrNull() ?: 2
        val paraIndex = paraStep / 2

        val offsetPart = bodySteps.lastOrNull() ?: "1:0"
        val offset = offsetPart.substringAfter(":").toIntOrNull() ?: 0

        return "/body/DocFragment[$docFragmentIndex]/body/p[$paraIndex]/text()[1].$offset"
    }
}
