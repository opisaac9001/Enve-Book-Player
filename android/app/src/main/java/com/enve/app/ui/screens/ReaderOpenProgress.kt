package com.enve.app.ui.screens

import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.app.viewmodel.CachedReaderProgress
import com.enve.app.viewmodel.OpenProgressAuthority
import com.enve.app.viewmodel.OpenRemoteProgress

internal data class OpenProgressResolution(
    val locatorJson: String?,
    val progress: Float,
    val mayUseCachedAudioPosition: Boolean,
)

internal data class OpenProgressPlan(
    val resolution: OpenProgressResolution,
    val remote: OpenRemoteProgress,
    val localUpdatedAt: Long = 0L,
)

internal fun sharedReadingOpenPlan(cached: CachedReaderProgress?, intentUpdatedAt: Long): OpenProgressPlan? {
    if (cached == null || cached.updatedAt <= 0L || cached.updatedAt < intentUpdatedAt || !SharedReadingLocation.isSharedPosition(cached.locator)) return null
    return OpenProgressPlan(
        resolution = OpenProgressResolution(cached.locator, cached.progress, mayUseCachedAudioPosition = false),
        remote = OpenRemoteProgress(snapshot = null, authority = OpenProgressAuthority.LOCAL),
        localUpdatedAt = cached.updatedAt,
    )
}

internal fun openProgressResolutionFor(
    authority: OpenProgressAuthority,
    localLocatorJson: String?,
    localProgress: Float,
    remoteLocatorJson: String?,
    remoteProgress: Float,
): OpenProgressResolution = when (authority) {
    OpenProgressAuthority.REMOTE ->
        OpenProgressResolution(remoteLocatorJson, remoteProgress, mayUseCachedAudioPosition = false)
    OpenProgressAuthority.AUTOMATIC, OpenProgressAuthority.LOCAL ->
        OpenProgressResolution(localLocatorJson, localProgress, mayUseCachedAudioPosition = !SharedReadingLocation.isSharedPosition(localLocatorJson))
}

internal suspend fun awaitWithinActiveBudget(
    budgetMs: Long,
    pausedMs: () -> Long,
    await: suspend (Long) -> Boolean,
): Boolean {
    var remaining = budgetMs
    var credited = 0L
    while (true) {
        if (await(remaining)) return true
        val paused = pausedMs()
        val uncredited = paused - credited
        if (uncredited <= 0L) return false
        credited = paused
        remaining = uncredited
    }
}

internal fun selectAudioResumeSeconds(
    locatorAudioSeconds: Long?,
    cachedAudioSeconds: Long?,
    mayUseCachedAudioPosition: Boolean,
): Long? = locatorAudioSeconds
    ?: cachedAudioSeconds?.takeIf { mayUseCachedAudioPosition && it > 0L }

internal fun shouldUseReaderNetwork(
    hasOfflineSource: Boolean,
    networkAvailable: Boolean,
): Boolean = networkAvailable && !hasOfflineSource
