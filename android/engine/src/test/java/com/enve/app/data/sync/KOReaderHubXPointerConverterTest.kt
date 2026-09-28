package com.enve.app.data.sync

import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class KOReaderHubXPointerConverterTest {

    private val nestedChapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body>
        <div><section><p>Alpha bravo</p><p>Second <em>nested</em> tail</p></section>
        <section><p>Third</p><p>Fourth</p></section></div>
        <div><p>Fifth</p></div>
        </body></html>
    """.trimIndent()

    private val trickyChapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head><body>
        <div><p>before<!--comment-->after</p><rp><span>hidden</span></rp>
        <p>caf&#233; &#20013; text</p><p><![CDATA[cdata body]]></p></div>
        </body></html>
    """.trimIndent()

    private val astralChapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Three</title></head><body>
        <p>a😀b<em>x</em>😀tail</p>
        </body></html>
    """.trimIndent()

    private fun epub(vararg chapters: String): File {
        val file = File.createTempFile("koreader-xpointer", ".epub").apply { deleteOnExit() }
        val manifest = chapters.indices.joinToString("") {
            """<item id="c$it" href="text/c$it.xhtml" media-type="application/xhtml+xml"/>"""
        }
        val spine = chapters.indices.joinToString("") { """<itemref idref="c$it"/>""" }
        ZipOutputStream(FileOutputStream(file)).use { zip ->
            zip.write(
                "META-INF/container.xml",
                """<?xml version="1.0"?>
                   <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
                     <rootfiles><rootfile full-path="OEBPS/content.opf"
                       media-type="application/oebps-package+xml"/></rootfiles>
                   </container>""".trimIndent(),
            )
            zip.write(
                "OEBPS/content.opf",
                """<?xml version="1.0" encoding="UTF-8"?>
                   <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                     <metadata/><manifest>$manifest</manifest><spine>$spine</spine>
                   </package>""".trimIndent(),
            )
            chapters.forEachIndexed { index, body -> zip.write("OEBPS/text/c$index.xhtml", body) }
        }
        return file
    }

    private fun ZipOutputStream.write(name: String, content: String) {
        putNextEntry(ZipEntry(name))
        write(content.toByteArray(Charsets.UTF_8))
        closeEntry()
    }

    private fun locations(locatorJson: String) =
        Json.parseToJsonElement(locatorJson).jsonObject.getValue("locations").jsonObject

    private fun partialCfi(locatorJson: String): String =
        locations(locatorJson).getValue("partialCfi").jsonPrimitive.content

    private fun href(locatorJson: String): String =
        Json.parseToJsonElement(locatorJson).jsonObject.getValue("href").jsonPrimitive.content

    private fun locatorWithCfi(cfi: String): String =
        """{"href":"OEBPS/text/c0.xhtml","type":"application/xhtml+xml",""" +
            """"locations":{"totalProgression":0.3,"partialCfi":"$cfi"}}"""

    @Test
    fun emitted_locations_use_the_flattened_readium_keys() {
        val file = epub(nestedChapter)

        val locator = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]/text()[1].6", 0.25, file,
        )!!

        val locations = locations(locator)
        assertNull(locations["otherLocations"])
        assertEquals("/4/2/2/4/1:6", locations.getValue("partialCfi").jsonPrimitive.content)
        assertEquals(
            "epubcfi(/6/2!/4/2/2/4/1:6)",
            locations.getValue("cfi").jsonPrimitive.content,
        )
        assertEquals(0.25, locations.getValue("totalProgression").jsonPrimitive.content.toDouble(), 0.0)
    }

    @Test
    fun emitted_anchor_is_readable_through_the_app_checkpoint_codec() {
        val file = epub(nestedChapter)

        val locator = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[2]/p[2]/text()[1].3", 0.5, file,
        )!!

        assertEquals("epubcfi(/6/2!/4/2/4/4/1:3)", EpubBridgeCheckpointCodec.cfi(locator))
        val checkpoint = EpubBridgeCheckpointCodec.fromReadiumLocator(
            locatorJson = locator,
            publicationSha256 = "sha",
            providerFileId = null,
            writerEpoch = 1,
            revision = 1,
            observedAt = 1,
        )!!
        assertEquals("OEBPS/text/c0.xhtml", checkpoint.href)
        assertEquals(0.5, checkpoint.totalProgression!!, 0.0)
        assertEquals(ReaderEngineKind.READIUM, checkpoint.sourceEngine)
    }

    @Test
    fun resolves_full_ancestry_instead_of_the_last_matching_tag() {
        val file = epub(nestedChapter)

        val first = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]", 0.25, file,
        )!!
        val second = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[2]/p[2]", 0.5, file,
        )!!

        assertEquals("OEBPS/text/c0.xhtml", href(first))
        assertEquals("/4/2/2/4", partialCfi(first))
        assertEquals("/4/2/4/4", partialCfi(second))
    }

    @Test
    fun repeated_sibling_tags_round_trip_through_cfi() {
        val file = epub(nestedChapter)

        for (xpointer in listOf(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[1]",
            "/body/DocFragment[1]/body/div[1]/section[2]/p[2]",
            "/body/DocFragment[1]/body/div[2]/p[1]",
        )) {
            val locator = KOReaderHubXPointerConverter.locatorJson(xpointer, 0.4, file)!!
            assertEquals("$xpointer.0", KOReaderHubXPointerConverter.xpointer(locator, file))
        }
    }

    @Test
    fun text_node_index_and_offset_survive_both_directions() {
        val file = epub(nestedChapter)

        val firstNode = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]/text()[1].6", 0.3, file,
        )!!
        val secondNode = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]/text()[2].2", 0.3, file,
        )!!

        assertEquals("/4/2/2/4/1:6", partialCfi(firstNode))
        assertEquals("/4/2/2/4/3:2", partialCfi(secondNode))
        assertEquals(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]/text()[1].6",
            KOReaderHubXPointerConverter.xpointer(firstNode, file),
        )
        assertEquals(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]/text()[2].2",
            KOReaderHubXPointerConverter.xpointer(secondNode, file),
        )
    }

    @Test
    fun accepts_koreader_offsets_without_a_text_node_index() {
        val file = epub(nestedChapter)

        val indexless = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[1]/text().9", 0.2, file,
        )!!
        val elementOffset = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[1].0", 0.2, file,
        )!!

        assertEquals("/4/2/2/2/1:9", partialCfi(indexless))
        assertEquals("/4/2/2/2/1:0", partialCfi(elementOffset))
    }

    @Test
    fun offsets_past_the_end_of_the_text_clamp_to_its_last_position() {
        val file = epub(nestedChapter)

        val overflow = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[1]/text()[1].40", 0.2, file,
        )!!

        assertEquals("/4/2/2/2/1:11", partialCfi(overflow))
        assertEquals(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[1]/text()[1].11",
            KOReaderHubXPointerConverter.xpointer(overflow, file),
        )
    }

    @Test
    fun comments_merge_adjacent_text_into_one_cfi_chunk() {
        val file = epub(nestedChapter, trickyChapter)

        val afterComment = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[2]/body/div[1]/p[1]/text()[2].0", 0.6, file,
        )!!

        assertEquals("OEBPS/text/c1.xhtml", href(afterComment))
        assertEquals("/4/2/2/1:6", partialCfi(afterComment))
        assertEquals(
            "/body/DocFragment[2]/body/div[1]/p[1]/text()[2].0",
            KOReaderHubXPointerConverter.xpointer(afterComment, file),
        )
    }

    @Test
    fun cdata_and_non_visible_elements_do_not_shift_element_indices() {
        val file = epub(nestedChapter, trickyChapter)

        val hidden = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[2]/body/div[1]/rp[1]/span[1]", 0.6, file,
        )!!
        val cdata = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[2]/body/div[1]/p[3]/text()[1].4", 0.7, file,
        )!!

        assertEquals("/4/2/4/2", partialCfi(hidden))
        assertEquals("/4/2/8/1:4", partialCfi(cdata))
        assertEquals(
            "/body/DocFragment[2]/body/div[1]/p[3]/text()[1].4",
            KOReaderHubXPointerConverter.xpointer(cdata, file),
        )
    }

    @Test
    fun unicode_content_does_not_disturb_structural_mapping() {
        val file = epub(nestedChapter, trickyChapter)

        val unicode = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[2]/body/div[1]/p[2]/text()[1].5", 0.65, file,
        )!!

        assertEquals("/4/2/6/1:5", partialCfi(unicode))
        assertEquals(
            "/body/DocFragment[2]/body/div[1]/p[2]/text()[1].5",
            KOReaderHubXPointerConverter.xpointer(unicode, file),
        )
    }

    @Test
    fun astral_characters_convert_between_code_points_and_utf16_units() {
        val file = epub(astralChapter)

        val beforeB = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/p[1]/text()[1].2", 0.1, file,
        )!!
        val afterEmoji = KOReaderHubXPointerConverter.locatorJson(
            "/body/DocFragment[1]/body/p[1]/text()[2].1", 0.2, file,
        )!!

        assertEquals("/4/2/1:3", partialCfi(beforeB))
        assertEquals("/4/2/3:2", partialCfi(afterEmoji))
        assertEquals(
            "/body/DocFragment[1]/body/p[1]/text()[1].2",
            KOReaderHubXPointerConverter.xpointer(beforeB, file),
        )
        assertEquals(
            "/body/DocFragment[1]/body/p[1]/text()[2].1",
            KOReaderHubXPointerConverter.xpointer(afterEmoji, file),
        )
    }

    @Test
    fun a_cfi_offset_inside_a_surrogate_pair_snaps_to_the_code_point_start() {
        val file = epub(astralChapter)

        assertEquals(
            "/body/DocFragment[1]/body/p[1]/text()[1].1",
            KOReaderHubXPointerConverter.xpointer(
                """{"href":"OEBPS/text/c0.xhtml","locations":{"partialCfi":"/4/2/1:2"}}""",
                file,
            ),
        )
    }

    @Test
    fun converts_an_epub_bridge_checkpoint_into_an_xpointer() {
        val file = epub(nestedChapter)
        val checkpoint = EpubBridgeCheckpointCodec.encode(
            EpubBridgeCheckpoint(
                publicationSha256 = "sha",
                observedAt = 1,
                sourceEngine = ReaderEngineKind.FOLIATE,
                href = "OEBPS/text/c0.xhtml",
                epubCfi = "epubcfi(/6/2!/4/2/2/4/1:6)",
                totalProgression = 0.3,
            ),
        )

        assertEquals(
            "/body/DocFragment[1]/body/div[1]/section[1]/p[2]/text()[1].6",
            KOReaderHubXPointerConverter.xpointer(checkpoint, file),
        )
    }

    @Test
    fun rejects_unusable_input_without_throwing() {
        val file = epub(nestedChapter)

        assertNull(KOReaderHubXPointerConverter.locatorJson("not an xpointer", 0.1, file))
        assertNull(KOReaderHubXPointerConverter.locatorJson("/body/DocFragment[9]/body/p[1]", 0.1, file))
        assertNull(
            KOReaderHubXPointerConverter.locatorJson(
                "/body/DocFragment[1]/body/div[1]/section[9]/p[1]", 0.1, file,
            ),
        )
        assertNull(
            KOReaderHubXPointerConverter.locatorJson(
                "/body/DocFragment[1]/body/div[1]/section[1]/p[1]/text()[4].0", 0.1, file,
            ),
        )
        assertNull(KOReaderHubXPointerConverter.xpointer("{}", file))
        assertNull(KOReaderHubXPointerConverter.xpointer("not json", file))
    }

    @Test
    fun refuses_range_truncated_and_unresolved_cfis() {
        val file = epub(nestedChapter)

        assertNull(KOReaderHubXPointerConverter.xpointer(locatorWithCfi("/4/2/2/4,/1:0,/1:5"), file))
        assertNull(KOReaderHubXPointerConverter.xpointer(locatorWithCfi("/4/2/98/2"), file))
        assertNull(KOReaderHubXPointerConverter.xpointer(locatorWithCfi("/4/2/1/2"), file))
        assertNull(KOReaderHubXPointerConverter.xpointer(locatorWithCfi("/4/2/2/2/3:0"), file))
        assertNull(KOReaderHubXPointerConverter.xpointer(locatorWithCfi("/2/2"), file))
    }
}
