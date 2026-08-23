package com.enve.app.data.vocab

import java.io.File
import java.io.IOException
import java.util.zip.GZIPInputStream

class StarDictDictionary(private val ifoFile: File) {

    data class Entry(val word: String, val offset: Long, val size: Int)

    data class Definition(
        val headword: String,
        val definition: String,
        val type: Char,

        val matchedForm: String?,
    )

    val directory: File = ifoFile.parentFile ?: File(".")
    val baseName: String = ifoFile.nameWithoutExtension

    val meta = mutableMapOf<String, String>()
    val entries = mutableListOf<Entry>()
    private val normIndex = HashMap<String, MutableList<Int>>()
    private val synIndex = HashMap<String, MutableList<Int>>()
    private var dictBuffer: ByteArray? = null
    private var loaded = false

    val displayName: String get() = meta["bookname"] ?: baseName
    val wordCount: Int get() = meta["wordcount"]?.toIntOrNull() ?: entries.size

    @Throws(IOException::class)
    fun load() {
        if (loaded) return
        parseIfo()
        parseIdx()
        buildNormIndex()
        parseSyn()
        loaded = true
    }

    fun lookup(word: String): List<Definition> {
        if (!loaded) return emptyList()
        val key = StarDictMorphology.normalize(word)
        synIndex[key]?.takeIf { it.isNotEmpty() }?.let {
            return it.mapNotNull { idx -> readEntry(idx, matchedForm = null) }
        }
        normIndex[key]?.takeIf { it.isNotEmpty() }?.let {
            return it.mapNotNull { idx -> readEntry(idx, matchedForm = null) }
        }
        return emptyList()
    }

    fun lookupFuzzy(word: String): List<Definition> {
        if (!loaded) return emptyList()
        for (candidate in StarDictMorphology.candidates(word)) {
            val key = StarDictMorphology.normalize(candidate)
            synIndex[key]?.takeIf { it.isNotEmpty() }?.let {
                return it.mapNotNull { idx -> readEntry(idx, matchedForm = candidate) }
            }
            normIndex[key]?.takeIf { it.isNotEmpty() }?.let {
                return it.mapNotNull { idx -> readEntry(idx, matchedForm = candidate) }
            }
        }
        return emptyList()
    }

    fun suggest(rawPrefix: String, limit: Int = 10): List<String> {
        if (!loaded) return emptyList()
        val prefix = StarDictMorphology.normalize(rawPrefix)
        val results = mutableListOf<String>()
        for (entry in entries) {
            if (StarDictMorphology.normalize(entry.word).startsWith(prefix)) {
                results.add(entry.word)
                if (results.size >= limit) break
            }
        }
        return results
    }

    private fun parseIfo() {
        for (line in ifoFile.readLines(Charsets.UTF_8)) {
            val eq = line.indexOf('=')
            if (eq <= 0) continue
            meta[line.substring(0, eq).trim()] = line.substring(eq + 1).trim()
        }
    }

    private fun parseIdx() {
        val idxFile = File(directory, "$baseName.idx")
        if (!idxFile.exists()) throw IOException("missing $baseName.idx")
        val buf = idxFile.readBytes()
        val use64 = (meta["idxoffsetbits"]?.toIntOrNull() ?: 32) == 64
        val offsetBytes = if (use64) 8 else 4
        var pos = 0
        val count = buf.size

        while (pos < count) {
            var end = pos
            while (end < count && buf[end] != 0.toByte()) end++
            if (end >= count) break
            val word = String(buf, pos, end - pos, Charsets.UTF_8)
            pos = end + 1
            if (pos + offsetBytes + 4 > count) break

            val offset: Long = if (use64) {
                val hi = readUInt32BE(buf, pos)
                val lo = readUInt32BE(buf, pos + 4)
                (hi shl 32) or lo
            } else {
                readUInt32BE(buf, pos)
            }
            val size = readUInt32BE(buf, pos + offsetBytes).toInt()
            pos += offsetBytes + 4
            entries.add(Entry(word, offset, size))
        }
    }

    private fun buildNormIndex() {
        normIndex.clear()
        for ((i, entry) in entries.withIndex()) {
            val key = StarDictMorphology.normalize(entry.word)
            normIndex.getOrPut(key) { mutableListOf() }.add(i)
        }
    }

    private fun parseSyn() {
        val synFile = File(directory, "$baseName.syn")
        if (!synFile.exists()) return
        val buf = synFile.readBytes()
        var pos = 0
        val count = buf.size
        while (pos < count) {
            var end = pos
            while (end < count && buf[end] != 0.toByte()) end++
            if (end >= count) break
            val word = String(buf, pos, end - pos, Charsets.UTF_8)
            pos = end + 1
            if (pos + 4 > count) break
            val idx = readUInt32BE(buf, pos).toInt()
            pos += 4
            if (idx < 0 || idx >= entries.size) continue
            val key = StarDictMorphology.normalize(word)
            synIndex.getOrPut(key) { mutableListOf() }.add(idx)
        }
    }

    @Throws(IOException::class)
    private fun loadDict(): ByteArray {
        dictBuffer?.let { return it }
        val dictFile = File(directory, "$baseName.dict")
        val dictDzFile = File(directory, "$baseName.dict.dz")
        val data: ByteArray = when {
            dictDzFile.exists() -> {
                GZIPInputStream(dictDzFile.inputStream()).use { it.readBytes() }
            }
            dictFile.exists() -> dictFile.readBytes()
            else -> throw IOException("no .dict or .dict.dz for $baseName")
        }
        dictBuffer = data
        return data
    }

    private fun readEntry(index: Int, matchedForm: String?): Definition? {
        if (index < 0 || index >= entries.size) return null
        val entry = entries[index]
        val buf = runCatching { loadDict() }.getOrNull() ?: return null
        val start = entry.offset.toInt()
        val end = start + entry.size
        if (end > buf.size) return null
        val def = String(buf, start, entry.size, Charsets.UTF_8)
        val type = (meta["sametypesequence"] ?: "m").firstOrNull() ?: 'm'
        return Definition(headword = entry.word, definition = def, type = type, matchedForm = matchedForm)
    }

    private fun readUInt32BE(buf: ByteArray, offset: Int): Long {
        val b0 = (buf[offset].toInt() and 0xFF).toLong()
        val b1 = (buf[offset + 1].toInt() and 0xFF).toLong()
        val b2 = (buf[offset + 2].toInt() and 0xFF).toLong()
        val b3 = (buf[offset + 3].toInt() and 0xFF).toLong()
        return (b0 shl 24) or (b1 shl 16) or (b2 shl 8) or b3
    }
}
