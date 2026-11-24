package com.enve.app.data.reader.fonts

import com.enve.app.data.repository.CustomFontRepository.Variant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderFontCatalogTest {
    private val lora = ReaderFontCatalog.families.first { it.directory == "lora" }

    @Test
    fun variableFamilyResolvesBoldFromTheWeightAxis() {
        val metadata = ReaderFontCatalog.parseMetadata(
            """
            name: "Lora"
            designer: "Cyreal"
            license: "OFL"
            fonts {
              name: "Lora"
              style: "normal"
              weight: 400
              filename: "Lora[wght].ttf"
              copyright: "Copyright 2011 The Lora Project Authors {with braces}"
            }
            fonts {
              name: "Lora"
              style: "italic"
              weight: 400
              filename: "Lora-Italic[wght].ttf"
            }
            axes {
              tag: "wght"
              min_value: 400.0
              max_value: 700.0
            }
            source {
              repository_url: "https://github.com/cyrealtype/Lora-Cyrillic"
              files {
                source_file: "fonts/variable/Lora[wght].ttf"
                dest_file: "Lora[wght].ttf"
              }
            }
            """.trimIndent(),
        )

        assertEquals(2, metadata.files.size)
        assertEquals(listOf(ReaderFontAxis("wght", 400f, 700f)), metadata.axes)
        assertEquals(
            mapOf(
                Variant.REGULAR to "Lora[wght].ttf",
                Variant.BOLD to "Lora[wght].ttf",
                Variant.ITALIC to "Lora-Italic[wght].ttf",
                Variant.BOLD_ITALIC to "Lora-Italic[wght].ttf",
            ),
            ReaderFontCatalog.resolveFaces(metadata),
        )
    }

    @Test
    fun staticFamilyPrefersExactWeightsAndSkipsMissingStyles() {
        val metadata = ReaderFontCatalog.parseMetadata(
            """
            fonts {
              style: "normal"
              weight: 300
              filename: "Sample-Light.ttf"
            }
            fonts {
              style: "normal"
              weight: 400
              filename: "Sample-Regular.ttf"
            }
            fonts {
              style: "normal"
              weight: 700
              filename: "Sample-Bold.ttf"
            }
            """.trimIndent(),
        )

        assertEquals(
            mapOf(Variant.REGULAR to "Sample-Regular.ttf", Variant.BOLD to "Sample-Bold.ttf"),
            ReaderFontCatalog.resolveFaces(metadata),
        )
    }

    @Test
    fun variableAxisOutsideBoldRangeDoesNotFakeABoldFace() {
        val metadata = ReaderFontCatalog.parseMetadata(
            """
            fonts {
              style: "normal"
              weight: 400
              filename: "Thin[wght].ttf"
            }
            axes {
              tag: "wght"
              min_value: 100.0
              max_value: 500.0
            }
            """.trimIndent(),
        )

        assertEquals(mapOf(Variant.REGULAR to "Thin[wght].ttf"), ReaderFontCatalog.resolveFaces(metadata))
    }

    @Test
    fun unsafeOrMalformedEntriesAreIgnored() {
        val metadata = ReaderFontCatalog.parseMetadata(
            """
            fonts {
              style: "normal"
              weight: 400
              filename: "../../secrets.ttf"
            }
            fonts {
              style: "normal"
              weight: 400
              filename: "sub/dir.ttf"
            }
            fonts {
              style: "oblique"
              weight: 400
              filename: "Odd.ttf"
            }
            fonts {
              style: "normal"
              weight: heavy
              filename: "Heavy.ttf"
            }
            fonts {
              style: "normal"
              weight: 400
              filename: "Sample.woff2"
            }
            """.trimIndent(),
        )

        assertTrue(metadata.files.isEmpty())
        assertTrue(ReaderFontCatalog.resolveFaces(metadata).isEmpty())
    }

    @Test
    fun urlsStayOnTheGoogleFontsRepositoryAndPreserveVariableFileNames() {
        assertEquals(
            "https://raw.githubusercontent.com/google/fonts/main/ofl/lora/METADATA.pb",
            ReaderFontCatalog.metadataUrl(lora).toString(),
        )
        assertEquals(
            "https://raw.githubusercontent.com/google/fonts/main/ofl/lora/Lora[wght].ttf",
            ReaderFontCatalog.fileUrl(lora, "Lora[wght].ttf").toString(),
        )
        assertEquals("https://github.com/google/fonts/blob/main/ofl/lora/OFL.txt", lora.licenseUrl)
        assertFalse(ReaderFontCatalog.isSafeFilename("../Lora.ttf"))
        assertFalse(ReaderFontCatalog.isSafeFilename("Lora.ttf?x=1"))
        assertFalse(ReaderFontCatalog.isSafeFilename(".hidden.ttf"))
        assertTrue(ReaderFontCatalog.isSafeFilename("Lora-Italic[wght].ttf"))
        assertTrue(ReaderFontCatalog.isSafeFilename("NotoSerif[wdth,wght].ttf"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun fileUrlRejectsUnsafeNames() {
        ReaderFontCatalog.fileUrl(lora, "../../../etc/passwd.ttf")
    }

    @Test
    fun catalogIsCuratedUniqueAndExcludesBundledFamilies() {
        val families = ReaderFontCatalog.families
        assertEquals(families.size, families.map { it.directory }.toSet().size)
        assertEquals(families.size, families.map { it.name.lowercase() }.toSet().size)
        assertTrue(families.all { Regex("[a-z0-9]+").matches(it.directory) })
        assertTrue(families.all { family -> family.name.none { it == '"' || it == '\\' } })
        val bundled = setOf("literata", "atkinson hyperlegible", "lexend", "opendyslexic", "ia writer duo")
        assertTrue(families.none { it.name.lowercase() in bundled })
    }

    @Test
    fun searchMatchesNameAndCategoryAndBoundsTheQuery() {
        assertEquals(ReaderFontCatalog.families, ReaderFontCatalog.search("   "))
        assertEquals(listOf("EB Garamond", "Cormorant Garamond").sorted(), ReaderFontCatalog.search("garamond").map { it.name }.sorted())
        assertTrue(ReaderFontCatalog.search("monospace").all { it.category == ReaderFontCategory.MONOSPACE })
        assertTrue(ReaderFontCatalog.search("x".repeat(500)).isEmpty())
    }
}
