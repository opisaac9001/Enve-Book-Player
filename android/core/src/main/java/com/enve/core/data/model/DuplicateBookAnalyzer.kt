package com.enve.core.data.model

data class DuplicateBookCluster(
    val id: String,
    val title: String,
    val reason: DuplicateMatchReason,
    val confidence: Int,
    val books: List<Book>,
)

enum class DuplicateMatchReason(val displayName: String) {
    ISBN("Matching ISBN"),
    EXACT_TITLE_AUTHOR("Same title and author"),
    EXACT_TITLE("Same title"),
    SIMILAR_TITLE_AUTHOR("Similar title and author"),
}

object DuplicateBookAnalyzer {
    fun findClusters(
        books: List<Book>,
        aggressiveness: MergeAggressiveness,
    ): List<DuplicateBookCluster> {
        val candidates = books
            .asSequence()
            .filter { it.title.isNotBlank() }
            .distinctBy { it.uniqueKey }
            .toList()

        if (candidates.size < 2) return emptyList()

        val parent = IntArray(candidates.size) { it }
        val matches = mutableListOf<PairMatch>()

        fun root(index: Int): Int {
            var current = index
            while (parent[current] != current) {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        fun union(left: Int, right: Int) {
            val leftRoot = root(left)
            val rightRoot = root(right)
            if (leftRoot != rightRoot) parent[rightRoot] = leftRoot
        }

        for (left in candidates.indices) {
            for (right in left + 1 until candidates.size) {
                val match = score(candidates[left], candidates[right]) ?: continue
                if (match.confidence >= aggressiveness.threshold) {
                    matches += match.copy(left = left, right = right)
                    union(left, right)
                }
            }
        }

        if (matches.isEmpty()) return emptyList()

        return candidates.indices
            .groupBy { root(it) }
            .values
            .asSequence()
            .filter { it.size > 1 }
            .mapNotNull { indexes ->
                val indexSet = indexes.toSet()
                val bestMatch = matches
                    .filter { it.left in indexSet && it.right in indexSet }
                    .maxWithOrNull(compareBy<PairMatch> { it.confidence }.thenBy { it.reason.ordinal })
                    ?: return@mapNotNull null
                val clusterBooks = indexes
                    .map { candidates[it] }
                    .sortedWith(
                        compareByDescending<Book> { it.lastReadTime }
                            .thenByDescending { it.addedOn }
                            .thenBy { it.title.lowercase() },
                    )
                DuplicateBookCluster(
                    id = clusterId(clusterBooks),
                    title = displayTitle(clusterBooks),
                    reason = bestMatch.reason,
                    confidence = bestMatch.confidence,
                    books = clusterBooks,
                )
            }
            .sortedWith(
                compareByDescending<DuplicateBookCluster> { it.confidence }
                    .thenBy { it.title.lowercase() },
            )
            .toList()
    }

    private data class PairMatch(
        val left: Int = -1,
        val right: Int = -1,
        val confidence: Int,
        val reason: DuplicateMatchReason,
    )

    private fun score(left: Book, right: Book): PairMatch? {
        return BookIdentity.duplicateScore(left, right)?.let {
            PairMatch(confidence = it.confidence, reason = it.reason)
        }
    }

    private fun displayTitle(books: List<Book>): String =
        books
            .map { it.title.trim() }
            .filter { it.isNotEmpty() }
            .minByOrNull { it.length }
            ?: "Duplicate Cluster"

    private fun clusterId(books: List<Book>): String {
        val raw = books.map { it.uniqueKey }.sorted().joinToString("|")
        return "duplicate:${raw.hashCode()}"
    }

}
