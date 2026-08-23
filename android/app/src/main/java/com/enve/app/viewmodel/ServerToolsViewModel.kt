package com.enve.app.viewmodel

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.servertools.ServerAchievementSummary
import com.enve.engine.servertools.ServerBookmark
import com.enve.engine.servertools.ServerFeature
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
    val unreachable: Boolean = false,
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
            loaded.update { it.copy(loading = true, unreachable = false) }
            val features = serverTools.targets.first()
                .firstOrNull { it.connectionId == connectionId }
                ?.features
                .orEmpty()
            val result = try {
                coroutineScope {
                    val stats = async { if (ServerFeature.STATS in features) serverTools.stats(connectionId) else emptyList() }
                    val achievements = async {
                        if (ServerFeature.ACHIEVEMENTS in features) serverTools.achievements(connectionId) else null
                    }
                    val highlights = async {
                        if (ServerFeature.HIGHLIGHTS in features) serverTools.highlights(connectionId, HIGHLIGHT_LIMIT) else emptyList()
                    }
                    val bookmarks = async {
                        if (ServerFeature.BOOKMARKS in features) serverTools.bookmarks(connectionId, BOOKMARK_LIMIT) else emptyList()
                    }
                    val history = async {
                        if (ServerFeature.HISTORY in features) serverTools.history(connectionId, HISTORY_LIMIT) else emptyList()
                    }
                    ServerToolsState(
                        loading = false,
                        stats = stats.await(),
                        achievements = achievements.await(),
                        highlights = highlights.await(),
                        bookmarks = bookmarks.await(),
                        history = history.await(),
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                ServerToolsState(loading = false, unreachable = true)
            }
            loaded.value = result
        }
    }
}
