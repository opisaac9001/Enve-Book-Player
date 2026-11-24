package com.enve.core.data.local

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.intPreferencesKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File
import java.nio.file.Files

class ReadingGoalStoreTest {
    @Test
    fun goalIsOptionalAndDefaultsToTwentyMinutes() = runBlocking {
        val directory = Files.createTempDirectory("reading-goal-default").toFile()
        val job = SupervisorJob()
        try {
            val store = ReadingGoalStore(dataStore(job, directory.resolve("settings.preferences_pb")))
            assertEquals(DailyReadingGoal(enabled = false, minutes = 20), store.goal.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun savedGoalSurvivesReopeningAndDisableKeepsMinutes() = runBlocking {
        val directory = Files.createTempDirectory("reading-goal-persist").toFile()
        val file = directory.resolve("settings.preferences_pb")
        var job = SupervisorJob()
        try {
            var store = ReadingGoalStore(dataStore(job, file))
            store.save(45)
            job.cancelAndJoin()

            job = SupervisorJob()
            store = ReadingGoalStore(dataStore(job, file))
            assertEquals(DailyReadingGoal(enabled = true, minutes = 45), store.goal.first())

            store.disable()
            assertEquals(DailyReadingGoal(enabled = false, minutes = 45), store.goal.first())

            store.save(240)
            assertEquals(DailyReadingGoal(enabled = true, minutes = 240), store.goal.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun rejectsMinutesOutsideTheSupportedRange() = runBlocking {
        val directory = Files.createTempDirectory("reading-goal-range").toFile()
        val job = SupervisorJob()
        try {
            val store = ReadingGoalStore(dataStore(job, directory.resolve("settings.preferences_pb")))
            assertThrows(IllegalArgumentException::class.java) { runBlocking { store.save(0) } }
            assertThrows(IllegalArgumentException::class.java) { runBlocking { store.save(241) } }
            store.save(1)
            assertEquals(DailyReadingGoal(enabled = true, minutes = 1), store.goal.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun clampsCorruptStoredMinutes() = runBlocking {
        val directory = Files.createTempDirectory("reading-goal-corrupt").toFile()
        val job = SupervisorJob()
        try {
            val dataStore = dataStore(job, directory.resolve("settings.preferences_pb"))
            val store = ReadingGoalStore(dataStore)
            store.save(30)
            dataStore.edit { it[intPreferencesKey("enve.readingGoal.dailyMinutes")] = 900 }
            assertEquals(DailyReadingGoal(enabled = true, minutes = 240), store.goal.first())
            dataStore.edit { it[intPreferencesKey("enve.readingGoal.dailyMinutes")] = -5 }
            assertEquals(DailyReadingGoal(enabled = true, minutes = 1), store.goal.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun profilesWithSeparatePreferenceFilesKeepSeparateGoals() = runBlocking {
        val directory = Files.createTempDirectory("reading-goal-profiles").toFile()
        val job = SupervisorJob()
        try {
            val adult = ReadingGoalStore(dataStore(job, directory.resolve("adult.preferences_pb")))
            val child = ReadingGoalStore(dataStore(job, directory.resolve("child.preferences_pb")))
            adult.save(60)
            assertEquals(DailyReadingGoal(enabled = true, minutes = 60), adult.goal.first())
            assertEquals(DailyReadingGoal(), child.goal.first())

            child.save(10)
            adult.disable()
            assertEquals(DailyReadingGoal(enabled = false, minutes = 60), adult.goal.first())
            assertEquals(DailyReadingGoal(enabled = true, minutes = 10), child.goal.first())
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    private fun dataStore(job: Job, file: File) =
        PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
}
