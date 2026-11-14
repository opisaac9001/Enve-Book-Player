package com.enve.app.data.fileimport

import com.enve.core.data.importing.AudiobookFileGrouping
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID

enum class ImportedFileKind { AUDIO, EBOOK }

enum class AudioGrouping { AUTOMATIC, SINGLE_BOOK, SEPARATE }

data class ImportFolder(val key: String, val name: String)

class ImportFile(
    val name: String,
    val sizeBytes: Long,
    val identity: String?,
    val folder: ImportFolder? = null,
    val open: () -> InputStream,
) {
    val extension: String get() = ImportableFormats.extension(name)
    val kind: ImportedFileKind? get() = ImportableFormats.kind(name)
}

sealed interface ImportItem {
    val title: String
    val files: List<ImportFile>

    class Document(val file: ImportFile) : ImportItem {
        override val title: String get() = ImportableFormats.stem(file.name)
        override val files: List<ImportFile> get() = listOf(file)
    }

    class Audiobook(override val title: String, val tracks: List<ImportFile>) : ImportItem {
        override val files: List<ImportFile> get() = tracks
    }
}

object ImportableFormats {
    val audioExtensions: Set<String> = setOf("mp3", "m4b", "m4a", "mp4", "aac", "ogg", "oga", "opus", "flac", "wav")
    val ebookExtensions: Set<String> = setOf("epub", "kepub", "pdf", "azw3", "cbz", "cbr")
    val zipContainerExtensions: Set<String> = setOf("epub", "kepub", "cbz")

    fun kind(fileName: String): ImportedFileKind? = when (extension(fileName)) {
        in audioExtensions -> ImportedFileKind.AUDIO
        in ebookExtensions -> ImportedFileKind.EBOOK
        else -> null
    }

    fun extension(fileName: String): String = fileName.substringAfterLast('.', "").lowercase()

    fun stem(fileName: String): String = fileName.substringBeforeLast('.', fileName).ifBlank { fileName }
}

object ImportPlanner {
    const val MAX_FILES = 500

    fun plan(files: List<ImportFile>, grouping: AudioGrouping): List<ImportItem> {
        require(files.size <= MAX_FILES) { "Choose up to $MAX_FILES files at a time." }
        val seen = mutableSetOf<String>()
        val supported = files.filter { file -> file.kind != null && file.identity?.let(seen::add) != false }
        val documents = supported.filter { it.kind == ImportedFileKind.EBOOK }.map(ImportItem::Document)
        val audiobooks = supported.filter { it.kind == ImportedFileKind.AUDIO }
            .groupBy { it.folder?.key }
            .values
            .flatMap { folderFiles -> audiobooks(folderFiles, grouping, folderFiles.first().folder?.name) }
        return documents + audiobooks
    }

    fun bookId(item: ImportItem): String {
        val identities = item.files.map { it.identity }
        val seed = if (identities.all { it != null }) identities.joinToString("\n") else UUID.randomUUID().toString()
        val kind = if (item is ImportItem.Audiobook) "audio" else "ebook"
        val digest = MessageDigest.getInstance("SHA-256").digest("$kind\n$seed".toByteArray())
        return "local-file-" + digest.joinToString("") { "%02x".format(it) }.take(40)
    }

    private fun audiobooks(audio: List<ImportFile>, grouping: AudioGrouping, folderName: String?): List<ImportItem.Audiobook> {
        val folderTitle = folderName?.trim()?.takeIf { it.isNotEmpty() }
        return when (grouping) {
            AudioGrouping.SEPARATE -> audio.map { ImportItem.Audiobook(ImportableFormats.stem(it.name), listOf(it)) }
            AudioGrouping.SINGLE_BOOK -> {
                val ordered = AudiobookFileGrouping.sorted(audio, ImportFile::name)
                listOf(ImportItem.Audiobook(groupTitle(ordered, folderTitle), ordered))
            }
            AudioGrouping.AUTOMATIC -> {
                val groups = AudiobookFileGrouping.groups(
                    files = audio,
                    name = ImportFile::name,
                    sizeBytes = { it.sizeBytes.coerceAtLeast(0L) },
                )
                groups.map { group ->
                    val title = when {
                        group.size == 1 -> ImportableFormats.stem(group.single().name)
                        groups.size == 1 -> groupTitle(group, folderTitle)
                        else -> groupTitle(group, null)
                    }
                    ImportItem.Audiobook(title, group)
                }
            }
        }
    }

    private fun groupTitle(group: List<ImportFile>, folderTitle: String?): String =
        folderTitle ?: AudiobookFileGrouping.inferredTitle(group.first().name)
}
