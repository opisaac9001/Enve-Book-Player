package com.enve.app.data.opds

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsProgressionTransportTest {

    private val document = """
        {
          "modified": "2026-01-28T00:24:00Z",
          "device": { "id": "urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a", "name": "Ebook Reader" },
          "progression": 0.0174920,
          "references": ["#t=40.274", "chapter1.html#par36"]
        }
    """.trimIndent()

    private val problem = """
        {
          "type": "https://registry.opds.io/error#progression-date",
          "title": "A more recent progression point is already available."
        }
    """.trimIndent()

    @Test
    fun a_successful_get_returns_the_progression_document() {
        val response = OpdsProgressionResponses.forGet(200, OPDS_PROGRESSION_MEDIA_TYPE, document)

        assertTrue(response is OpdsProgressionResponse.Document)
        val parsed = (response as OpdsProgressionResponse.Document).document
        assertEquals(40.274, parsed.timeSeconds!!, 1e-6)
        assertEquals("par36", parsed.fragmentId)
    }

    @Test
    fun an_empty_get_payload_means_no_progression_has_been_recorded() {
        assertEquals(OpdsProgressionResponse.Empty, OpdsProgressionResponses.forGet(200, null, null))
        assertEquals(
            OpdsProgressionResponse.Empty,
            OpdsProgressionResponses.forGet(200, OPDS_PROGRESSION_MEDIA_TYPE, "   "),
        )
    }

    @Test
    fun a_malformed_success_payload_is_a_failure_rather_than_a_silent_empty() {
        assertEquals(
            OpdsProgressionResponse.Failure(200, null),
            OpdsProgressionResponses.forGet(200, null, """{"progression":0.5}"""),
        )
    }

    @Test
    fun unauthorized_is_distinguished_from_other_errors() {
        assertEquals(OpdsProgressionResponse.Unauthorized, OpdsProgressionResponses.forGet(401, null, "{}"))
        assertEquals(OpdsProgressionResponse.Unauthorized, OpdsProgressionResponses.forPut(401, null, "{}"))
    }

    @Test
    fun problem_details_are_surfaced_for_failures() {
        val invalidPayload = """
            {
              "type": "https://registry.opds.io/error#progression-invalid-payload",
              "title": "Progression could not be updated due to an invalid payload."
            }
        """.trimIndent()

        val response = OpdsProgressionResponses.forPut(400, "application/problem+json", invalidPayload)

        assertEquals(
            OpdsProgressionResponse.Failure(
                400,
                OpdsProblemDetails(
                    "https://registry.opds.io/error#progression-invalid-payload",
                    "Progression could not be updated due to an invalid payload.",
                ),
            ),
            response,
        )
        assertEquals(
            OpdsProgressionResponse.Failure(403, null),
            OpdsProgressionResponses.forPut(403, "text/html", "<html>nope</html>"),
        )
    }

    @Test
    fun put_accepts_200_and_201_and_reports_409_as_a_conflict() {
        assertTrue(
            OpdsProgressionResponses.forPut(200, OPDS_PROGRESSION_MEDIA_TYPE, document)
                is OpdsProgressionResponse.Document,
        )
        assertTrue(
            OpdsProgressionResponses.forPut(201, OPDS_PROGRESSION_MEDIA_TYPE, document)
                is OpdsProgressionResponse.Document,
        )

        val conflict = OpdsProgressionResponses.forPut(409, "application/problem+json", problem)
        assertEquals(
            OpdsProgressionResponse.Conflict(
                OpdsProblemDetails(
                    "https://registry.opds.io/error#progression-date",
                    "A more recent progression point is already available.",
                ),
            ),
            conflict,
        )
    }

    @Test
    fun a_put_that_answers_without_a_progression_document_is_a_failure() {
        assertEquals(OpdsProgressionResponse.Failure(200, null), OpdsProgressionResponses.forPut(200, null, ""))
        assertEquals(OpdsProgressionResponse.Failure(201, null), OpdsProgressionResponses.forPut(201, null, null))
        assertEquals(
            OpdsProgressionResponse.Failure(201, null),
            OpdsProgressionResponses.forPut(201, OPDS_PROGRESSION_MEDIA_TYPE, "   "),
        )
        assertEquals(
            OpdsProgressionResponse.Failure(200, null),
            OpdsProgressionResponses.forPut(200, OPDS_PROGRESSION_MEDIA_TYPE, """{"progression":0.5}"""),
        )
    }

    @Test
    fun a_declared_content_type_must_agree_with_the_progression_media_type() {
        assertTrue(
            OpdsProgressionResponses.forGet(200, "application/opds-progression+json; charset=utf-8", document)
                is OpdsProgressionResponse.Document,
        )
        assertTrue(
            OpdsProgressionResponses.forGet(200, "APPLICATION/OPDS-PROGRESSION+JSON", document)
                is OpdsProgressionResponse.Document,
        )
        assertTrue(OpdsProgressionResponses.forGet(200, null, document) is OpdsProgressionResponse.Document)
        assertTrue(OpdsProgressionResponses.forGet(200, "  ", document) is OpdsProgressionResponse.Document)

        assertEquals(
            OpdsProgressionResponse.Failure(200, null),
            OpdsProgressionResponses.forGet(200, "application/json", document),
        )
        assertEquals(
            OpdsProgressionResponse.Failure(201, null),
            OpdsProgressionResponses.forPut(201, "text/plain", document),
        )
        assertEquals(
            OpdsProgressionResponse.Empty,
            OpdsProgressionResponses.forGet(200, "text/plain", null),
        )
    }

    @Test
    fun a_conflict_on_get_is_not_treated_as_a_conflict() {
        assertEquals(
            OpdsProgressionResponse.Failure(
                409,
                OpdsProblemDetails(
                    "https://registry.opds.io/error#progression-date",
                    "A more recent progression point is already available.",
                ),
            ),
            OpdsProgressionResponses.forGet(409, "application/problem+json", problem),
        )
    }
}
