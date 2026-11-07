package com.enve.app.readium

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EbookTTSServiceTest {
    private class Playback(scope: CoroutineScope, maxInputLength: Int = 4_000, holdsSpeech: Boolean = false) {
        val spoken = mutableListOf<Pair<String, String>>()
        val prepared = mutableListOf<String>()
        val failures = mutableListOf<String>()
        var acceptsSpeech = true
        var stops = 0
        var resumes = 0
        val service = EbookTTSService(
            scope,
            speak = { text, id -> spoken.add(text to id); acceptsSpeech },
            stopSpeech = { stops++ },
            onNavigate = {},
            onFailure = failures::add,
            maxInputLength = maxInputLength,
            prepareSpeech = prepared::add,
            pauseSpeech = { holdsSpeech },
            resumeSpeech = { resumes++; holdsSpeech },
        ).also { it.setReady(true) }

        fun start(vararg text: String) {
            val paragraphs = text.iterator()
            service.start { if (paragraphs.hasNext()) EbookTTSParagraph(paragraphs.next()) else null }
        }
    }

    @Test
    fun pauseDuringInitialContentLoadWaitsForExplicitResume() = runBlocking {
        val playback = Playback(this)
        val pending = CompletableDeferred<EbookTTSParagraph>()
        playback.service.start { pending.await() }
        yield()
        playback.service.pause()
        pending.complete(EbookTTSParagraph("First paragraph."))
        yield()

        assertTrue(playback.spoken.isEmpty())
        assertTrue(playback.service.state.value.active)
        assertFalse(playback.service.state.value.playing)
        playback.service.resume()
        assertEquals("First paragraph.", playback.spoken.single().first)
        playback.service.stop()
    }

    @Test
    fun resumeRetainsTheLastSpokenWordAndRejectsTheInterruptedCallback() = runBlocking {
        val playback = Playback(this)
        playback.start("First second third.", "Next paragraph.")
        yield()
        val firstId = playback.spoken.last().second
        playback.service.onStart(firstId)
        playback.service.onRangeStart(firstId, 6)
        playback.service.pause()
        playback.service.restart()
        assertEquals(1, playback.spoken.size)

        playback.service.resume()
        val resumedId = playback.spoken.last().second
        assertNotEquals(firstId, resumedId)
        assertEquals("second third.", playback.spoken.last().first)
        playback.service.onDone(firstId)
        assertEquals(0, playback.service.state.value.paragraph)
        assertTrue(playback.service.state.value.playing)
        playback.service.onDone(resumedId)
        yield()
        assertEquals("Next paragraph.", playback.spoken.last().first)
        playback.service.stop()
    }

    @Test
    fun pausedParagraphSkipsStayPausedAndResumeAtTheChosenParagraph() = runBlocking {
        val playback = Playback(this)
        playback.start("One.", "Two.", "Three.")
        yield()
        playback.service.pause()
        playback.service.next()
        yield()
        playback.service.next()
        yield()
        playback.service.previous()
        assertEquals(1, playback.spoken.size)
        assertEquals(1, playback.service.state.value.paragraph)
        assertFalse(playback.service.state.value.playing)
        playback.service.resume()
        assertEquals("Two.", playback.spoken.last().first)
        playback.service.stop()
    }

    @Test
    fun changingVoiceWhilePausedDoesNotLoseAnUnstartedUtterance() = runBlocking {
        val playback = Playback(this)
        playback.start("Still at the beginning.")
        yield()
        playback.service.pause()
        playback.service.restart()
        playback.service.resume()
        assertEquals(listOf("Still at the beginning.", "Still at the beginning."), playback.spoken.map { it.first })
        playback.service.stop()
    }

    @Test
    fun lateContentFromAStoppedSessionCannotReplaceTheCurrentBook() = runBlocking {
        val playback = Playback(this)
        val pending = CompletableDeferred<EbookTTSParagraph>()
        playback.service.start { withContext(NonCancellable) { pending.await() } }
        yield()
        playback.start("Current book.")
        yield()
        pending.complete(EbookTTSParagraph("Stale book."))
        yield()
        assertEquals(listOf("Current book."), playback.spoken.map { it.first })
        playback.service.stop()
    }

    @Test
    fun failedSynthesisCanResumeTheSamePassage() = runBlocking {
        val playback = Playback(this)
        playback.acceptsSpeech = false
        playback.start("Retry this passage.")
        yield()
        assertFalse(playback.service.state.value.playing)
        assertTrue(playback.failures.isNotEmpty())
        playback.acceptsSpeech = true
        playback.service.resume()
        assertEquals("Retry this passage.", playback.spoken.last().first)
        assertTrue(playback.service.state.value.playing)
        playback.service.stop()
    }

    @Test
    fun failedContentLoadCanBeRetriedWithoutADeadPlayButton() = runBlocking {
        val playback = Playback(this)
        var attempts = 0
        playback.service.start {
            if (attempts++ == 0) error("Temporary read failure")
            EbookTTSParagraph("Recovered passage.")
        }
        yield()
        assertFalse(playback.service.state.value.playing)
        playback.service.resume()
        yield()
        assertEquals("Recovered passage.", playback.spoken.single().first)
        playback.service.stop()
    }

    @Test
    fun aVoiceBecomingReadyCannotUnpausePendingSpeech() = runBlocking {
        val playback = Playback(this)
        playback.service.setReady(false)
        playback.start("Wait for the voice.")
        yield()
        playback.service.pause()
        playback.service.setReady(true)
        assertTrue(playback.spoken.isEmpty())
        playback.service.resume()
        assertEquals("Wait for the voice.", playback.spoken.single().first)
        playback.service.stop()
    }

    @Test
    fun longParagraphsKeepAllTextAndNeverSplitASurrogatePair() = runBlocking {
        val playback = Playback(this, maxInputLength = 12)
        val text = "abcdefghijk🙂and a long paragraph with every word retained."
        playback.start(text)
        yield()
        repeat(30) {
            if (playback.service.state.value.active) {
                playback.service.onDone(playback.spoken.last().second)
                yield()
            }
        }
        assertFalse(playback.service.state.value.active)
        assertEquals(text, playback.spoken.joinToString("") { it.first })
        assertTrue(playback.spoken.all { it.first.length <= 12 && !it.first.last().isHighSurrogate() })
    }

    @Test
    fun longParagraphsBreakAtSentenceEndsAndPrepareTheNextChunk() = runBlocking {
        val playback = Playback(this, maxInputLength = 40)
        playback.start("One short sentence here. Then a second sentence follows on.")
        yield()
        assertEquals("One short sentence here. ", playback.spoken.single().first)
        assertEquals(listOf("Then a second sentence follows on."), playback.prepared)
        playback.service.onDone(playback.spoken.last().second)
        assertEquals("Then a second sentence follows on.", playback.spoken.last().first)
        playback.service.stop()
    }

    @Test
    fun heldPauseResumesTheSameUtteranceWithoutSpeakingAgain() = runBlocking {
        val playback = Playback(this, holdsSpeech = true)
        playback.start("Keep this utterance.")
        yield()
        val id = playback.spoken.single().second
        playback.service.onStart(id)
        val stopsBeforePause = playback.stops
        playback.service.pause()
        playback.service.pause()
        assertEquals(stopsBeforePause, playback.stops)
        assertFalse(playback.service.state.value.playing)

        playback.service.resume()
        assertEquals(1, playback.resumes)
        assertEquals(1, playback.spoken.size)
        playback.service.onStart(id)
        assertTrue(playback.service.state.value.playing)
        assertFalse(playback.service.state.value.preparing)
        playback.service.onDone(id)
        yield()
        assertFalse(playback.service.state.value.active)
    }

    @Test
    fun changingSettingsWhileHeldDiscardsTheHeldAudioAndStaysPaused() = runBlocking {
        val playback = Playback(this, holdsSpeech = true)
        playback.start("Change my voice.")
        yield()
        playback.service.pause()
        playback.service.restart()
        assertFalse(playback.service.state.value.playing)
        assertEquals(1, playback.spoken.size)

        playback.service.resume()
        assertEquals(0, playback.resumes)
        assertEquals(listOf("Change my voice.", "Change my voice."), playback.spoken.map { it.first })
        assertTrue(playback.service.state.value.playing)
        playback.service.stop()
    }

    @Test
    fun theNextParagraphIsLoadedAndPreparedBeforeTheCurrentOneEnds() = runBlocking {
        val playback = Playback(this)
        val paragraphs = listOf("First.", "Second.").iterator()
        var loads = 0
        playback.service.start {
            loads++
            if (paragraphs.hasNext()) EbookTTSParagraph(paragraphs.next()) else null
        }
        yield()
        yield()
        assertEquals(2, loads)
        assertEquals(listOf("Second."), playback.prepared)

        playback.service.onDone(playback.spoken.last().second)
        assertEquals("Second.", playback.spoken.last().first)
        assertEquals(1, playback.service.state.value.paragraph)
        assertEquals(2, loads)
        playback.service.stop()
    }

    @Test
    fun previousWhileTheNextParagraphLoadsStaysOnTheCurrentParagraph() = runBlocking {
        val playback = Playback(this)
        val second = CompletableDeferred<EbookTTSParagraph?>()
        var loads = 0
        playback.service.start { if (loads++ == 0) EbookTTSParagraph("First.") else second.await() }
        yield()
        playback.service.next()
        assertEquals(0, playback.service.state.value.paragraph)
        playback.service.previous()
        second.complete(EbookTTSParagraph("Second."))
        yield()
        assertEquals(0, playback.service.state.value.paragraph)
        assertEquals(listOf("First.", "First."), playback.spoken.map { it.first })

        playback.service.next()
        assertEquals(1, playback.service.state.value.paragraph)
        assertEquals("Second.", playback.spoken.last().first)
        playback.service.stop()
    }

    @Test
    fun aLookaheadThatFindsNoMoreTextEndsTheSessionWhenSpeechFinishes() = runBlocking {
        val playback = Playback(this)
        playback.start("Only paragraph.")
        yield()
        yield()
        playback.service.onDone(playback.spoken.single().second)
        assertFalse(playback.service.state.value.active)
        assertTrue(playback.failures.isEmpty())
    }
}
