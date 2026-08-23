package com.enve.app.hearth

import com.enve.app.data.servertools.GrimmoryToolsRepository
import com.enve.app.data.servertools.KavitaToolsRepository
import com.enve.audiobookshelf.AudiobookshelfPersonalRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitHighlightQuery
import com.enve.engine.servertools.ServerAchievementSummary
import com.enve.engine.servertools.ServerBookmark
import com.enve.engine.servertools.ServerFeature
import com.enve.engine.servertools.ServerHighlight
import com.enve.engine.servertools.ServerHistoryEntry
import com.enve.engine.servertools.ServerStatGroup
import com.enve.engine.servertools.ServerToolsFacade
import com.enve.engine.servertools.ServerToolsTarget
import com.enve.silo.SiloPersonalRepository
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

private const val INSIGHTS_WINDOW_DAYS = 30

@Singleton
class ServerToolsFacadeImpl @Inject constructor(
    private val connectionRegistry: ConnectionRegistry,
    private val bookCache: BookCacheDao,
    private val bookOrbit: BookOrbitFacade,
    private val grimmoryTools: GrimmoryToolsRepository,
    private val kavitaTools: KavitaToolsRepository,
    private val absPersonal: AudiobookshelfPersonalRepository,
    private val siloPersonal: SiloPersonalRepository,
) : ServerToolsFacade {

    override val targets: Flow<List<ServerToolsTarget>> = connectionRegistry.connections.map { connections ->
        connections.map { connection ->
            ServerToolsTarget(
                connectionId = connection.id,
                source = connection.source,
                name = connection.name.ifBlank { connection.serverUrl },
                serverUrl = connection.serverUrl,
                enabled = connection.enabled,
                isAdmin = connection.isAdmin,
                features = featuresFor(connection.source),
            )
        }
    }

    override suspend fun stats(connectionId: String): List<ServerStatGroup> =
        when (sourceOf(connectionId)) {
            BookSource.BOOKORBIT -> bookOrbit.insights(connectionId, INSIGHTS_WINDOW_DAYS)
                ?.let(ServerToolsMapping::bookOrbitStats)
                .orEmpty()
            BookSource.GRIMMORY -> scoped(connectionId) {
                grimmoryTools.stats().getOrNull()?.let(ServerToolsMapping::grimmoryStats).orEmpty()
            }
            BookSource.KAVITA -> scoped(connectionId) {
                kavitaTools.stats().getOrNull()?.let(ServerToolsMapping::kavitaStats).orEmpty()
            }
            BookSource.AUDIOBOOKSHELF -> scoped(connectionId) {
                absPersonal.listeningStats().getOrNull()?.let(ServerToolsMapping::absStats).orEmpty()
            }
            else -> emptyList()
        }

    override suspend fun achievements(connectionId: String): ServerAchievementSummary? =
        when (sourceOf(connectionId)) {
            BookSource.BOOKORBIT -> bookOrbit.achievements(connectionId)
                ?.let(ServerToolsMapping::bookOrbitAchievements)
                ?.takeIf { it.available > 0 }
            else -> null
        }

    override suspend fun highlights(connectionId: String, limit: Int): List<ServerHighlight> =
        when (sourceOf(connectionId)) {
            BookSource.BOOKORBIT -> bookOrbit.highlights(connectionId, BookOrbitHighlightQuery())
                ?.let(ServerToolsMapping::bookOrbitHighlights)
                .orEmpty()
                .take(limit)
            BookSource.GRIMMORY -> scoped(connectionId) {
                grimmoryTools.notes(limit).getOrNull()?.let(ServerToolsMapping::grimmoryHighlights).orEmpty()
            }
            BookSource.KAVITA -> scoped(connectionId) {
                kavitaTools.annotations(limit).getOrNull()?.let(ServerToolsMapping::kavitaHighlights).orEmpty()
            }
            else -> emptyList()
        }

    override suspend fun bookmarks(connectionId: String, limit: Int): List<ServerBookmark> =
        when (sourceOf(connectionId)) {
            BookSource.AUDIOBOOKSHELF -> scoped(connectionId) {
                val bookmarks = absPersonal.bookmarks().getOrNull().orEmpty().take(limit)
                val titles = bookmarks
                    .map { it.libraryItemId }
                    .distinct()
                    .mapNotNull { itemId ->
                        bookCache.getByIdAndConnection(itemId, connectionId)?.let { itemId to it.title }
                    }
                    .toMap()
                ServerToolsMapping.absBookmarks(bookmarks, titles)
            }
            else -> emptyList()
        }

    override suspend fun history(connectionId: String, limit: Int): List<ServerHistoryEntry> =
        when (sourceOf(connectionId)) {
            BookSource.SILO -> scoped(connectionId) {
                siloPersonal.history(limit).getOrNull()?.let(ServerToolsMapping::siloHistory).orEmpty()
            }
            else -> emptyList()
        }

    override suspend fun relatedBooks(book: Book, limit: Int): List<Book> {
        val connectionId = book.connectionId ?: return emptyList()
        val ids = when (book.source) {
            BookSource.GRIMMORY -> scoped(connectionId) {
                grimmoryTools.recommendedBookIds(book.id, limit).getOrNull()
            }
            BookSource.SILO -> scoped(connectionId) {
                siloPersonal.similar(book.id, limit).getOrNull()?.map { it.contentId }
            }
            else -> null
        }.orEmpty()
        return ids
            .mapNotNull { id -> bookCache.getByIdAndConnection(id, connectionId)?.toBook() }
            .filterNot { it.uniqueKey == book.uniqueKey }
            .take(limit)
    }

    private fun sourceOf(connectionId: String): BookSource? =
        connectionRegistry.getConnectionsSync().firstOrNull { it.id == connectionId }?.source

    private suspend fun <T> scoped(connectionId: String, block: suspend () -> T): T =
        withContext(ConnectionScope.asContextElement(connectionId)) { block() }

    private fun featuresFor(source: BookSource): Set<ServerFeature> = when (source) {
        BookSource.BOOKORBIT -> setOf(ServerFeature.STATS, ServerFeature.ACHIEVEMENTS, ServerFeature.HIGHLIGHTS)
        BookSource.GRIMMORY -> setOf(ServerFeature.STATS, ServerFeature.HIGHLIGHTS, ServerFeature.RECOMMENDATIONS)
        BookSource.KAVITA -> setOf(ServerFeature.STATS, ServerFeature.HIGHLIGHTS)
        BookSource.AUDIOBOOKSHELF -> setOf(ServerFeature.STATS, ServerFeature.BOOKMARKS)
        BookSource.SILO -> setOf(ServerFeature.HISTORY, ServerFeature.RECOMMENDATIONS)
        else -> emptySet()
    }
}
