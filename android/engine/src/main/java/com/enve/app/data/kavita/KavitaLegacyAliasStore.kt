package com.enve.app.data.kavita

import com.enve.core.data.local.ProfileStorageLocations
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
private data class KavitaLegacyAliases(
    val connections: Map<String, Map<Int, Int>> = emptyMap(),
)

@Singleton
class KavitaLegacyAliasStore @Inject constructor(locations: ProfileStorageLocations) {
    private val file = File(locations.filesDirectory, "kavita/legacy-issue-aliases.json")
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()
    private var loaded: Map<String, Map<Int, Int>>? = null

    suspend fun pin(connectionKey: String, firstChapterBySeries: Map<Int, Int?>): Map<Int, Int> = mutex.withLock {
        withContext(Dispatchers.IO) {
            val all = aliases()
            val key = hash(connectionKey)
            val existing = all[key].orEmpty()
            val additions = firstChapterBySeries.entries
                .mapNotNull { (seriesId, chapterId) -> chapterId?.takeIf { seriesId !in existing }?.let { seriesId to it } }
                .toMap()
            val connection = if (additions.isEmpty()) existing else (existing + additions).also { updated ->
                val next = all + (key to updated)
                persist(next)
                loaded = next
            }
            firstChapterBySeries.keys.mapNotNull { seriesId -> connection[seriesId]?.let { seriesId to it } }.toMap()
        }
    }

    private fun aliases(): Map<String, Map<Int, Int>> = loaded ?: (
        if (file.exists()) json.decodeFromString(KavitaLegacyAliases.serializer(), file.readText()).connections else emptyMap()
    ).also { loaded = it }

    private fun persist(all: Map<String, Map<Int, Int>>) {
        file.parentFile?.mkdirs()
        val staging = File(file.parentFile, "${file.name}.tmp")
        staging.writeText(json.encodeToString(KavitaLegacyAliases.serializer(), KavitaLegacyAliases(all)))
        check(staging.renameTo(file)) { "Kavita alias store could not be saved" }
    }

    private fun hash(connectionKey: String): String =
        MessageDigest.getInstance("SHA-256").digest(connectionKey.toByteArray())
            .joinToString("") { "%02x".format(it) }
}
