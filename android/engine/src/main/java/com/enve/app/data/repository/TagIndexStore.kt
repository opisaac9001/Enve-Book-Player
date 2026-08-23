package com.enve.app.data.repository

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import org.json.JSONArray
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class TagIndexStore @Inject constructor(
    private val annotationRepo: AnnotationRepository,
) {

    val tagsByUsage: Flow<List<String>> = annotationRepo.all().map { rows ->
        val counts = HashMap<String, Int>()
        rows.forEach { row -> parseTags(row.tagsJson).forEach { counts.merge(it, 1, Int::plus) } }
        counts.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key }).map { it.key }
    }

    fun suggest(all: List<String>, query: String, limit: Int = 8): List<String> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return all.take(limit)
        val prefix = all.filter { it.lowercase().startsWith(q) }
        val rest   = all.filter { !it.lowercase().startsWith(q) && it.lowercase().contains(q) }
        return (prefix + rest).take(limit)
    }

    private fun parseTags(json: String?): List<String> {
        if (json.isNullOrBlank()) return emptyList()
        return runCatching {
            val arr = JSONArray(json)
            buildList {
                for (i in 0 until arr.length()) {
                    arr.optString(i).takeIf { it.isNotBlank() }?.let(::add)
                }
            }
        }.getOrDefault(emptyList())
    }
}
