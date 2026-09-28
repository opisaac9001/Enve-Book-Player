package com.enve.audiobookshelf

import com.enve.core.reader.EpubCfi
import com.enve.core.reader.MediaOverlayTimeline
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudiobookshelfEbookLocationTest {
    private val clips = listOf(
        MediaOverlayTimeline.Clip("s1", "OEBPS/text/ch1.xhtml", "a.mp3", 0.0, 10.0),
        MediaOverlayTimeline.Clip("s2", "OEBPS/text/ch1.xhtml", "a.mp3", 10.0, 20.0),
        MediaOverlayTimeline.Clip("s3", "OEBPS/text/ch1.xhtml", "a.mp3", 20.0, 30.0),
        MediaOverlayTimeline.Clip("s4", "OEBPS/text/ch1.xhtml", "a.mp3", 30.0, 40.0),
    )

    private val timeline = MediaOverlayTimeline(clips, clipTextProgressions = listOf(0.1, 0.2, 0.3, 0.4))

    private fun sentence(id: String) =
        """{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["$id"],"totalProgression":0.2}}"""

    private fun fragment(locator: String?): String? =
        locator?.let(EpubCfi::jsonObject)?.get("locations")?.jsonObject?.get("fragments")?.jsonArray?.firstOrNull()?.jsonPrimitive?.content

    @Test
    fun serverLocationDecodesCfisAndLegacyReadiumJson() {
        val legacy = sentence("s1")

        assertEquals(AbsServerEbookLocation.ReadiumLocatorJson(legacy), absServerEbookLocation(legacy))
        assertEquals(
            AbsServerEbookLocation.Cfi("epubcfi(/6/18!/4/2[ch1]/8/2[s1])"),
            absServerEbookLocation(" epubcfi(/6/18!/4/2[ch1]/8/2[s1]) "),
        )
        assertNull(absServerEbookLocation("page=12"))
        assertNull(absServerEbookLocation("{not json"))
        assertNull(absServerEbookLocation(""))
        assertNull(absServerEbookLocation(null))
    }

    @Test
    fun aPositionThatFailedTheRoundTripOmitsEbookLocation() {
        val omitted = absEbookProgressBody(0.42f, ebookLocation = null, itemHasAudio = false, audioPosition = null)
        val sent = absEbookProgressBody(0.42f, ebookLocation = "epubcfi(/6/4!/4/2[s1])", itemHasAudio = false, audioPosition = null)

        assertEquals(listOf("ebookProgress", "isFinished"), omitted.keys.sorted())
        assertEquals(0.42, omitted.getValue("ebookProgress").jsonPrimitive.doubleOrNull!!, 1e-6)
        assertEquals("epubcfi(/6/4!/4/2[s1])", sent.getValue("ebookLocation").jsonPrimitive.content)
    }

    @Test
    fun ebookPatchLeavesTheAudioSideAlone() {
        val reading = absEbookProgressBody(0.42f, "epubcfi(/6/4!/4/2)", itemHasAudio = true, audioPosition = null)
        val finishing = absEbookProgressBody(1f, null, itemHasAudio = true, audioPosition = null)
        val narrating = absEbookProgressBody(0.42f, "epubcfi(/6/4!/4/2)", itemHasAudio = true, audioPosition = AbsAudioPosition(600.0, 2400.0))

        assertEquals(listOf("ebookLocation", "ebookProgress"), reading.keys.sorted())
        assertEquals(true, finishing.getValue("isFinished").jsonPrimitive.booleanOrNull)
        assertEquals(600.0, narrating.getValue("currentTime").jsonPrimitive.doubleOrNull!!, 0.0)
        assertEquals(2400.0, narrating.getValue("duration").jsonPrimitive.doubleOrNull!!, 0.0)
        assertEquals(0.25, narrating.getValue("progress").jsonPrimitive.doubleOrNull!!, 0.0)
        assertNull(narrating["isFinished"])
    }

    @Test
    fun narrationMatchesTheItemAudioOnlyWithinOnePercent() {
        assertTrue(MediaOverlayTimeline.narrationMatchesAudio(36_000.0, 36_300.0))
        assertTrue(MediaOverlayTimeline.narrationMatchesAudio(36_300.0, 36_000.0))
        assertFalse(MediaOverlayTimeline.narrationMatchesAudio(36_000.0, 36_400.0))
        assertFalse(MediaOverlayTimeline.narrationMatchesAudio(2_336.0, 28_800.0))
        assertFalse(MediaOverlayTimeline.narrationMatchesAudio(0.0, 0.0))
    }

    @Test
    fun narrationTimeIsPushedOnlyWhileItSitsInTheNarratedSentence() {
        val clip = timeline.clipTimings[2]
        val live = absItemAudioPosition(narrationTime = 25.0, clip = clip, overlayDuration = 40.0, itemAudioDuration = 40.2)!!

        assertEquals(25.125, live.currentTime, 1e-9)
        assertEquals(40.2, live.duration, 0.0)
        assertNull(absItemAudioPosition(narrationTime = 5.0, clip = clip, overlayDuration = 40.0, itemAudioDuration = 40.2))
        assertNull(absItemAudioPosition(narrationTime = 25.0, clip = clip, overlayDuration = 40.0, itemAudioDuration = 60.0))
    }

    @Test
    fun itemAudioSomeoneElseMovedBecomesTheNarratedSentence() {
        val moved = absNarratedLocator(
            itemAudioTime = 35.175,
            itemAudioDuration = 40.2,
            timeline = timeline,
            serverLocator = sentence("s1"),
            lastSyncedAudioTime = 5.0,
        )!!

        assertEquals("s4", fragment(moved.first))
        assertEquals(0.4, moved.second, 0.0)
    }

    @Test
    fun itemAudioEnveAlreadySyncedYieldsToTheEbookPage() {
        val pagedAway = absNarratedLocator(35.0, 40.0, timeline, serverLocator = sentence("s1"), lastSyncedAudioTime = 35.0)
        val pagedBack = absNarratedLocator(35.0, 40.0, timeline, serverLocator = null, lastSyncedAudioTime = 35.004)

        assertNull(pagedAway)
        assertNull(pagedBack)
    }

    @Test
    fun itemAudioYieldsWhenItAgreesWithTheEbookSentence() {
        val agreeing = absNarratedLocator(35.0, 40.0, timeline, serverLocator = sentence("s4"), lastSyncedAudioTime = null)
        val neverRead = absNarratedLocator(15.0, 40.0, timeline, serverLocator = null, lastSyncedAudioTime = null)

        assertNull(agreeing)
        assertEquals("s2", fragment(neverRead?.first))
    }

    @Test
    fun onlyAnAudioTimeEnveDidNotSyncCountsAsMovedElsewhere() {
        assertTrue(absItemAudioMovedElsewhere(120.0, lastSyncedAudioTime = null))
        assertTrue(absItemAudioMovedElsewhere(120.0, lastSyncedAudioTime = 119.5))
        assertFalse(absItemAudioMovedElsewhere(120.0, lastSyncedAudioTime = 120.0))
        assertFalse(absItemAudioMovedElsewhere(120.0, lastSyncedAudioTime = 120.005))
    }
}
