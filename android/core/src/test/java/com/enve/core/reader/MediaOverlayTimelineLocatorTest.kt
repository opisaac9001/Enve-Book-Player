package com.enve.core.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaOverlayTimelineLocatorTest {
    private fun timeline(first: String = "Audio/first.mp3", second: String = "Audio/second.mp3") = MediaOverlayTimeline(
        listOf(
            MediaOverlayTimeline.Clip("first", "one.xhtml", first, 10.0, 20.0),
            MediaOverlayTimeline.Clip("second", "two.xhtml", second, 10.0, 30.0),
        ), mapOf(first to 100.0, second to 100.0), listOf(0.2, 0.8),
    )

    @Test fun namedAudioOffsetWinsOverTextAndSpokenFractions() {
        val json = """{"href":"second.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"],"totalProgression":0.01}}"""
        val resolved = requireNotNull(timeline().resolveEpub3Locator(json))
        assertEquals(1, resolved.clipIndex)
        assertEquals(117.25, resolved.audioTime, 0.0)
        assertEquals(MediaOverlayTimeline.Source.FRAGMENT, resolved.source)
    }

    @Test fun audioPercentageUsesWholeFileDurationsIncludingGaps() {
        val json = """{"href":"audiobook://fixture","type":"audio","locations":{"totalProgression":0.6}}"""
        val resolved = requireNotNull(timeline().resolveEpub3Locator(json))
        assertEquals(1, resolved.clipIndex)
        assertEquals(120.0, resolved.audioTime, 0.0)
    }

    @Test fun namedAudioProgressionStaysWithinItsFile() {
        val json = """{"href":"second.mp3","type":"audio/mpeg","locations":{"progression":0.25,"totalProgression":0.01}}"""
        assertEquals(125.0, requireNotNull(timeline().resolveEpub3Locator(json)).audioTime, 0.0)
    }

    @Test fun duplicateAudioBasenamesRequireAnExactPath() {
        val timeline = timeline("Audio/one/track.mp3", "Audio/two/track.mp3")
        val exact = """{"href":"Audio/two/track.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"],"totalProgression":0.01}}"""
        assertEquals(117.25, requireNotNull(timeline.resolveEpub3Locator(exact)).audioTime, 0.0)
        val ambiguous = """{"href":"track.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"],"totalProgression":0.6}}"""
        assertEquals(120.0, requireNotNull(timeline.resolveEpub3Locator(ambiguous)).audioTime, 0.0)
        val unresolved = """{"href":"track.mp3","type":"audio/mpeg","locations":{"fragments":["t=17.25"]}}"""
        assertNull(timeline.resolveEpub3Locator(unresolved))
    }

    @Test fun generatedTextLocatorRestoresTimeWithinTheSentence() {
        val timeline = timeline()
        val json = requireNotNull(timeline.textLocatorJson(1, 117.25))
        val resolved = requireNotNull(timeline.resolveEpub3Locator(json))
        assertEquals(1, resolved.clipIndex)
        assertEquals(117.25, resolved.audioTime, 0.0)
        assertEquals(MediaOverlayTimeline.Source.FRAGMENT, resolved.source)
    }

    @Test fun fragmentTimeCannotJumpToAnotherSentence() {
        val json = """{"href":"one.xhtml","type":"application/xhtml+xml","locations":{"fragments":["first","t=117.25"]}}"""
        assertEquals(10.0, requireNotNull(timeline().resolveEpub3Locator(json)).audioTime, 0.0)
    }

    @Test fun invalidTimeFragmentsUseTheAudioPercentage() {
        for (time in listOf("NaN", "Infinity", "-5")) {
            val json = """{"href":"second.mp3","type":"audio/mpeg","locations":{"fragments":["t=$time"],"totalProgression":0.6}}"""
            assertEquals(120.0, requireNotNull(timeline().resolveEpub3Locator(json)).audioTime, 0.0)
        }
    }
}
