package com.enve.app.hearth

import com.enve.app.data.repository.OpdsAcquisition
import com.enve.app.data.repository.OpdsAcquisitionKind
import com.enve.app.data.repository.OpdsDrm
import com.enve.app.data.repository.OpdsFormat
import com.enve.app.data.repository.OpdsIndirectAcquisition
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpdsAcquisitionSelectionTest {

    private val root = "https://opds.example.com/v1/catalog"

    private val epub = acquisition("https://opds.example.com/a.epub", OpdsAcquisitionKind.OPEN_ACCESS)
    private val lcp = acquisition("https://opds.example.com/b.epub", drm = OpdsDrm.LCP)
    private val webpub = acquisition("https://opds.example.com/c.json", format = OpdsFormat.WEBPUB)
    private val borrow = acquisition("https://opds.example.com/borrow", OpdsAcquisitionKind.BORROW)
    private val fulfilment = acquisition(
        "https://opds.example.com/acsm",
        indirect = listOf(OpdsIndirectAcquisition("application/vnd.adobe.adept+xml")),
    )
    private val offsite = acquisition("https://cdn.example.org/d.epub", OpdsAcquisitionKind.OPEN_ACCESS)

    private val stored = listOf(epub, lcp, webpub, borrow, fulfilment, offsite)

    @Test
    fun a_supported_same_origin_download_is_accepted() {
        assertEquals(epub, acceptableOpdsAcquisition(stored, epub.href, root))
    }

    @Test
    fun an_href_the_catalog_never_offered_is_refused() {
        assertNull(acceptableOpdsAcquisition(stored, "https://opds.example.com/injected.epub", root))
        assertNull(acceptableOpdsAcquisition(emptyList(), epub.href, root))
    }

    @Test
    fun an_href_that_leaves_the_configured_catalog_is_refused() {
        assertNull(acceptableOpdsAcquisition(stored, offsite.href, root))
        assertNull(acceptableOpdsAcquisition(stored, epub.href, null))
        assertNull(acceptableOpdsAcquisition(stored, epub.href, "https://evil.example.org"))
    }

    @Test
    fun a_non_http_href_is_refused_before_anything_else() {
        val hostile = acquisition("javascript:alert(1)", OpdsAcquisitionKind.OPEN_ACCESS)

        assertNull(acceptableOpdsAcquisition(stored + hostile, hostile.href, root))
    }

    @Test
    fun drm_unsupported_formats_transactions_and_fulfilment_chains_are_refused() {
        assertNull(acceptableOpdsAcquisition(stored, lcp.href, root))
        assertNull(acceptableOpdsAcquisition(stored, webpub.href, root))
        assertNull(acceptableOpdsAcquisition(stored, borrow.href, root))
        assertNull(acceptableOpdsAcquisition(stored, fulfilment.href, root))
    }

    private fun acquisition(
        href: String,
        kind: OpdsAcquisitionKind = OpdsAcquisitionKind.GENERIC,
        format: OpdsFormat = OpdsFormat.EPUB,
        drm: OpdsDrm = OpdsDrm.NONE,
        indirect: List<OpdsIndirectAcquisition> = emptyList(),
    ) = OpdsAcquisition(
        kind = kind,
        href = href,
        mediaType = "application/epub+zip",
        format = format,
        drm = drm,
        requiresIndirectFetch = indirect.isNotEmpty(),
        indirect = indirect,
    )
}
