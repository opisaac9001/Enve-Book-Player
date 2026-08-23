package com.enve.app.data.vocab

import android.content.Context
import android.net.Uri
import android.util.Log
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class InstalledDictionariesStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {

    data class InstalledDictionary(
        val slug: String,
        val displayName: String,
        val wordCount: Int,
        val folder: File,
    )

    private val rootDir: File = File(context.filesDir, "StarDict").apply { mkdirs() }
    private val cache = mutableMapOf<String, StarDictDictionary>()

    private val _dictionaries = MutableStateFlow<List<InstalledDictionary>>(emptyList())
    val dictionaries: StateFlow<List<InstalledDictionary>> = _dictionaries.asStateFlow()

    init { refresh() }

    fun refresh() {
        _dictionaries.value = scan()
    }

    fun lookup(word: String): StarDictDictionary.Definition? {
        for (entry in _dictionaries.value) {
            val dict = load(entry.slug) ?: continue
            val hits = dict.lookupFuzzy(word)
            hits.firstOrNull()?.let { return it }
        }
        return null
    }

    fun delete(slug: String) {
        val target = File(rootDir, slug)
        if (target.exists()) target.deleteRecursively()
        cache.remove(slug)
        refresh()
    }

    fun installFromFolder(folderUri: Uri): InstalledDictionary {
        val tree = androidx.documentfile.provider.DocumentFile.fromTreeUri(context, folderUri)
            ?: throw InstallException("Could not open selected folder")
        val files = tree.listFiles().filter { it.isFile }
        val ifo = files.firstOrNull { (it.name ?: "").lowercase().endsWith(".ifo") }
            ?: throw InstallException("No .ifo file found in the selected folder.")

        val slug = freshSlug(preferred = (ifo.name ?: "dictionary").substringBeforeLast('.'))
        val dest = File(rootDir, slug).apply { mkdirs() }

        try {
            for (entry in files) {
                val name = entry.name ?: continue
                val lower = name.lowercase()
                val isRelevant = lower.endsWith(".ifo") || lower.endsWith(".idx") ||
                    lower.endsWith(".dict") || lower.endsWith(".dict.dz") ||
                    lower.endsWith(".dz") || lower.endsWith(".syn")
                if (!isRelevant) continue
                val outFile = File(dest, name)
                context.contentResolver.openInputStream(entry.uri)?.use { input ->
                    outFile.outputStream().use { output -> input.copyTo(output) }
                } ?: throw InstallException("Could not read \"$name\".")
            }
        } catch (e: Exception) {
            dest.deleteRecursively()
            throw e
        }

        Log.i(TAG, "Installed StarDict dictionary: $slug")
        refresh()
        return _dictionaries.value.firstOrNull { it.slug == slug }
            ?: throw InstallException("Files were copied but the dictionary metadata could not be read.")
    }

    class InstallException(message: String) : Exception(message)

    private fun load(slug: String): StarDictDictionary? {
        cache[slug]?.let { return it }
        val folder = File(rootDir, slug)
        val ifo = folder.listFiles()?.firstOrNull { it.name.lowercase().endsWith(".ifo") } ?: return null
        val dict = StarDictDictionary(ifo)
        try {
            dict.load()
        } catch (e: Exception) {
            Log.w(TAG, "StarDict load failed for $slug: ${e.message}")
            return null
        }
        cache[slug] = dict
        return dict
    }

    private fun scan(): List<InstalledDictionary> {
        val subdirs = rootDir.listFiles()?.filter { it.isDirectory } ?: emptyList()
        return subdirs.mapNotNull { folder ->
            val ifo = folder.listFiles()?.firstOrNull { it.name.lowercase().endsWith(".ifo") }
                ?: return@mapNotNull null
            val dict = StarDictDictionary(ifo)
            runCatching { dict.load() }
            InstalledDictionary(
                slug = folder.name,
                displayName = dict.displayName,
                wordCount = dict.wordCount,
                folder = folder,
            )
        }.sortedBy { it.displayName.lowercase() }
    }

    private fun freshSlug(preferred: String): String {
        val sanitized = preferred.lowercase()
            .split(Regex("[^a-z0-9]+"))
            .filter { it.isNotEmpty() }
            .joinToString("-")
        val base = sanitized.ifEmpty { "dictionary" }
        var candidate = base
        var n = 1
        while (File(rootDir, candidate).exists()) {
            n++
            candidate = "$base-$n"
        }
        return candidate
    }

    companion object { private const val TAG = "InstalledDictionaries" }
}
