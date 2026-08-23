package com.enve.engine.servertools

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.flow.Flow

enum class ServerFeature {
    STATS,
    ACHIEVEMENTS,
    HIGHLIGHTS,
    BOOKMARKS,
    HISTORY,
    RECOMMENDATIONS,
}

data class ServerToolsTarget(
    val connectionId: String,
    val source: BookSource,
    val name: String,
    val serverUrl: String,
    val enabled: Boolean,
    val isAdmin: Boolean,
    val features: Set<ServerFeature>,
)

data class ServerStat(
    val label: String,
    val value: String,
    val detail: String? = null,
)

data class ServerStatGroup(
    val title: String,
    val stats: List<ServerStat>,
)

data class ServerAchievement(
    val key: String,
    val name: String,
    val description: String,
    val earned: Boolean,
    val awardedAtMs: Long?,
    val progress: Double?,
    val threshold: Double?,
)

data class ServerAchievementSummary(
    val earned: Int,
    val available: Int,
    val achievements: List<ServerAchievement>,
)

data class ServerHighlight(
    val id: String,
    val bookTitle: String?,
    val author: String?,
    val chapterTitle: String?,
    val text: String,
    val note: String?,
    val createdAtMs: Long?,
)

data class ServerBookmark(
    val id: String,
    val bookTitle: String?,
    val label: String?,
    val positionSeconds: Long?,
    val createdAtMs: Long?,
)

data class ServerHistoryEntry(
    val id: String,
    val title: String,
    val subtitle: String?,
    val occurredAtMs: Long?,
    val durationSeconds: Long?,
)

interface ServerToolsFacade {
    val targets: Flow<List<ServerToolsTarget>>

    suspend fun stats(connectionId: String): List<ServerStatGroup>

    suspend fun achievements(connectionId: String): ServerAchievementSummary?

    suspend fun highlights(connectionId: String, limit: Int): List<ServerHighlight>

    suspend fun bookmarks(connectionId: String, limit: Int): List<ServerBookmark>

    suspend fun history(connectionId: String, limit: Int): List<ServerHistoryEntry>

    suspend fun relatedBooks(book: Book, limit: Int): List<Book>
}
