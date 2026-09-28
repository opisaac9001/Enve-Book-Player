package com.enve.core.data.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioLocatorPositionTest {

    @Test
    fun readsStorytellerAudiobookLocatorAsAudioFraction() {
        val position = AudioLocatorPosition.parse(
            """{"href":"audiobook://track-3","type":"application/octet-stream","locations":{"totalProgression":0.42}}""",
        )

        assertEquals(AudioLocatorPosition(timeMs = null, progression = 0.42), position)
    }

    @Test
    fun readsAudioTypedLocatorWithMediaFragmentTime() {
        val position = AudioLocatorPosition.parse(
            """{"href":"","type":"audio","locations":{"totalProgression":0.25,"fragments":["t=754.5"]}}""",
        )

        assertEquals(AudioLocatorPosition(timeMs = 754_500L, progression = 0.25), position)
    }

    @Test
    fun treatsMissingAudioProgressionAsTheStart() {
        val position = AudioLocatorPosition.parse("""{"href":"audiobook://book","type":"audio/mpeg","locations":{}}""")

        assertEquals(AudioLocatorPosition(timeMs = null, progression = 0.0), position)
    }

    @Test
    fun ignoresTextLocators() {
        val text = """{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["s1"],"totalProgression":0.3}}"""

        assertNull(AudioLocatorPosition.parse(text))
        assertFalse(AudioLocatorPosition.isAudioLocator(text))
        assertFalse(AudioLocatorPosition.isAudioLocator("epubcfi(/6/4!/4/2)"))
        assertFalse(AudioLocatorPosition.isAudioLocator(null))
        assertTrue(AudioLocatorPosition.isAudioLocator("""{"href":"audiobook://x","locations":{"totalProgression":1.2}}"""))
        assertEquals(1.0, AudioLocatorPosition.parse("""{"href":"audiobook://x","locations":{"totalProgression":1.2}}""")!!.progression, 0.0)
    }
}
