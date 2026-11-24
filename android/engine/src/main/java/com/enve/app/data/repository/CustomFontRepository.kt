package com.enve.app.data.repository

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import android.net.Uri
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.reader.CustomFont
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import javax.inject.Inject
import javax.inject.Singleton

internal const val MAX_CUSTOM_FONT_BYTES = 16L * 1024 * 1024
private const val SFNT_HEADER_BYTES = 12
private const val SFNT_TABLE_RECORD_BYTES = 16
private const val MAX_SFNT_TABLES = 128
private const val HEAD_TABLE_MIN_BYTES = 54L
private const val HEAD_MAGIC = 0x5F0F3CF5
private val REQUIRED_SFNT_TABLES = listOf("cmap", "head", "hhea", "hmtx", "maxp")

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

internal fun validatedCustomFontExtension(file: File): String? {
    val length = file.length()
    if (length < SFNT_HEADER_BYTES || length > MAX_CUSTOM_FONT_BYTES) return null
    val extension = detectCustomFontExtension(file) ?: return null
    return RandomAccessFile(file, "r").use { font ->
        font.seek(4)
        val tableCount = font.readUnsignedShort()
        if (tableCount !in 1..MAX_SFNT_TABLES) return@use null
        val directoryEnd = SFNT_HEADER_BYTES + tableCount.toLong() * SFNT_TABLE_RECORD_BYTES
        if (directoryEnd > length) return@use null
        font.seek(SFNT_HEADER_BYTES.toLong())
        val tables = HashMap<String, Pair<Long, Long>>(tableCount)
        val tag = ByteArray(4)
        repeat(tableCount) {
            font.readFully(tag)
            if (tag.any { it < 0x20 || it > 0x7E }) return@use null
            font.skipBytes(4)
            val offset = font.readInt().toLong() and 0xFFFFFFFFL
            val size = font.readInt().toLong() and 0xFFFFFFFFL
            if (offset < directoryEnd || offset + size > length) return@use null
            tables[String(tag, Charsets.US_ASCII)] = offset to size
        }
        if (!REQUIRED_SFNT_TABLES.all(tables::containsKey)) return@use null
        val hasOutlines = if (extension == "otf") {
            "CFF " in tables || "CFF2" in tables
        } else {
            "glyf" in tables && "loca" in tables
        }
        if (!hasOutlines) return@use null
        val (headOffset, headSize) = tables.getValue("head")
        if (headSize < HEAD_TABLE_MIN_BYTES) return@use null
        font.seek(headOffset + 12)
        if (font.readInt() != HEAD_MAGIC) return@use null
        extension
    }
}

internal fun InputStream.copyFontBounded(output: OutputStream): Long {
    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
    var total = 0L
    while (true) {
        val read = read(buffer)
        if (read < 0) return total
        total += read
        require(total <= MAX_CUSTOM_FONT_BYTES) { "Font files must be smaller than 16 MB" }
        output.write(buffer, 0, read)
    }
}

@Singleton
class CustomFontRepository @Inject constructor(
    @ApplicationContext private val context: Context,
    private val database: ReaderDatabase,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    enum class Variant { REGULAR, BOLD, ITALIC, BOLD_ITALIC }

    private val dao by lazy { database.customFontDao() }

    fun observeFonts(): Flow<List<CustomFont>> = dao.observeAll()

    suspend fun listFonts(): List<CustomFont> = withContext(Dispatchers.IO) { dao.getAll() }

    suspend fun addVariant(
        familyId: String?,
        displayName: String,
        variant: Variant,
        sourceUri: Uri,
    ): Result<CustomFont> = withContext(Dispatchers.IO) {
        fontResult {
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
                    upload.outputStream().use { output -> source.copyFontBounded(output) }
                }
                require(upload.length() > 0L) { "The selected font file is empty" }
                val extension = validatedCustomFontExtension(upload)
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

    suspend fun installFamily(displayName: String, faces: Map<Variant, File>): Result<CustomFont> =
        withContext(Dispatchers.IO) {
            fontResult {
                val name = validateDisplayName(displayName)
                val id = sanitizeId(name)
                require(id.isNotBlank()) { "Font name must contain alphanumerics" }
                require(Variant.REGULAR in faces) { "$name has no regular style" }
                if (dao.get(id) != null || dao.getAll().any { it.displayName.equals(name, ignoreCase = true) }) {
                    error("$name is already installed")
                }
                val familyDir = File(fontRoot(), id).apply { mkdirs() }
                val revision = System.nanoTime()
                try {
                    val installed = faces.entries.fold(
                        CustomFont(id = id, displayName = name, addedAt = System.currentTimeMillis()),
                    ) { font, (variant, source) ->
                        val extension = validatedCustomFontExtension(source)
                            ?: error("$name did not download as a valid TrueType or OpenType font")
                        val destination = File(familyDir, "${variant.fileBase}-$revision.$extension")
                        source.copyTo(destination, overwrite = true)
                        font.withVariant(variant, destination.absolutePath)
                    }
                    dao.upsert(installed)
                    installed
                } catch (error: Exception) {
                    familyDir.deleteRecursively()
                    throw error
                }
            }
        }

    suspend fun rename(id: String, newDisplayName: String): Result<Unit> = withContext(Dispatchers.IO) {
        fontResult {
            val trimmed = validateDisplayName(newDisplayName)
            val existing = dao.get(id) ?: error("Font not found")
            require(dao.getAll().none { it.id != id && it.displayName.equals(trimmed, ignoreCase = true) }) {
                "A font family with this name already exists"
            }

            dao.upsert(existing.copy(displayName = trimmed))
        }
    }

    suspend fun deleteFamily(id: String): Result<Unit> = withContext(Dispatchers.IO) {
        fontResult {
            dao.delete(id)
            File(fontRoot(), id).deleteRecursively()
            Unit
        }
    }

    suspend fun deleteVariant(id: String, variant: Variant): Result<CustomFont?> =
        withContext(Dispatchers.IO) {
            fontResult {
                val existing = dao.get(id) ?: return@fontResult null
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

    private fun fontRoot(): File = File(locations.filesDirectory, "reader-fonts").apply {
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

private suspend inline fun <T> fontResult(block: () -> T): Result<T> = try {
    Result.success(block())
} catch (error: kotlinx.coroutines.CancellationException) {
    throw error
} catch (error: Exception) {
    Result.failure(error)
}
