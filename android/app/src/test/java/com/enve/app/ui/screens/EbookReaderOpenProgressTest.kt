package com.enve.app.ui.screens

import com.enve.app.viewmodel.OpenProgressAuthority
import com.enve.app.viewmodel.CachedReaderProgress
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
    @Test fun newerSharedZeroOverridesStaleIntentAndCachedNarrationTime() {
        val marked = """{"locations":{"totalProgression":0},"enveSharedPosition":true}"""
        val plan = sharedReadingOpenPlan(CachedReaderProgress(0f, marked, 900L, updatedAt = 200L), intentUpdatedAt = 100L)!!
        assertEquals(0f, plan.resolution.progress, 0f)
        assertEquals(marked, plan.resolution.locatorJson)
        assertEquals(OpenProgressAuthority.LOCAL, plan.remote.authority)
        assertEquals(200L, plan.localUpdatedAt)
        assertFalse(plan.resolution.mayUseCachedAudioPosition)
        assertEquals(null, selectAudioResumeSeconds(null, 900L, plan.resolution.mayUseCachedAudioPosition))
        val ordinary = openProgressResolutionFor(OpenProgressAuthority.LOCAL, localLocator, 0.25f, null, 0f)
        assertEquals(900L, selectAudioResumeSeconds(null, 900L, ordinary.mayUseCachedAudioPosition))
    }

    @Test fun unmarkedOrOlderCachedPositionsDoNotOverrideIntentAuthority() {
        assertEquals(null, sharedReadingOpenPlan(CachedReaderProgress(0.25f, localLocator, 0L, updatedAt = 200L), 100L))
        val marked = """{"locations":{"totalProgression":0.25},"enveSharedPosition":true}"""
        assertEquals(null, sharedReadingOpenPlan(CachedReaderProgress(0.25f, marked, 0L, updatedAt = 100L), 200L))
    }

}
