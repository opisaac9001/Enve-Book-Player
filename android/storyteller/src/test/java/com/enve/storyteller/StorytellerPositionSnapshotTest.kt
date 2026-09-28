package com.enve.storyteller

import com.enve.core.data.sync.AudioLocatorPosition
import com.enve.storyteller.dto.StorytellerPositionResponse
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StorytellerPositionSnapshotTest {

    @Test
    fun offersListeningPositionFromTheStorytellerAppAsAnAudioLocator() {
        val locator = """{"href":"audiobook://book-1","type":"audio/mpeg","locations":{"totalProgression":0.58}}"""

        val snapshot = position(locator).toEbookSnapshot()!!

        assertEquals(0.58f, snapshot.percentage, 0f)
        assertEquals(1_790_404_409_954L, snapshot.updatedAt)
        assertEquals(AudioLocatorPosition(timeMs = null, progression = 0.58), AudioLocatorPosition.parse(snapshot.locatorJson))
    }

    @Test
    fun decodesAudioLocatorsStoredAsJsonStrings() {
        val locator = """{"href":"","type":"audio","locations":{"totalProgression":0.2,"fragments":["t=120"]}}"""
        val response = StorytellerPositionResponse(timestamp = 1L, locator = JsonPrimitive(locator))

        val snapshot = response.toEbookSnapshot()!!

        assertEquals(AudioLocatorPosition(timeMs = 120_000L, progression = 0.2), AudioLocatorPosition.parse(snapshot.locatorJson))
    }

    @Test
    fun keepsTextLocatorsAsReadingPositions() {
        val locator = """{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["s145"],"totalProgression":0.1}}"""

        val snapshot = position(locator).toEbookSnapshot()!!

        assertEquals(0.1f, snapshot.percentage, 0f)
        assertEquals(Json.parseToJsonElement(locator), Json.parseToJsonElement(snapshot.locatorJson!!))
    }

    @Test
    fun skipsPositionsWithoutProgression() {
        assertNull(position("""{"href":"OEBPS/text/ch1.xhtml","locations":{}}""").toEbookSnapshot())
    }

    private fun position(locator: String) = StorytellerPositionResponse(
        timestamp = 1_790_404_409_954L,
        locator = Json.parseToJsonElement(locator),
    )
}
