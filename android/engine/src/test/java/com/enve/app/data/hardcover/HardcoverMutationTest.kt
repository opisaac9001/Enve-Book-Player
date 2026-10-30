package com.enve.app.data.hardcover

import com.enve.core.data.util.optInt
import com.enve.core.data.util.optObject
import com.enve.core.data.util.optString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class HardcoverMutationTest {
    private fun obj(text: String) = Json.parseToJsonElement(text).jsonObject

    @Test fun bearerPrefixIsStrippedFromPastedTokens() {
        assertEquals("abc.def", normalizedHardcoverToken("  Bearer   abc.def \n"))
        assertEquals("abc.def", normalizedHardcoverToken("bearer abc.def"))
        assertEquals("abc.def", normalizedHardcoverToken("abc.def"))
    }

    @Test fun nestedMutationErrorsSurface() {
        val userBookError = assertThrows(HardcoverException::class.java) {
            hardcoverMutationResult(obj("""{"insert_user_book":{"id":null,"error":"Book already in library"}}"""), "insert_user_book")
        }
        assertEquals("Book already in library", userBookError.message)

        val goalErrors = assertThrows(HardcoverException::class.java) {
            hardcoverMutationResult(obj("""{"update_goal":{"id":null,"errors":["goal must be positive","bad dates"]}}"""), "update_goal")
        }
        assertEquals("goal must be positive; bad dates", goalErrors.message)

        assertEquals(7, hardcoverMutationResult(obj("""{"update_goal":{"id":7,"errors":[]}}"""), "update_goal").optInt("id"))
    }

    @Test fun nullMutationIdentityCannotReportSuccess() {
        assertThrows(HardcoverException::class.java) {
            hardcoverMutationResult(obj("""{"update_user_book":{"id":null,"error":null}}"""), "update_user_book")
        }
    }

    @Test fun finishedReadDisplaysCompleteWithoutEditionCounts() {
        assertEquals(1f, hardcoverReadProgress(obj("""{"finished_at":"2026-10-27"}"""), null), 0f)
    }

    @Test fun goalUpdatePreservesMetadataConditionsAndPrivacy() {
        val existing = obj(
            """{"id":3,"goal":30,"metric":"book","description":"Reading more","start_date":"2026-01-01","end_date":"2026-12-31",
                "privacy_setting_id":2,"archived":false,"conditions":{"readingFormatId":2},"progress":"12"}""",
        )
        val input = hardcoverGoalInput(existing, target = 40, year = 2026)

        assertEquals(40, input.optInt("goal"))
        assertEquals("book", input.optString("metric"))
        assertEquals("Reading more", input.optString("description"))
        assertEquals("2026-01-01", input.optString("start_date"))
        assertEquals("2026-12-31", input.optString("end_date"))
        assertEquals(2, input.optInt("privacy_setting_id"))
        assertEquals(2, input.optObject("conditions")?.optInt("readingFormatId"))
    }

    @Test fun newGoalSendsRequiredEmptyConditions() {
        val input = hardcoverGoalInput(null, target = 25, year = 2026)
        assertEquals(emptyMap<String, Any>(), input.optObject("conditions"))
        assertEquals("2026 Reading Goal", input.optString("description"))
        assertNull(input.optInt("privacy_setting_id"))
    }

    @Test fun unknownGoalConditionsBlockUpdateInsteadOfBeingDropped() {
        val existing = obj("""{"id":3,"goal":30,"metric":"book","conditions":{"mysteryFilter":1}}""")
        assertThrows(HardcoverException::class.java) { hardcoverGoalInput(existing, 40, 2026) }
    }

    @Test fun onlyActiveCalendarYearBookGoalIsSelected() {
        val goals = Json.parseToJsonElement(
            """[
                {"id":1,"metric":"hour","archived":false,"start_date":"2026-01-01","end_date":"2026-12-31"},
                {"id":2,"metric":"book","archived":true,"start_date":"2026-01-01","end_date":"2026-12-31"},
                {"id":3,"metric":"book","archived":false,"start_date":"2026-03-01","end_date":"2026-12-31"},
                {"id":4,"metric":"book","archived":false,"start_date":"2026-01-01","end_date":"2026-12-31"}
            ]""",
        ) as JsonArray
        assertEquals(4, hardcoverAnnualBookGoal(goals, 2026)?.optInt("id"))
        assertNull(hardcoverAnnualBookGoal(goals, 2025))
    }

    @Test fun libraryProgressUsesAudioSecondsWhenPresent() {
        val read = obj("""{"progress_pages":null,"progress_seconds":900,"edition":{"pages":null,"audio_seconds":3600}}""")
        assertEquals(0.25f, hardcoverReadProgress(read, null), 0.0001f)
        val pagesRead = obj("""{"progress_pages":50,"progress_seconds":null}""")
        assertEquals(0.5f, hardcoverReadProgress(pagesRead, obj("""{"pages":100}""")), 0.0001f)
    }
}
