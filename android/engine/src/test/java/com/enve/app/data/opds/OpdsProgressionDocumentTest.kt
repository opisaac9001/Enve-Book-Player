package com.enve.app.data.opds

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.OffsetDateTime

class OpdsProgressionDocumentTest {

    @Test
    fun reads_a_reflowable_epub_progression() {
        val document = OpdsProgressionCodec.decode(
            """
            {
              "title": "Chapter 1 - A New Dawn",
              "modified": "2026-01-27T11:00:00Z",
              "device": {
                "id": "urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a",
                "name": "Ebook Reader (Pixel 10 Pro)"
              },
              "progression": 0.0174920,
              "references": ["chapter1.html#:~:text=It%20was%20expected"]
            }
            """.trimIndent(),
        )

        assertNotNull(document)
        requireNotNull(document)
        assertEquals("Chapter 1 - A New Dawn", document.title)
        assertEquals("2026-01-27T11:00:00Z", document.modified)
        assertEquals(
            OffsetDateTime.parse("2026-01-27T11:00:00Z").toInstant().toEpochMilli(),
            document.modifiedAtMs,
        )
        assertEquals("urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a", document.device.id)
        assertEquals("Ebook Reader (Pixel 10 Pro)", document.device.name)
        assertEquals(0.0174920, document.progression, 1e-9)
        assertEquals("chapter1.html", document.resourcePath)
        assertEquals("It was expected", document.textQuote)
    }

    @Test
    fun reads_an_audiobook_media_fragment() {
        val document = OpdsProgressionCodec.decode(
            """
            {
              "title": "Part 4",
              "modified": "2025-12-25T12:00:00Z",
              "device": { "id": "urn:uuid:019c0049-6e8c-745c-adb1-5b03f8ad50c4", "name": "Audiobook Player" },
              "progression": 0.72370325,
              "references": ["#t=849.250"]
            }
            """.trimIndent(),
        )

        requireNotNull(document)
        assertEquals(849.250, document.timeSeconds!!, 1e-6)
        assertNull(document.resourcePath)
    }

    @Test
    fun rejects_documents_that_break_the_schema() {
        val valid = """
            {
              "modified": "2026-01-28T19:00:00Z",
              "device": { "id": "https://reader.example.com", "name": "Web Reader" },
              "progression": 0.048204
            }
        """.trimIndent()
        assertNotNull(OpdsProgressionCodec.decode(valid))

        assertNull(OpdsProgressionCodec.decode(null))
        assertNull(OpdsProgressionCodec.decode(""))
        assertNull(OpdsProgressionCodec.decode(valid.replace("\"progression\": 0.048204", "\"progression\": 1.5")))
        assertNull(OpdsProgressionCodec.decode(valid.replace("0.048204", "\"0.048204\"")))
        assertNull(OpdsProgressionCodec.decode(valid.replace("2026-01-28T19:00:00Z", "2026-01-28")))
        assertNull(OpdsProgressionCodec.decode(valid.replace("\"name\": \"Web Reader\"", "\"name\": \"\"")))
        assertNull(OpdsProgressionCodec.decode(valid.replace("\"id\": \"https://reader.example.com\",", "")))
        assertNull(
            OpdsProgressionCodec.decode(
                valid.dropLast(1) + ", \"references\": \"chapter1.html\" }",
            ),
        )
        assertNull(OpdsProgressionCodec.decode(valid.dropLast(1) + ", \"references\": [7] }"))
    }

    @Test
    fun requires_a_device_id_that_is_a_uri() {
        assertNotNull(OpdsProgressionCodec.decode(withDeviceId("urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a")))
        assertNotNull(OpdsProgressionCodec.decode(withDeviceId("https://reader.example.com/devices/7")))

        assertNull(OpdsProgressionCodec.decode(withDeviceId("Ebook Reader")))
        assertNull(OpdsProgressionCodec.decode(withDeviceId("/devices/7")))
        assertNull(OpdsProgressionCodec.decode(withDeviceId("urn:uuid:019c0047 cc8d")))
        assertNull(OpdsProgressionCodec.decode(withDeviceId("urn:uuid:019c0047\\tcc8d")))
        assertNull(OpdsProgressionCodec.decode(withDeviceId("https://reader.example.com/%zz")))
        assertNull(OpdsProgressionCodec.decode(withDeviceId("https://reader.example.com/%4")))
        assertNull(OpdsProgressionCodec.decode(withDeviceId("")))
    }

