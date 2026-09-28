package com.enve.core.data.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class JsonExtTest {

    private val root: JsonObject = Json.parseToJsonElement(
        """
        {
          "name": "Dune",
          "blank": "  ",
          "missing": null,
          "count": 42,
          "size": 1234.0,
          "ratio": 0.5,
          "flag": true,
          "nested": { "id": "x" },
          "list": [ { "id": "a" }, "skip", { "id": "b" } ]
        }
        """.trimIndent(),
    ).jsonObject

    @Test
    fun stringReadersDistinguishLenientStrictAndNonBlank() {
        assertEquals("Dune", root.optString("name"))
        assertEquals("42", root.optString("count"))
        assertEquals("  ", root.optString("blank"))
        assertNull(root.optNonBlankString("blank"))
        assertNull(root.optString("missing"))
        assertNull(root.optString("nested"))
        assertEquals("Dune", root["name"].stringLiteralOrNull())
        assertNull(root["count"].stringLiteralOrNull())
        assertNull(JsonNull.stringLiteralOrNull())
        assertNull(JsonPrimitive("").nonBlankStringOrNull())
    }

    @Test
    fun numericReadersAcceptWholeDoublesForLongs() {
        assertEquals(42, root.optInt("count"))
        assertEquals(1234L, root.optLong("size"))
        assertEquals(42L, root.optLong("count"))
        assertEquals(0.5, root.optDouble("ratio")!!, 0.0)
        assertNull(root.optLong("name"))
        assertEquals(true, root.optBoolean("flag"))
    }

    @Test
    fun containerReadersNeverThrow() {
        assertEquals("x", root.optObject("nested")?.optString("id"))
        assertNull(root.optObject("name"))
        assertEquals(3, root.optArray("list")?.size)
        assertNull(root["name"]!!.asArrayOrNull())
        assertEquals(listOf("a", "b"), root["list"].objects().map { it.optString("id") })
        assertEquals(listOf("x"), root["nested"].objects().map { it.optString("id") })
        assertEquals(emptyList<JsonObject>(), root["name"].objects())
    }
}
