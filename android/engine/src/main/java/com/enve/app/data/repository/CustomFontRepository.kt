package com.enve.app.data.repository

import android.content.Context
import android.net.Uri
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.reader.CustomFont
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

internal fun detectCustomFontExtension(file: File): String? {
    val header = ByteArray(4)
    val count = file.inputStream().use { it.read(header) }
    if (count != header.size) return null
    val signature = header.decodeToString()
    return when {
        header.contentEquals(byteArrayOf(0x00, 0x01, 0x00, 0x00)) -> "ttf"
        signature == "true" || signature == "typ1" -> "ttf"
        signature == "OTTO" -> "otf"
        else -> null
    }
}

@Singleton
class CustomFontRepository @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    enum class Variant { REGULAR, BOLD, ITALIC, BOLD_ITALIC }

    private val dao by lazy { ReaderDatabase.getInstance(context).customFontDao() }

    fun observeFonts(): Flow<List<CustomFont>> = dao.observeAll()

    suspend fun listFonts(): List<CustomFont> = withContext(Dispatchers.IO) { dao.getAll() }

    suspend fun addVariant(
        familyId: String?,
        displayName: String,
        variant: Variant,
        sourceUri: Uri,
    ): Result<CustomFont> = withContext(Dispatchers.IO) {
        runCatching {
            val trimmedName = validateDisplayName(displayName)
            val generatedId = sanitizeId(trimmedName)
            val id = familyId ?: generatedId
            require(id.isNotBlank()) { "Font name must contain alphanumerics" }
            val existing = dao.get(id)
            if (familyId != null) requireNotNull(existing) { "Font family not found" }
            if (familyId == null && existing != null) {
                error("A font family with this name already exists. Add the file to that family instead.")
            }
            if (familyId == null && dao.getAll().any { it.displayName.equals(trimmedName, ignoreCase = true) }) {
                error("A font family with this name already exists. Add the file to that family instead.")
            }
            val familyName = existing?.displayName ?: trimmedName

            val familyDir = File(fontRoot(), id).apply { if (!exists()) mkdirs() }
            val revision = System.nanoTime()
            val upload = File(familyDir, ".${variant.fileBase}-$revision.upload")
            var destination: File? = null

            try {
                val input = context.contentResolver.openInputStream(sourceUri)
                    ?: error("Could not open the selected file")
                input.use { source ->
                    upload.outputStream().use { output -> source.copyTo(output) }
                }
                require(upload.length() > 0L) { "The selected font file is empty" }
                val extension = detectCustomFontExtension(upload)
                    ?: error("Select a TrueType (.ttf) or OpenType (.otf) font file")
                destination = File(familyDir, "${variant.fileBase}-$revision.$extension")
                if (!upload.renameTo(destination)) {
                    upload.copyTo(destination)
                    upload.delete()
                }

                val updated = (existing ?: CustomFont(
                    id = id,
                    displayName = familyName,
                    addedAt = System.currentTimeMillis(),
                )).withVariant(variant, destination.absolutePath)
                    .copy(displayName = familyName)
                dao.upsert(updated)
                existing?.pathFor(variant)
                    ?.takeUnless { it == destination.absolutePath }
                    ?.let(::File)
                    ?.delete()
                updated
            } catch (error: Exception) {
                upload.delete()
                destination?.delete()
                throw error
            }
        }
    }

    suspend fun rename(id: String, newDisplayName: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            val trimmed = validateDisplayName(newDisplayName)
            val existing = dao.get(id) ?: error("Font not found")
            require(dao.getAll().none { it.id != id && it.displayName.equals(trimmed, ignoreCase = true) }) {
                "A font family with this name already exists"
            }

            dao.upsert(existing.copy(displayName = trimmed))
        }
    }

    suspend fun deleteFamily(id: String): Result<Unit> = withContext(Dispatchers.IO) {
        runCatching {
            dao.delete(id)
            File(fontRoot(), id).deleteRecursively()
            Unit
        }
    }

    suspend fun deleteVariant(id: String, variant: Variant): Result<CustomFont?> =
        withContext(Dispatchers.IO) {
            runCatching {
                val existing = dao.get(id) ?: return@runCatching null
                require(
                    variant != Variant.REGULAR ||
                        existing.boldPath == null && existing.italicPath == null && existing.boldItalicPath == null,
                ) { "Delete the font family instead of removing its Regular face" }
                val removedPath = existing.pathFor(variant)
                val updated = existing.withVariant(variant, null)
                if (updated.regularPath == null && updated.boldPath == null &&
                    updated.italicPath == null && updated.boldItalicPath == null
                ) {
                    dao.delete(id)
                    File(fontRoot(), id).deleteRecursively()
                    null
                } else {
                    dao.upsert(updated)
                    removedPath?.let(::File)?.delete()
                    updated
                }
            }
        }

    private fun fontRoot(): File = File(context.filesDir, "reader-fonts").apply {
        if (!exists()) mkdirs()
    }

    companion object {
        private val Variant.fileBase: String
            get() = when (this) {
                Variant.REGULAR -> "regular"
                Variant.BOLD -> "bold"
                Variant.ITALIC -> "italic"
                Variant.BOLD_ITALIC -> "boldItalic"
            }

        private fun sanitizeId(name: String): String =
            name.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-')

        private fun validateDisplayName(name: String): String {
            val trimmed = name.trim()
            require(trimmed.isNotBlank()) { "Font name cannot be blank" }
            require(trimmed.length <= 80) { "Font name is too long" }
            require(trimmed.none { it == '"' || it == '\\' || it.isISOControl() }) {
                "Font name cannot contain quotes, backslashes, or control characters"
            }
            return trimmed
        }

        private fun CustomFont.withVariant(variant: Variant, path: String?): CustomFont = when (variant) {
            Variant.REGULAR -> copy(regularPath = path)
            Variant.BOLD -> copy(boldPath = path)
            Variant.ITALIC -> copy(italicPath = path)
            Variant.BOLD_ITALIC -> copy(boldItalicPath = path)
        }

        fun CustomFont.pathFor(variant: Variant): String? = when (variant) {
            Variant.REGULAR -> regularPath
            Variant.BOLD -> boldPath
            Variant.ITALIC -> italicPath
            Variant.BOLD_ITALIC -> boldItalicPath
        }
    }
}
