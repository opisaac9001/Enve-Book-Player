package com.enve.app.hearth

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.enve.app.readium.narrator.NarratorPack
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.file.Files

class HearthNarratorPreferencesTest {
    @Test
    fun narratorChoicesStayWithTheirProfileAndSurviveReopening() = runBlocking {
        val directory = Files.createTempDirectory("hearth-narrator").toFile()
        var job = SupervisorJob()
        try {
            fun open(name: String) = HearthPreferencesStore(
                PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
                    directory.resolve("$name.preferences_pb")
                },
            )
            var adult = open("adult")
            val child = open("child")
            val voice = NarratorPack.KOKORO.voices.last()
            adult.setReaderTtsVoice("system-voice")
            adult.setReaderNarratorPack(NarratorPack.KOKORO)
            adult.setReaderNarratorVoice(NarratorPack.KOKORO, voice)
            assertNull(child.readerNarratorPack.first())
            assertNull(child.readerNarratorVoice(NarratorPack.KOKORO).first())
            job.cancelAndJoin()

            job = SupervisorJob()
            adult = open("adult")
            assertEquals(NarratorPack.KOKORO, adult.readerNarratorPack.first())
            assertEquals(voice, adult.readerNarratorVoice(NarratorPack.KOKORO).first())
            assertNull(adult.readerNarratorVoice(NarratorPack.SUPERTONIC).first())

            adult.setReaderNarratorPack(null)
            assertNull(adult.readerNarratorPack.first())
            assertEquals(voice, adult.readerNarratorVoice(NarratorPack.KOKORO).first())
            assertEquals("system-voice", adult.readerTtsVoice.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun aVoiceThePackNoLongerShipsIsIgnored() = runBlocking {
        val directory = Files.createTempDirectory("hearth-narrator-voice").toFile()
        val job = SupervisorJob()
        try {
            val store = HearthPreferencesStore(
                PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
                    directory.resolve("settings.preferences_pb")
                },
            )
            store.setReaderNarratorVoice(NarratorPack.POCKET, "retired-voice")
            assertNull(store.readerNarratorVoice(NarratorPack.POCKET).first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