    @Test
    fun requires_every_reference_to_be_a_uri_reference() {
        assertNotNull(OpdsProgressionCodec.decode(withReferences("chapter1.html")))
        assertNotNull(OpdsProgressionCodec.decode(withReferences("#page=87")))
        assertNotNull(OpdsProgressionCodec.decode(withReferences("../part2/chapter1.html#par36")))
        assertNotNull(OpdsProgressionCodec.decode(withReferences("chapter1.html#:~:text=It%20was%20expected")))

        assertNull(OpdsProgressionCodec.decode(withReferences("chapter 1.html")))
        assertNull(OpdsProgressionCodec.decode(withReferences("chapter1.html#par\\u000136")))
        assertNull(OpdsProgressionCodec.decode(withReferences("chapter1.html#:~:text=It%2Gwas")))
        assertNull(OpdsProgressionCodec.decode(withReferences("chapter1.html#par36", "not a reference")))
        assertNull(OpdsProgressionCodec.decode(withReferences("")))
    }

    @Test
    fun round_trips_unknown_references_and_unknown_members() {
        val payload = """
            {
              "modified": "2026-02-05T14:24:00Z",
              "device": { "id": "urn:uuid:019c2df6-90f8-7096-b162-a0e69cd52844", "name": "Comics Reader" },
              "progression": 0.4999,
              "references": ["#t=5", "#xywh=160,120,320,240", "page78.jxl"],
              "vendorState": { "shelf": "later" }
            }
        """.trimIndent()

        val document = OpdsProgressionCodec.decode(payload)
        requireNotNull(document)
        assertEquals(
            listOf("#t=5", "#xywh=160,120,320,240", "page78.jxl"),
            document.references.map { it.raw },
        )
        assertTrue(document.references[1].target is OpdsProgressionTarget.Unknown)

        val encoded = OpdsProgressionCodec.encode(document)
        assertTrue(encoded.contains("\"vendorState\":{\"shelf\":\"later\"}"))
        assertEquals(document, OpdsProgressionCodec.decode(encoded))
    }

    @Test
    fun builds_documents_with_an_iso_8601_utc_timestamp() {
        val document = OpdsProgressionDocument.at(
            modifiedAtMs = OffsetDateTime.parse("2026-01-27T11:00:00Z").toInstant().toEpochMilli(),
            device = OpdsProgressionDevice("urn:uuid:0000", "Enve"),
            progression = 1.4,
            references = listOf(OpdsProgressionReferences.time(67.0)),
        )

        assertEquals("2026-01-27T11:00:00Z", document.modified)
        assertEquals(1.0, document.progression, 1e-9)
        assertEquals(
            """{"modified":"2026-01-27T11:00:00Z","device":{"id":"urn:uuid:0000","name":"Enve"},"progression":1.0,"references":["#t=67"]}""",
            OpdsProgressionCodec.encode(document),
        )
    }

    @Test
    fun a_freshly_built_document_re_emits_the_members_the_server_owns() {
        val stored = OpdsProgressionCodec.decode(
            """
            {
              "modified": "2026-02-05T14:24:00Z",
              "device": { "id": "urn:uuid:019c2df6-90f8-7096-b162-a0e69cd52844", "name": "Comics Reader" },
              "progression": 0.5,
              "vendorState": { "shelf": "later" }
            }
            """.trimIndent(),
        )!!

        val pushed = OpdsProgressionDocument.at(
            modifiedAtMs = OffsetDateTime.parse("2026-01-27T11:00:00Z").toInstant().toEpochMilli(),
            device = OpdsProgressionDevice("urn:uuid:0000", "Enve"),
            progression = 0.75,
            references = listOf(OpdsProgressionReferences.time(67.0)),
            additionalMembers = stored.additionalMembers,
        )

        assertEquals(
            """{"modified":"2026-01-27T11:00:00Z","device":{"id":"urn:uuid:0000","name":"Enve"},""" +
                """"progression":0.75,"references":["#t=67"],"vendorState":{"shelf":"later"}}""",
            OpdsProgressionCodec.encode(pushed),
        )
    }

    @Test
    fun reads_problem_details_and_requires_type_and_title() {
        val problem = OpdsProgressionCodec.decodeProblem(
            """
            {
              "type": "https://registry.opds.io/error#progression-date",
              "title": "A more recent progression point is already available."
            }
            """.trimIndent(),
        )

        assertEquals("https://registry.opds.io/error#progression-date", problem?.type)
        assertEquals("A more recent progression point is already available.", problem?.title)
        assertNull(OpdsProgressionCodec.decodeProblem("""{"type":"https://registry.opds.io/error#progression-date"}"""))
        assertNull(OpdsProgressionCodec.decodeProblem("not json"))
    }

    private fun withDeviceId(id: String): String = """
        {
          "modified": "2026-01-28T19:00:00Z",
          "device": { "id": "$id", "name": "Web Reader" },
          "progression": 0.048204
        }
    """.trimIndent()

    private fun withReferences(vararg references: String): String = """
        {
          "modified": "2026-01-28T19:00:00Z",
          "device": { "id": "urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a", "name": "Web Reader" },
          "progression": 0.048204,
          "references": [${references.joinToString(", ") { "\"$it\"" }}]
        }
    """.trimIndent()
}
