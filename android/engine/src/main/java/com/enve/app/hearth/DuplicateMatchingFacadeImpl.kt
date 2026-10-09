package com.enve.app.hearth

import com.enve.app.data.duplicates.DuplicateGroupStore
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.DuplicateBookAnalyzer
import com.enve.core.data.model.DuplicateBookCluster
import com.enve.engine.library.LibraryFacade
import com.enve.engine.matching.DuplicateMatchingFacade
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flowOn
import javax.inject.Inject

class DuplicateMatchingFacadeImpl @Inject constructor(
    library: LibraryFacade,
    prefs: PreferencesManager,
    private val groups: DuplicateGroupStore,
) : DuplicateMatchingFacade {
    override val grouped = groups.groups
    override val clusters: Flow<List<DuplicateBookCluster>> = combine(
        library.allBooks,
        prefs.mergeAggressiveness,
    ) { books, aggressiveness -> DuplicateBookAnalyzer.findClusters(books, aggressiveness) }
        .flowOn(Dispatchers.Default)

    override suspend fun merge(cluster: DuplicateBookCluster, keepBookKey: String): Int =
        groups.group(cluster.books.map { it.uniqueKey }, keepBookKey)

    override suspend fun unmerge(keepBookKey: String): Int = groups.ungroup(keepBookKey)
}
