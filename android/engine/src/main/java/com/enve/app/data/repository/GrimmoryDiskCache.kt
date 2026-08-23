package com.enve.app.data.repository

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GrimmoryDiskCache @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val root: File by lazy {
        File(context.cacheDir, "bookloore").apply { mkdirs() }
    }

    suspend fun read(key: String, ttlMs: Long): CachedEntry? = withContext(Dispatchers.IO) {
        val file = fileFor(key)
        if (!file.exists() || file.length() == 0L) return@withContext null
        val text = runCatching { file.readText() }.getOrNull() ?: return@withContext null
        val savedAt = parseSavedAt(text) ?: return@withContext null
        if (System.currentTimeMillis() - savedAt > ttlMs) return@withContext null
        val payload = extractPayload(text) ?: return@withContext null
        CachedEntry(savedAt, payload)
    }

    suspend fun write(key: String, payloadJson: String) = withContext(Dispatchers.IO) {
        runCatching {
            val savedAt = System.currentTimeMillis()
            fileFor(key).writeText("""{"savedAt":$savedAt,"payload":$payloadJson}""")
        }
    }

    suspend fun invalidate(prefix: String? = null) = withContext(Dispatchers.IO) {
        runCatching {
            if (prefix == null) {
                root.listFiles()?.forEach { it.delete() }
            } else {
                val targetHash = sha1(prefix)
                root.listFiles { f -> f.name.startsWith(targetHash) }?.forEach { it.delete() }
            }
        }
    }

    private fun fileFor(key: String): File = File(root, "${sha1(key)}.json")

    private fun sha1(input: String): String {
        val md = MessageDigest.getInstance("SHA-1")
        return md.digest(input.toByteArray()).joinToString("") { "%02x".format(it) }
    }

    private fun parseSavedAt(text: String): Long? {
        val idx = text.indexOf("\"savedAt\":")
        if (idx < 0) return null
        val start = idx + "\"savedAt\":".length
        val end = text.indexOf(',', startIndex = start).takeIf { it > 0 } ?: return null
        return text.substring(start, end).trim().toLongOrNull()
    }

    private fun extractPayload(text: String): String? {
        val key = "\"payload\":"
        val idx = text.indexOf(key)
        if (idx < 0) return null
        val start = idx + key.length

        val end = text.lastIndexOf('}').takeIf { it > start } ?: return null
        return text.substring(start, end).trim()
    }

    data class CachedEntry(val savedAt: Long, val payloadJson: String)
}
