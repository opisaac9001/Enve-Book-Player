package com.enve.app.ui.screens

import com.enve.app.viewmodel.OpenProgressAuthority
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EbookReaderOpenProgressTest {

    private val localLocator = """{"href":"local.xhtml"}"""
    private val remoteLocator = """{"href":"remote.xhtml"}"""

    @Test
    fun keepLocalChoiceOpensTheLocalPositionAndKeepsCachedAudio() {
        val resolution = openProgressResolutionFor(
            authority = OpenProgressAuthority.LOCAL,
            localLocatorJson = localLocator,
            localProgress = 0.25f,
            remoteLocatorJson = remoteLocator,
            remoteProgress = 0.75f,
        )
        assertEquals(localLocator, resolution.locatorJson)
        assertEquals(0.25f, resolution.progress, 0f)
        assertTrue(resolution.mayUseCachedAudioPosition)
    }

    @Test
    fun useRemoteChoiceOpensTheRemotePositionAndDropsCachedAudio() {
        val resolution = openProgressResolutionFor(
            authority = OpenProgressAuthority.REMOTE,
            localLocatorJson = localLocator,
            localProgress = 0.25f,
            remoteLocatorJson = remoteLocator,
            remoteProgress = 0.75f,
        )
        assertEquals(remoteLocator, resolution.locatorJson)
        assertEquals(0.75f, resolution.progress, 0f)
        assertFalse(resolution.mayUseCachedAudioPosition)
    }

    @Test
    fun automaticResolutionStaysOnTheLocalPosition() {
        val resolution = openProgressResolutionFor(
            authority = OpenProgressAuthority.AUTOMATIC,
            localLocatorJson = localLocator,
            localProgress = 0.25f,
            remoteLocatorJson = remoteLocator,
            remoteProgress = 0.75f,
        )
        assertEquals(localLocator, resolution.locatorJson)
        assertTrue(resolution.mayUseCachedAudioPosition)
    }

    @Test
    fun watchdogAcceptsWorkThatFinishesInsideTheBudget() = runBlocking {
        val budgets = mutableListOf<Long>()
        val completed = awaitWithinActiveBudget(
            budgetMs = 1_000L,
            pausedMs = { 0L },
            await = { budget -> budgets += budget; true },
        )
        assertTrue(completed)
        assertEquals(listOf(1_000L), budgets)
    }

    @Test
    fun watchdogFiresWhenNoTimeWasSpentWaitingOnTheUser() = runBlocking {
        val completed = awaitWithinActiveBudget(
            budgetMs = 1_000L,
            pausedMs = { 0L },
            await = { false },
        )
        assertFalse(completed)
    }

    @Test
    fun watchdogCreditsTimeSpentOnTheConflictPrompt() = runBlocking {
        val budgets = mutableListOf<Long>()
        var rounds = 0
        val completed = awaitWithinActiveBudget(
            budgetMs = 1_000L,
            pausedMs = { 4_000L },
            await = { budget ->
                budgets += budget
                rounds += 1
                rounds > 1
            },
        )
        assertTrue(completed)
        assertEquals(listOf(1_000L, 4_000L), budgets)
    }

    @Test
    fun watchdogKeepsExtendingWhileTheConflictPromptStaysOpen() = runBlocking {
        val budgets = mutableListOf<Long>()
        var paused = 0L
        val completed = awaitWithinActiveBudget(
            budgetMs = 1_000L,
            pausedMs = { paused },
            await = { budget ->
                budgets += budget
                paused += budget
                budgets.size > 3
            },
        )
        assertTrue(completed)
        assertEquals(listOf(1_000L, 1_000L, 1_000L, 1_000L), budgets)
    }
}
