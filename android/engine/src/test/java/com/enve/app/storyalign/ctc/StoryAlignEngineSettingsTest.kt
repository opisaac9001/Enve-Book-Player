package com.enve.app.storyalign.ctc

import com.enve.engine.storyalign.StoryAlignEngine
import com.enve.engine.storyalign.StoryAlignSettings
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class StoryAlignEngineSettingsTest {
    @Test
    fun persistedJobsWithoutAnEngineKeepTheirOriginalWhisperPath() {
        val settings = Json.decodeFromString<StoryAlignSettings>("{\"model\":\"tiny.en\"}")
        assertEquals(StoryAlignEngine.WHISPER, settings.engine)
    }
}
