package com.enve.core.data.local

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ReaderPageTurnStoreTest {
    @Test
    fun defaultsToStandardAndCurlSurvivesReopening() = runBlocking {
        val directory = Files.createTempDirectory("page-turn").toFile()
        val file = directory.resolve("settings.preferences_pb")
        var job = SupervisorJob()
        try {
            var store = ReaderPageTurnStore(dataStore(job, file))
            assertEquals(ReaderPageTurnStyle.STANDARD, store.style.first())
            store.save(ReaderPageTurnStyle.CURL)
            job.cancelAndJoin()

            job = SupervisorJob()
            store = ReaderPageTurnStore(dataStore(job, file))
            assertEquals(ReaderPageTurnStyle.CURL, store.style.first())
            store.save(ReaderPageTurnStyle.STANDARD)
            assertEquals(ReaderPageTurnStyle.STANDARD, store.style.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun unknownStoredValuesFallBackToStandard() = runBlocking {
        val directory = Files.createTempDirectory("page-turn-unknown").toFile()
        val job = SupervisorJob()
        try {
            val dataStore = dataStore(job, directory.resolve("settings.preferences_pb"))
            dataStore.edit { it[stringPreferencesKey("reader.pageTurn.style")] = "ROTATE" }
            assertEquals(ReaderPageTurnStyle.STANDARD, ReaderPageTurnStore(dataStore).style.first())
            assertEquals(ReaderPageTurnStyle.STANDARD, ReaderPageTurnStore.styleFor(null))
            assertEquals(ReaderPageTurnStyle.STANDARD, ReaderPageTurnStore.styleFor("curl"))
            assertEquals(ReaderPageTurnStyle.CURL, ReaderPageTurnStore.styleFor("CURL"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun profilesWithSeparatePreferenceFilesDoNotShareStyle() = runBlocking {
        val directory = Files.createTempDirectory("page-turn-profiles").toFile()
        val job = SupervisorJob()
        try {
            val adult = ReaderPageTurnStore(dataStore(job, directory.resolve("adult.preferences_pb")))
            val child = ReaderPageTurnStore(dataStore(job, directory.resolve("child.preferences_pb")))
            adult.save(ReaderPageTurnStyle.CURL)
            assertEquals(ReaderPageTurnStyle.CURL, adult.style.first())
            assertEquals(ReaderPageTurnStyle.STANDARD, child.style.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    private fun dataStore(job: Job, file: File) =
        PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
}
