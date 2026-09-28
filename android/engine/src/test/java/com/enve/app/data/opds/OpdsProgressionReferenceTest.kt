package com.enve.app.data.opds

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpdsProgressionReferenceTest {

    @Test
    fun classifies_an_audio_media_fragment() {
        val reference = OpdsProgressionReferences.parse("#t=849.250")

        assertNull(reference.resource)
        assertEquals(849.250, (reference.target as OpdsProgressionTarget.Time).seconds, 1e-6)
    }

    @Test
    fun reads_normal_play_time_clocks_and_ranges() {
        assertEquals(90.0, seconds("#t=npt:00:01:30"), 1e-6)
        assertEquals(3661.5, seconds("#t=1:01:01.5"), 1e-6)
        assertEquals(10.0, seconds("#t=10,20"), 1e-6)
        assertEquals(0.0, seconds("#t=,20"), 1e-6)
        assertEquals(
            OpdsProgressionTarget.Unknown("t=soon"),
            OpdsProgressionReferences.parse("#t=soon").target,
        )
    }

    @Test
    fun classifies_resource_paths_html_ids_and_pdf_pages() {
        val resource = OpdsProgressionReferences.parse("chapter5.html")
        assertEquals("chapter5.html", resource.resource)
        assertEquals(OpdsProgressionTarget.Resource, resource.target)

        val id = OpdsProgressionReferences.parse("chapter1.html#par36")
        assertEquals("chapter1.html", id.resource)
        assertEquals(OpdsProgressionTarget.Id("par36"), id.target)

        val page = OpdsProgressionReferences.parse("#page=87")
        assertEquals(OpdsProgressionTarget.Page(87), page.target)

        val absolute = OpdsProgressionReferences.parse("https://example.com/chapter1#par26")
        assertEquals("https://example.com/chapter1", absolute.resource)
        assertEquals(OpdsProgressionTarget.Id("par26"), absolute.target)
    }

    @Test
    fun keeps_scroll_to_text_directives_verbatim_and_exposes_the_quote() {
        val simple = OpdsProgressionReferences.parse("chapter1.html#:~:text=It%20was%20expected")
        val target = simple.target as OpdsProgressionTarget.Text
        assertEquals("text=It%20was%20expected", target.directive)
        assertEquals("It was expected", target.start)

        val anchored = OpdsProgressionReferences
            .parse("chapter1.html#:~:text=before-,It%20was,-after")
            .target as OpdsProgressionTarget.Text
        assertEquals("It was", anchored.start)
    }

    @Test
    fun carries_a_cfi_as_an_opaque_reference_that_round_trips() {
        val cfi = "epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)"
        val reference = OpdsProgressionReferences.cfi("chapter1.html", cfi)

        assertEquals("chapter1.html#epubcfi(/6/4%5Bchap01ref%5D!/4%5Bbody01%5D/10%5Bpara05%5D/3:10)", reference.raw)
        assertEquals("chapter1.html", reference.resource)
        assertEquals(OpdsProgressionTarget.Cfi(cfi), reference.target)
        assertEquals(reference, OpdsProgressionReferences.parse(reference.raw))
    }

    @Test
    fun keeps_unrecognised_fragments_intact() {
        val reference = OpdsProgressionReferences.parse("cover.jpg#xywh=160,120,320,240")

        assertEquals("cover.jpg", reference.resource)
        assertEquals(OpdsProgressionTarget.Unknown("xywh=160,120,320,240"), reference.target)
        assertEquals("cover.jpg#xywh=160,120,320,240", reference.raw)
    }

    @Test
    fun builders_emit_the_forms_used_by_the_draft_examples() {
        assertEquals("#t=67", OpdsProgressionReferences.time(67.0).raw)
        assertEquals("#t=40.274", OpdsProgressionReferences.time(40.274).raw)
        assertEquals("#page=6", OpdsProgressionReferences.page(6).raw)
        assertEquals("chapter5.html", OpdsProgressionReferences.resource("chapter5.html").raw)
        assertEquals("chapter1.html#par36", OpdsProgressionReferences.id("chapter1.html", "par36").raw)
        assertEquals(
            "chapter1.html#:~:text=It%20was%20expected",
            OpdsProgressionReferences.text("chapter1.html", "It was expected").raw,
        )
    }

    private fun seconds(raw: String): Double =
        (OpdsProgressionReferences.parse(raw).target as OpdsProgressionTarget.Time).seconds
}
