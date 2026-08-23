package com.enve.app.ui.screens

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.repository.CustomFontRepository
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.shared.util.Url

@RunWith(AndroidJUnit4::class)
class ReadiumCustomFontResourcesTest {
    @Test
    fun exposesInstalledVariantsThroughReadiumsPublicationOrigin() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, "readium-font-resource-test").apply {
            deleteRecursively()
            mkdirs()
        }
        val regular = File(directory, "regular.ttf").apply {
            writeBytes(byteArrayOf(0x00, 0x01, 0x00, 0x00, 0x01))
        }
        val boldItalic = File(directory, "bold-italic.otf").apply {
            writeBytes("OTTOtest".encodeToByteArray())
        }
        val resources = ReadiumCustomFontResources(
            listOf(
                CustomFont(
                    id = "test-family",
                    displayName = "Test Family",
                    regularPath = regular.absolutePath,
                    boldItalicPath = boldItalic.absolutePath,
                    addedAt = 1L,
                ),
            ),
        )

        assertEquals(
            "https://readium/publication/enve-reader-fonts/test-family/regular.ttf",
            resources.sourceUrl("test-family", CustomFontRepository.Variant.REGULAR).toString(),
        )
        assertEquals(
            "https://readium/publication/enve-reader-fonts/test-family/bold-italic.otf",
            resources.sourceUrl("test-family", CustomFontRepository.Variant.BOLD_ITALIC).toString(),
        )
        val regularUrl = requireNotNull(
            Url.fromDecodedPath("enve-reader-fonts/test-family/regular.ttf"),
        )
        assertNotNull(resources[regularUrl])
        assertEquals(setOf("font/ttf", "font/otf"), resources.links.map { it.mediaType.toString() }.toSet())

        directory.deleteRecursively()
    }
}
