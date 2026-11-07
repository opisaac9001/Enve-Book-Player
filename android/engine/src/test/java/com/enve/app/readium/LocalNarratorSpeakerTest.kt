package com.enve.app.readium

import com.enve.app.readium.narrator.NarratorAudio
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalNarratorSpeakerTest {
    private class Output : NarratorAudioOutput {
        val plays = mutableListOf<CompletableDeferred<Unit>>()
        lateinit var paused: StateFlow<Boolean>

        override suspend fun play(audio: NarratorAudio, paused: StateFlow<Boolean>, onProgress: (Float) -> Unit) {
            this.paused = paused
            val done = CompletableDeferred<Unit>()
            plays += done
            onProgress(0.5f)
            done.await()
        }
    }

    private class Narration(
        scope: CoroutineScope,
        render: suspend (String) -> NarratorAudio = { NarratorAudio(FloatArray(8), 24_000) },
    ) {
        val output = Output()
        val synthesized = mutableListOf<String>()
        val events = mutableListOf<String>()
        val speaker = LocalNarratorSpeaker(
            scope,
            synthesize = { text -> synthesized += text; render(text) },
            output = output,
            onStart = { events += "start:$it" },
            onRangeStart = { id, start -> events += "range:$id:$start" },
            onDone = { events += "done:$it" },
            onError = { events += "error:$it" },
        )
    }

    @Test
    fun preparedAudioIsReusedForTheMatchingUtterance() = runBlocking {
        val narration = Narration(this)
        narration.speaker.prepare("Next sentence.")
        yield()
        narration.speaker.speak("Next sentence.", "a")
        yield()
        assertEquals(listOf("Next sentence."), narration.synthesized)
        assertEquals("start:a", narration.events.first())

        narration.output.plays.single().complete(Unit)
        yield()
        assertTrue("range:a:5" in narration.events)
        assertEquals("done:a", narration.events.last())
        narration.speaker.release()
    }

    @Test
    fun pausingBeforeAudioIsReadyWaitsForResumeBeforePlaying() = runBlocking {
        val audio = CompletableDeferred<NarratorAudio>()
        val narration = Narration(this) { audio.await() }
        narration.speaker.speak("Hold on.", "a")
        yield()
        assertTrue(narration.speaker.pause())
        audio.complete(NarratorAudio(FloatArray(8), 24_000))
        yield()
        yield()
        assertTrue(narration.events.isEmpty())
        assertTrue(narration.output.plays.isEmpty())

        assertTrue(narration.speaker.resume())
        yield()
        assertEquals(listOf("start:a"), narration.events.take(1))
        assertEquals(1, narration.output.plays.size)
        narration.speaker.release()
    }

    @Test
    fun pausingStartedAudioHoldsTheOutputAndResumeReportsTheStartAgain() = runBlocking {
        val narration = Narration(this)
        narration.speaker.speak("Playing now.", "a")
        yield()
        assertTrue(narration.speaker.pause())
        assertTrue(narration.output.paused.value)
        assertTrue(narration.speaker.resume())
        assertFalse(narration.output.paused.value)
        assertEquals(2, narration.events.count { it == "start:a" })
        assertEquals(1, narration.output.plays.size)
        narration.speaker.release()
    }

    @Test
    fun aReplacedUtteranceNeverReportsCompletion() = runBlocking {
        val narration = Narration(this)
        narration.speaker.speak("First.", "a")
        yield()
        narration.speaker.speak("Second.", "b")
        narration.output.plays.first().complete(Unit)
        yield()
        yield()
        assertFalse(narration.events.any { it == "done:a" || it == "error:a" })
        assertTrue("start:b" in narration.events)

        narration.speaker.release()
        assertFalse(narration.speaker.pause())
    }

    @Test
    fun synthesisFailureIsReportedAndCannotBeHeld() = runBlocking {
        val narration = Narration(this) { error("Model files are missing") }
        narration.speaker.speak("Fails.", "a")
        yield()
        yield()
        assertEquals(listOf("error:a"), narration.events)
        assertFalse(narration.speaker.pause())
        narration.speaker.release()
    }

    @Test
    fun invalidatingDiscardsPreparedAudioRenderedWithOldSettings() = runBlocking {
        val narration = Narration(this)
        narration.speaker.prepare("Again.")
        yield()
        narration.speaker.invalidate()
        narration.speaker.speak("Again.", "a")
        yield()
        assertEquals(listOf("Again.", "Again."), narration.synthesized)
        narration.speaker.release()
    }
}
