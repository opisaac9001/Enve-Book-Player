package com.enve.app.data.vocab

import android.content.Context
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class DefinitionLookupService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val installedDictionaries: InstalledDictionariesStore,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val memoryCache = mutableMapOf<String, String?>()
    private val inflight = mutableMapOf<String, Deferred<String?>>()
    private val mutex = Mutex()

    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(8, TimeUnit.SECONDS)
            .build()
    }

    private val json = Json { ignoreUnknownKeys = true }

    private val cacheRoot: File by lazy {
        File(context.filesDir, "DefinitionCache").apply { mkdirs() }
    }

    suspend fun definition(rawWord: String, language: String? = null): String? {
        val word = normalize(rawWord)
        if (word.isEmpty()) return null
        val lang = languageTag(language)
        val key = "$lang:$word"

        mutex.withLock {
            memoryCache[key]?.let { return it }
            inflight[key]?.let { return it.await() }
        }

        formatStarDict(installedDictionaries.lookup(word))?.let { result ->
            mutex.withLock { memoryCache[key] = result }
            writeDisk(lang, word, result)
            return result
        }

        val onDisk = readDisk(lang, word)
        if (onDisk != null) {
            mutex.withLock { memoryCache[key] = onDisk.value }
            return onDisk.value
        }

        val deferred = scope.async {
            fetchOnline(word, lang)
        }
        mutex.withLock { inflight[key] = deferred }
        val result = try { deferred.await() } finally {
            mutex.withLock { inflight.remove(key) }
        }
        mutex.withLock { memoryCache[key] = result }
        writeDisk(lang, word, result)
        return result
    }

    fun cached(rawWord: String, language: String? = null): String? {
        val word = normalize(rawWord)
        val lang = languageTag(language)
        memoryCache["$lang:$word"]?.let { return it }
        return readDisk(lang, word)?.value
    }

    private fun normalize(s: String): String = s.trim().lowercase()

    private fun languageTag(raw: String?): String =
        raw?.take(2)?.lowercase()?.takeIf { it.isNotEmpty() } ?: "en"

    private data class DiskResult(val value: String?)

    private fun cacheFile(lang: String, word: String): File {
        val dir = File(cacheRoot, lang).apply { mkdirs() }
        val safe = word.replace('/', '_')
        return File(dir, "$safe.txt")
    }

    private fun readDisk(lang: String, word: String): DiskResult? {
        val file = cacheFile(lang, word)
        if (!file.exists()) return null
        val bytes = runCatching { file.readBytes() }.getOrDefault(ByteArray(0))
        return if (bytes.isEmpty()) DiskResult(null) else DiskResult(String(bytes))
    }

    private fun writeDisk(lang: String, word: String, definition: String?) {
        runCatching {
            cacheFile(lang, word).writeBytes((definition ?: "").toByteArray())
        }
    }

    @Serializable
    private data class ApiEntry(val meanings: List<ApiMeaning> = emptyList())

    @Serializable
    private data class ApiMeaning(
        val partOfSpeech: String? = null,
        val definitions: List<ApiDefinition> = emptyList(),
    )

    @Serializable
    private data class ApiDefinition(val definition: String? = null)

    private suspend fun fetchOnline(word: String, lang: String): String? = withContext(Dispatchers.IO) {
        val url = "https://api.dictionaryapi.dev/api/v2/entries/$lang/${java.net.URLEncoder.encode(word, "UTF-8")}"
        val request = Request.Builder().url(url).header("Accept", "application/json").build()
        try {
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val body = response.body?.string() ?: return@use null
                val entries = json.decodeFromString<List<ApiEntry>>(body)
                format(entries)
            }
        } catch (e: Exception) {
            Log.w(TAG, "DefinitionLookup fetch failed for '$word': ${e.message}")
            null
        }
    }

    private fun formatStarDict(hit: StarDictDictionary.Definition?): String? {
        if (hit == null || hit.definition.isEmpty()) return null
        val cleaned = when (hit.type) {
            'h', 'g' -> stripMarkup(hit.definition)
            else -> hit.definition
        }
        return cleaned.trim().takeIf { it.isNotEmpty() }
    }

    private fun stripMarkup(s: String): String {
        val tagless = s.replace(Regex("<[^>]+>"), "")
        val decoded = tagless
            .replace("&amp;", "&")
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&quot;", "\"")
            .replace("&apos;", "'")
            .replace("&#39;", "'")
            .replace("&nbsp;", " ")
        return decoded.replace(Regex("\\s+"), " ")
    }

    private fun format(entries: List<ApiEntry>): String? {
        val lines = mutableListOf<String>()
        val seen = mutableSetOf<String>()
        outer@ for (entry in entries) {
            for (meaning in entry.meanings) {
                val first = meaning.definitions.firstOrNull()?.definition?.trim().orEmpty()
                if (first.isEmpty()) continue
                val pos = meaning.partOfSpeech?.trim().orEmpty()
                val line = if (pos.isEmpty()) first else "($pos) $first"
                if (seen.add(line)) {
                    lines.add(line)
                    if (lines.size >= 3) break@outer
                }
            }
        }
        return lines.takeIf { it.isNotEmpty() }?.joinToString("\n")
    }

    companion object { private const val TAG = "DefinitionLookup" }
}
