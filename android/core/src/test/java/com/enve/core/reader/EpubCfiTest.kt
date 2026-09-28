package com.enve.core.reader

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EpubCfiTest {
    private val chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignored</title></head>
        <body>
          <section id="ch1">
            <h1>Chapter <em>One</em></h1>
            <p id="p1"><span id="s1">First sentence.</span> <span id="s2">Second <i>nested</i> sentence here.</span></p>
            <p>Caf&#233; ${"😀"} text with <b>bold</b> and more words after the bold part.<!-- split -->Tail run.</p>
            <p id="dup">Duplicate A</p>
            <p id="dup">Duplicate B</p>
          </section>
        </body></html>
    """.trimIndent()

    private val epubPackage = EpubPackage(
        spineStep = 6,
        spine = listOf(
            EpubPackage.SpineItem(itemrefId = null, href = "OEBPS/text/cover.xhtml", mediaOverlayHref = null, isLinear = false),
            EpubPackage.SpineItem(itemrefId = "c1", href = "OEBPS/text/ch1.xhtml", mediaOverlayHref = "OEBPS/smil/ch1.smil", isLinear = true),
        ),
    )

    private fun document(html: String = chapter) = EpubXhtmlDocument.parse(html)

    private fun cfi(locator: JsonObject, document: EpubXhtmlDocument): String? {
        val point = EpubCfi.point(locator, document) ?: return null
        return EpubCfi.verifiedCfi(point, document, spineIndex = 1, epubPackage = epubPackage)
    }

    private fun locator(
        locations: JsonObject,
        highlight: String? = null,
        before: String? = null,
    ) = buildJsonObject {
        put("href", "OEBPS/text/ch1.xhtml")
        put("locations", locations)
        if (highlight != null) {
            put("text", buildJsonObject {
                put("highlight", highlight)
                if (before != null) put("before", before)
            })
        }
    }

    private fun JsonObject.locations() = getValue("locations").jsonObject

    @Test
    fun narratedSentenceBecomesAnElementCfiWithIdAssertions() {
        val document = document()
        val locator = locator(buildJsonObject {
            put("fragments", kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("s2"))))
            put("progression", 0.3)
            put("totalProgression", 0.4)
        })

        assertEquals("epubcfi(/6/4[c1]!/4/2[ch1]/4[p1]/4[s2])", cfi(locator, document))
    }

    @Test
    fun textQuoteBecomesATextOffsetCountedInUtf16() {
        val document = document()
        val progression = buildJsonObject { put("progression", 0.5) }
        val afterBold = locator(progression, highlight = "and more words after the bold part.", before = "with bold")
        val afterEmoji = locator(progression, highlight = "text   with bold and more")

        assertEquals("epubcfi(/6/4[c1]!/4/2[ch1]/6/3:1)", cfi(afterBold, document))
        assertEquals("epubcfi(/6/4[c1]!/4/2[ch1]/6/1:8)", cfi(afterEmoji, document))
    }

    @Test
    fun readerDomRangeBecomesATextPointInsideTheSentence() {
        val document = document()
        val page = locator(
            buildJsonObject {
                put("cssSelector", "body > section > p:nth-of-type(1)")
                put("domRange", buildJsonObject {
                    put("start", buildJsonObject {
                        put("cssSelector", "#s2")
                        put("textNodeIndex", 1)
                        put("charOffset", 2)
                    })
                })
                put("progression", 0.3)
            },
            highlight = "sted sentence here.",
        )

        assertEquals("epubcfi(/6/4[c1]!/4/2[ch1]/4[p1]/4[s2]/2/1:2)", cfi(page, document))
    }

    @Test
    fun textSplitByACommentStaysOneChunk() {
        val document = document()
        val tail = locator(JsonObject(emptyMap()), highlight = "Tail run.")

        assertEquals("epubcfi(/6/4[c1]!/4/2[ch1]/6/3:36)", cfi(tail, document))
    }

    @Test
    fun cdataJoinsTheSurroundingTextChunk() {
        val document = document("<html><body><p id=\"a\">One <![CDATA[two]]> three <b>x</b></p></body></html>")
        val point = EpubCfi.point(locator(JsonObject(emptyMap()), highlight = "two three"), document)!!

        assertEquals("epubcfi(/6/4[c1]!/2/2[a]/1:4)", EpubCfi.verifiedCfi(point, document, 1, epubPackage))
    }

    @Test
    fun progressionLandsOnTheCharacterAtThatFraction() {
        val document = document()
        val index = document.textIndex()
        val point = index.point(fraction = 0.0)!!

        assertEquals("/4/2[ch1]/2/1:0", document.localPath(point))
        assertTrue(index.offset(point) > 0)
    }

    @Test
    fun builtCfisResolveToTheSameElementOrText() {
        val document = document()
        val index = document.textIndex()
        val points = listOf("ch1", "p1", "s1", "s2").map { EpubCfi.Point(document.element(it)!!, null) } +
            (0 until index.length step 7).map { index.point(it)!! }

        for (point in points) {
            val cfi = EpubCfi.verifiedCfi(point, document, spineIndex = 1, epubPackage = epubPackage)!!
            val parsed = EpubCfi.parse(cfi)!!
            assertTrue(document.resolve(parsed.local)!!.isSameLocation(point))
            assertEquals(1, EpubCfi.spineIndex(parsed, epubPackage))
        }
    }

    @Test
    fun duplicateIdsFailTheRoundTrip() {
        val document = document()
        fun foliate(cfi: String) = locator(buildJsonObject {
            put("cfi", cfi)
            put("enveSourceEngine", "foliate")
        })

        assertNull(cfi(foliate("epubcfi(/6/4!/4/2/10[dup])"), document))
        assertEquals("epubcfi(/6/4[c1]!/4/2[ch1]/8[dup])", cfi(foliate("epubcfi(/6/4!/4/2/8[dup])"), document))
    }

    @Test
    fun malformedXhtmlNeverProducesACfi() {
        val document = document("<html><body><p id=\"a\">Open <b>never closed</p></body></html>")
        val locator = buildJsonObject {
            put("locations", buildJsonObject {
                put("fragments", kotlinx.serialization.json.JsonArray(listOf(JsonPrimitive("a"))))
            })
        }

        assertFalse(document.isWellFormed)
        assertNull(cfi(locator, document))
    }

    @Test
    fun undeclaredEntitiesAreNotWellFormed() {
        val document = document(
            """<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">""" +
                "<html><body><p id=\"a\">One&nbsp;two</p></body></html>",
        )

        assertFalse(document.isWellFormed)
    }

    @Test
    fun parsesRangesEscapesAndIgnoresTextAssertions() {
        val range = EpubCfi.parse("epubcfi(/6/4[c1]!/4/2[ch1],/4[p1]/2[s1]/1:3,/6/1:9)")!!
        assertEquals(listOf(6, 4), range.packagePath.map { it.index })
        assertEquals(listOf(4, 2, 4, 2, 1), range.local.map { it.index })
        assertEquals(3, range.local.last().offset)

        val escaped = EpubCfi.parse("epubcfi(/6/4!/4/2[a^]b^,c;s=a]/3:5[yyy,zzz;s=b])")!!
        assertEquals("a]b,c", escaped.local[1].assertion)
        assertNull(escaped.local[2].assertion)
        assertEquals(5, escaped.local[2].offset)
        assertEquals("[a^]b^,c]", EpubCfi.assertion("a]b,c"))

        assertNull(EpubCfi.parse("epubcfi(/6/4)"))
        assertNull(EpubCfi.parse("not a cfi"))
    }

    @Test
    fun resolvesToAReadiumLocatorWithTheNarratedFragment() {
        val document = document()
        val narrated = setOf("s1", "s2")
        fun resolved(cfi: String) = document.resolve(EpubCfi.parse(cfi)!!.local)!!
        fun readium(point: EpubCfi.Point) = EpubCfi.readiumLocator(
            point = point,
            document = document,
            href = "OEBPS/text/ch1.xhtml",
            totalProgression = 0.4,
            overlayFragments = narrated,
        )

        val italic = readium(resolved("epubcfi(/6/4!/4/2/4/4/2/1:2)"))
        val descendant = readium(resolved("epubcfi(/6/4!/4/2/4)"))
        val plain = readium(resolved("epubcfi(/6/4!/4/2/6/3:1)"))

        assertEquals(listOf("s2"), italic.locations()["fragments"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertEquals("#s2", italic.locations()["cssSelector"]!!.jsonPrimitive.content)
        assertEquals(listOf("s1"), descendant.locations()["fragments"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertNull(plain.locations()["fragments"])
        assertTrue(plain.getValue("text").jsonObject.getValue("highlight").jsonPrimitive.content.startsWith("and more words"))
        assertEquals(0.4, plain.locations().getValue("totalProgression").jsonPrimitive.doubleOrNull!!, 0.0)
        val progression = plain.locations().getValue("progression").jsonPrimitive.doubleOrNull!!
        assertTrue(progression > 0.3 && progression < 0.9)
    }

    @Test
    fun packageSpineKeepsNonLinearItemsAndResolvesHrefs() {
        val opf = """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <metadata>
                <meta property="media:duration" refines="#ch-smil">0:01:30.500</meta>
              </metadata>
              <manifest>
                <item id="cover" href="text/cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch" href="text/My%20Chapter.xhtml" media-overlay="ch-smil" media-type="application/xhtml+xml"/>
                <item id="ch-smil" href="../smil/ch.smil" media-type="application/smil+xml"/>
              </manifest>
              <spine>
                <itemref idref="cover" linear="no"/>
                <itemref id="ref-ch" idref="ch"/>
              </spine>
            </package>
        """.trimIndent()
        val epubPackage = EpubPackage.parse(opf, "OEBPS/content.opf")

        assertEquals(6, epubPackage.spineStep)
        assertEquals(listOf("OEBPS/text/cover.xhtml", "OEBPS/text/My Chapter.xhtml"), epubPackage.spine.map { it.href })
        assertEquals(listOf(false, true), epubPackage.spine.map { it.isLinear })
        assertEquals("ref-ch", epubPackage.spine[1].itemrefId)
        assertEquals("smil/ch.smil", epubPackage.spine[1].mediaOverlayHref)
        assertEquals(90.5, epubPackage.spine[1].mediaOverlayDuration!!, 1e-9)
        assertEquals(1, epubPackage.spineIndex("OEBPS/text/My%20Chapter.xhtml#s1"))
        assertEquals(0, epubPackage.spineIndex("text/cover.xhtml"))
    }
}
