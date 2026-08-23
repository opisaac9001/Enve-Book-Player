package com.enve.app.data.librarian

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.util.Base64
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class EbookContextStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val root = File(context.filesDir, "enve-librarian/ebook-contexts")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    suspend fun load(bookStableId: String): EbookContext? = withContext(Dispatchers.IO) {
        val directory = directory(bookStableId)
        val manifestFile = File(directory, "manifest.json")
        val chunksFile = File(directory, "chunks.json")
        if (!manifestFile.exists() || !chunksFile.exists()) return@withContext null
        runCatching {
            EbookContext(
                manifest = json.decodeFromString(EbookContextManifest.serializer(), manifestFile.readText()),
                chunks = json.decodeFromString(ListSerializer(EbookContextChunk.serializer()), chunksFile.readText())
                    .sortedBy { it.startProgress },
            )
        }.getOrNull()
    }

    suspend fun save(bookStableId: String, chunks: List<EbookContextChunk>) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val existing = load(bookStableId)?.manifest
        val manifest = EbookContextManifest(
            bookStableId = bookStableId,
            status = BookContextStatus.READY,
            createdAtEpochMs = existing?.createdAtEpochMs ?: now,
            updatedAtEpochMs = now,
            chunkCount = chunks.size,
            failureMessage = null,
        )
        write(manifest, chunks.sortedBy { it.startProgress }, bookStableId)
    }

    suspend fun markGenerating(bookStableId: String) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val existing = load(bookStableId)
        val manifest = EbookContextManifest(
            bookStableId = bookStableId,
            status = BookContextStatus.GENERATING,
            createdAtEpochMs = existing?.manifest?.createdAtEpochMs ?: now,
            updatedAtEpochMs = now,
            chunkCount = existing?.chunks?.size ?: 0,
            failureMessage = null,
        )
        write(manifest, existing?.chunks.orEmpty(), bookStableId)
    }

    suspend fun markFailed(bookStableId: String, message: String) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val existing = load(bookStableId)
        val manifest = EbookContextManifest(
            bookStableId = bookStableId,
            status = BookContextStatus.FAILED,
            createdAtEpochMs = existing?.manifest?.createdAtEpochMs ?: now,
            updatedAtEpochMs = now,
            chunkCount = existing?.chunks?.size ?: 0,
            failureMessage = message,
        )
        write(manifest, existing?.chunks.orEmpty(), bookStableId)
    }

    private fun write(manifest: EbookContextManifest, chunks: List<EbookContextChunk>, bookStableId: String) {
        val directory = directory(bookStableId).also { it.mkdirs() }
        File(directory, "manifest.json").writeText(json.encodeToString(EbookContextManifest.serializer(), manifest))
        File(directory, "chunks.json").writeText(json.encodeToString(ListSerializer(EbookContextChunk.serializer()), chunks))
    }

    private fun directory(bookStableId: String): File = File(root, safeName(bookStableId))
}

@Singleton
class LibrarianConversationStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val root = File(context.filesDir, "enve-librarian/conversations")
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    suspend fun load(bookStableId: String, fallbackStableId: String? = null): List<LibrarianMessage> = withContext(Dispatchers.IO) {
        val primary = File(root, "${safeName(bookStableId)}.json")
        val file = when {
            primary.exists() -> primary

            fallbackStableId != null -> File(root, "${safeName(fallbackStableId)}.json").takeIf { it.exists() }
            else -> null
        } ?: return@withContext emptyList()
        runCatching {
            json.decodeFromString(ListSerializer(LibrarianMessage.serializer()), file.readText())
                .sortedBy { it.createdAtEpochMs }
        }.getOrDefault(emptyList())
    }

    suspend fun save(bookStableId: String, messages: List<LibrarianMessage>) = withContext(Dispatchers.IO) {
        root.mkdirs()
        val trimmed = messages.takeLast(80)
        File(root, "${safeName(bookStableId)}.json")
            .writeText(json.encodeToString(ListSerializer(LibrarianMessage.serializer()), trimmed))
    }

    suspend fun clear(bookStableId: String) = withContext(Dispatchers.IO) {
        File(root, "${safeName(bookStableId)}.json").delete()
    }
}

@Singleton
class LibrarianEnginePreferenceStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val file = File(context.filesDir, "enve-librarian/engine-preference.txt")

    suspend fun load(): LibrarianEnginePreference = withContext(Dispatchers.IO) {
        val saved = file.takeIf { it.isFile }?.readText()?.trim().orEmpty()
        runCatching { LibrarianEnginePreference.valueOf(saved) }
            .getOrDefault(LibrarianEnginePreference.AUTOMATIC)
    }

    suspend fun save(preference: LibrarianEnginePreference) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        file.writeText(preference.name)
    }
}

private fun safeName(value: String): String {
    val encoded = Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(value.toByteArray(Charsets.UTF_8))

    if (encoded.length <= 120) return encoded
    return java.security.MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
}
