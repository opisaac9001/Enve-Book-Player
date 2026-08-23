package com.enve.app.data.repository

import java.io.File
import org.junit.Assert.assertEquals
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
}
