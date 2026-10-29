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
    private class Playback(scope: CoroutineScope, maxInputLength: Int = 4_000) {
        val spoken = mutableListOf<Pair<String, String>>()
        val failures = mutableListOf<String>()
        var acceptsSpeech = true
        val service = EbookTTSService(
            scope,
            speak = { text, id -> spoken.add(text to id); acceptsSpeech },
            stopSpeech = {},
            onNavigate = {},
            onFailure = failures::add,
            maxInputLength = maxInputLength,
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
}
