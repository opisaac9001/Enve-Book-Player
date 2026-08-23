package com.enve.core.data.util

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
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
fun JsonObject.optElement(key: String): JsonElement? = this[key]?.takeUnless { it is JsonNull }
fun JsonObject.optObject(key: String): JsonObject? = optElement(key)?.asObjectOrNull()
fun JsonObject.optArray(key: String): JsonArray? = runCatching { optElement(key)?.jsonArray }.getOrNull()
fun JsonObject.optString(key: String): String? = runCatching { optElement(key)?.jsonPrimitive?.contentOrNull }.getOrNull()
fun JsonObject.optInt(key: String): Int? = runCatching { optElement(key)?.jsonPrimitive?.intOrNull }.getOrNull()
fun JsonObject.optLong(key: String): Long? = runCatching { optElement(key)?.jsonPrimitive?.longOrNull }.getOrNull()
fun JsonObject.optBoolean(key: String): Boolean? = runCatching { optElement(key)?.jsonPrimitive?.booleanOrNull }.getOrNull()
fun JsonObject.optFloat(key: String): Float? = runCatching {
    optElement(key)?.jsonPrimitive?.floatOrNull
        ?: optElement(key)?.jsonPrimitive?.doubleOrNull?.toFloat()
}.getOrNull()
