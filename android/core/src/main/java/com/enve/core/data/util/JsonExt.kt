package com.enve.core.data.util

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

fun JsonElement.asObjectOrNull(): JsonObject? = runCatching { jsonObject }.getOrNull()
fun JsonElement.asArrayOrNull(): JsonArray? = runCatching { jsonArray }.getOrNull()
fun JsonElement?.stringOrNull(): String? = (this as? JsonPrimitive)?.contentOrNull
fun JsonElement?.nonBlankStringOrNull(): String? = stringOrNull()?.takeIf { it.isNotBlank() }
fun JsonElement?.stringLiteralOrNull(): String? = (this as? JsonPrimitive)?.takeIf { it.isString }?.content
fun JsonElement?.objects(): List<JsonObject> = when (this) {
    is JsonArray -> mapNotNull { it as? JsonObject }
    is JsonObject -> listOf(this)
    else -> emptyList()
}

fun JsonObject.optElement(key: String): JsonElement? = this[key]?.takeUnless { it is JsonNull }
fun JsonObject.optObject(key: String): JsonObject? = optElement(key)?.asObjectOrNull()
fun JsonObject.optArray(key: String): JsonArray? = optElement(key)?.asArrayOrNull()
fun JsonObject.optString(key: String): String? = this[key].stringOrNull()
fun JsonObject.optNonBlankString(key: String): String? = this[key].nonBlankStringOrNull()
fun JsonObject.optInt(key: String): Int? = runCatching { optElement(key)?.jsonPrimitive?.intOrNull }.getOrNull()
fun JsonObject.optLong(key: String): Long? = runCatching {
    optElement(key)?.jsonPrimitive?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }
}.getOrNull()
fun JsonObject.optDouble(key: String): Double? = runCatching { optElement(key)?.jsonPrimitive?.doubleOrNull }.getOrNull()
fun JsonObject.optBoolean(key: String): Boolean? = runCatching { optElement(key)?.jsonPrimitive?.booleanOrNull }.getOrNull()
fun JsonObject.optFloat(key: String): Float? = runCatching {
    optElement(key)?.jsonPrimitive?.floatOrNull
        ?: optElement(key)?.jsonPrimitive?.doubleOrNull?.toFloat()
}.getOrNull()
