package com.enve.app.viewmodel

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.servertools.ServerAchievementSummary
import com.enve.engine.servertools.ServerBookmark
import com.enve.engine.servertools.ServerFeature
import com.enve.engine.servertools.ServerFeatureUnsupportedException
import com.enve.engine.servertools.ServerHighlight
import com.enve.engine.servertools.ServerHistoryEntry
import com.enve.engine.servertools.ServerStatGroup
import com.enve.engine.servertools.ServerToolsFacade
import com.enve.engine.servertools.ServerToolsTarget
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

private const val HIGHLIGHT_LIMIT = 12
private const val BOOKMARK_LIMIT = 12
private const val HISTORY_LIMIT = 15

data class ServerToolsState(
    val target: ServerToolsTarget? = null,
    val loading: Boolean = true,
    val stats: List<ServerStatGroup> = emptyList(),
    val achievements: ServerAchievementSummary? = null,
    val highlights: List<ServerHighlight> = emptyList(),
    val bookmarks: List<ServerBookmark> = emptyList(),
    val history: List<ServerHistoryEntry> = emptyList(),
    val failedFeatures: Set<ServerFeature> = emptySet(),
    val unsupported: Boolean = false,
) {
    val hasAnyContent: Boolean
        get() = stats.isNotEmpty() || achievements != null || highlights.isNotEmpty() ||
            bookmarks.isNotEmpty() || history.isNotEmpty()
}

@HiltViewModel
class ServerToolsViewModel @Inject constructor(
    private val serverTools: ServerToolsFacade,
    savedStateHandle: SavedStateHandle,
) : ViewModel() {
    private val connectionId: String = savedStateHandle["connectionId"] ?: ""
    private val loaded = MutableStateFlow(ServerToolsState())

    val state: StateFlow<ServerToolsState> = combine(
        serverTools.targets.map { targets -> targets.firstOrNull { it.connectionId == connectionId } },
        loaded,
    ) { target, current ->
        current.copy(target = target)
    }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ServerToolsState())

    init {
        refresh()
    }

    fun refresh() {
        if (connectionId.isBlank()) {
            loaded.update { it.copy(loading = false) }
            return
        }
        viewModelScope.launch {
            loaded.update { it.copy(loading = true, failedFeatures = emptySet()) }
            val target = serverTools.targets.first().firstOrNull { it.connectionId == connectionId }
            loaded.value = loadServerToolsState(serverTools, connectionId, target?.features.orEmpty())
        }
    }
}

internal suspend fun loadServerToolsState(
    serverTools: ServerToolsFacade,
    connectionId: String,
    features: Set<ServerFeature>,
): ServerToolsState = coroutineScope {
    val stats = async {
        loadFeature(ServerFeature.STATS, features, emptyList()) { serverTools.stats(connectionId) }
    }
    val achievements = async {
        loadFeature(ServerFeature.ACHIEVEMENTS, features, null) { serverTools.achievements(connectionId) }
    }
    val highlights = async {
        loadFeature(ServerFeature.HIGHLIGHTS, features, emptyList()) { serverTools.highlights(connectionId, HIGHLIGHT_LIMIT) }
    }
    val bookmarks = async {
        loadFeature(ServerFeature.BOOKMARKS, features, emptyList()) { serverTools.bookmarks(connectionId, BOOKMARK_LIMIT) }
    }
    val history = async {
        loadFeature(ServerFeature.HISTORY, features, emptyList()) { serverTools.history(connectionId, HISTORY_LIMIT) }
    }
    val results = mapOf(
        ServerFeature.STATS to stats.await(),
        ServerFeature.ACHIEVEMENTS to achievements.await(),
        ServerFeature.HIGHLIGHTS to highlights.await(),
        ServerFeature.BOOKMARKS to bookmarks.await(),
        ServerFeature.HISTORY to history.await(),
    ).filterKeys { it in features }
    ServerToolsState(
        loading = false,
        stats = stats.await().value,
        achievements = achievements.await().value,
        highlights = highlights.await().value,
        bookmarks = bookmarks.await().value,
        history = history.await().value,
        failedFeatures = results.filterValues {
            it.error != null && it.error !is ServerFeatureUnsupportedException
        }.keys,
        unsupported = results.isNotEmpty() && results.values.all { it.error is ServerFeatureUnsupportedException },
    )
}

private data class ServerFeatureResult<T>(val value: T, val error: Exception? = null)

private suspend fun <T> loadFeature(
    feature: ServerFeature,
    features: Set<ServerFeature>,
    empty: T,
    request: suspend () -> T,
): ServerFeatureResult<T> {
    if (feature !in features) return ServerFeatureResult(empty)
    return try {
        ServerFeatureResult(request())
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        ServerFeatureResult(empty, e)
    }
}
