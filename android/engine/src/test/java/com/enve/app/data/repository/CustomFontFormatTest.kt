package com.enve.app.data.repository

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import kotlin.io.path.createTempDirectory

class CustomFontFormatTest {
    @Test
    fun detectsFontFormatFromFileHeaderInsteadOfProviderMetadata() {
        val directory = createTempDirectory("enve-font-format-").toFile()
        try {
            val trueType = File(directory, "opaque-upload").apply {
                writeBytes(byteArrayOf(0x00, 0x01, 0x00, 0x00, 0x01))
            }
            val openType = File(directory, "wrong.ttf").apply {
                writeBytes("OTTOtest".encodeToByteArray())
            }
            val unsupported = File(directory, "fake.otf").apply {
                writeText("not a font")
            }

            assertEquals("ttf", detectCustomFontExtension(trueType))
            assertEquals("otf", detectCustomFontExtension(openType))
            assertEquals(null, detectCustomFontExtension(unsupported))
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun validationAcceptsStructurallyCompleteTrueTypeAndOpenTypeFonts() = withDirectory { directory ->
        val trueType = File(directory, "a").apply { writeBytes(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES)) }
        val openType = File(directory, "b").apply { writeBytes(sfnt(OPEN_TYPE, OPEN_TYPE_TABLES)) }

        assertEquals("ttf", validatedCustomFontExtension(trueType))
        assertEquals("otf", validatedCustomFontExtension(openType))
    }

    @Test
    fun validationRejectsHeadersWithoutAUsableFontBehindThem() = withDirectory { directory ->
        fun check(bytes: ByteArray) = validatedCustomFontExtension(File(directory, "f").apply { writeBytes(bytes) })

        assertNull(check(byteArrayOf(0x00, 0x01, 0x00, 0x00, 0x01)))
        assertNull(check(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES - "glyf")))
        assertNull(check(sfnt(OPEN_TYPE, OPEN_TYPE_TABLES - "CFF ")))
        assertNull(check(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES - "cmap")))
        assertNull(check(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES, headMagic = 0x12345678)))
        assertNull(check(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES).copyOf(200)))
        assertNull(check(sfnt("wOFF".encodeToByteArray(), TRUE_TYPE_TABLES)))
        assertNull(check(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES).also { it[12] = 0x01 }))
    }

    @Test
    fun validationRejectsOversizedFilesWithoutReadingThem() = withDirectory { directory ->
        val file = File(directory, "huge")
        file.writeBytes(sfnt(TRUE_TYPE, TRUE_TYPE_TABLES))
        RandomAccessFile(file, "rw").use { it.setLength(MAX_CUSTOM_FONT_BYTES + 1) }

        assertNull(validatedCustomFontExtension(file))
    }

    @Test
    fun boundedCopyStopsAtTheFontSizeLimit() {
        val small = ByteArrayOutputStream()
        assertEquals(5L, "12345".byteInputStream().copyFontBounded(small))
        assertEquals("12345", small.toString())

        var written = 0L
        val sink = object : OutputStream() {
            override fun write(b: Int) { written++ }
            override fun write(b: ByteArray, off: Int, len: Int) { written += len }
        }
        val endless = object : InputStream() {
            override fun read(): Int = 0
            override fun read(b: ByteArray, off: Int, len: Int): Int = len
        }
        val failure = runCatching { endless.copyFontBounded(sink) }.exceptionOrNull()

        assertEquals(IllegalArgumentException::class, failure?.let { it::class })
        assertEquals(true, written <= MAX_CUSTOM_FONT_BYTES)
    }

    private fun withDirectory(block: (File) -> Unit) {
        val directory = createTempDirectory("enve-font-validation-").toFile()
        try {
            block(directory)
        } finally {
            directory.deleteRecursively()
        }
    }

    private fun sfnt(version: ByteArray, tags: Set<String>, headMagic: Int = 0x5F0F3CF5): ByteArray {
        val headerSize = 12 + 16 * tags.size
        val buffer = ByteBuffer.allocate(headerSize + TABLE_BYTES * tags.size)
        buffer.put(version)
        buffer.putShort(tags.size.toShort()).putShort(0).putShort(0).putShort(0)
        tags.forEachIndexed { index, tag ->
            buffer.put(tag.toByteArray(Charsets.US_ASCII))
            buffer.putInt(0)
            buffer.putInt(headerSize + index * TABLE_BYTES)
            buffer.putInt(TABLE_BYTES)
        }
        val head = tags.indexOf("head")
        if (head >= 0) buffer.putInt(headerSize + head * TABLE_BYTES + 12, headMagic)
        return buffer.array()
    }

    private companion object {
        const val TABLE_BYTES = 64
        val TRUE_TYPE = byteArrayOf(0x00, 0x01, 0x00, 0x00)
        val OPEN_TYPE = "OTTO".encodeToByteArray()
        val TRUE_TYPE_TABLES = setOf("cmap", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "name")
        val OPEN_TYPE_TABLES = setOf("CFF ", "cmap", "head", "hhea", "hmtx", "maxp", "name")
    }
}
