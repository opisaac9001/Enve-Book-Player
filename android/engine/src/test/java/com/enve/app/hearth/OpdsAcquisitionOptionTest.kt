package com.enve.app.hearth

import com.enve.app.data.repository.OpdsAcquisition
import com.enve.app.data.repository.OpdsAcquisitionKind
import com.enve.app.data.repository.OpdsAvailability
import com.enve.app.data.repository.OpdsCopies
import com.enve.app.data.repository.OpdsDrm
import com.enve.app.data.repository.OpdsFormat
import com.enve.app.data.repository.OpdsHolds
import com.enve.app.data.repository.OpdsIndirectAcquisition
import com.enve.app.data.repository.OpdsPrice
import com.enve.engine.opds.OpdsAcquisitionAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsAcquisitionOptionTest {

    private fun acquisition(
        kind: OpdsAcquisitionKind = OpdsAcquisitionKind.OPEN_ACCESS,
        format: OpdsFormat = OpdsFormat.EPUB,
        drm: OpdsDrm = OpdsDrm.NONE,
        requiresIndirectFetch: Boolean = false,
        price: OpdsPrice? = null,
        availability: OpdsAvailability? = null,
        copies: OpdsCopies? = null,
        holds: OpdsHolds? = null,
        title: String? = null,
    ) = OpdsAcquisition(
        kind = kind,
        href = "https://opds.example.com/x",
        mediaType = "application/epub+zip",
        format = format,
        drm = drm,
        title = title,
        requiresIndirectFetch = requiresIndirectFetch,
        indirect = if (requiresIndirectFetch) listOf(OpdsIndirectAcquisition("application/epub+zip")) else emptyList(),
        price = price,
        availability = availability,
        copies = copies,
        holds = holds,
    )

    @Test
    fun an_open_access_epub_is_offered_as_a_download() {
        val option = acquisition().toOption()

        assertEquals(OpdsAcquisitionAction.OPEN, option.action)
        assertEquals("Download", option.label)
        assertEquals("EPUB", option.formatLabel)
        assertTrue(option.isActionable)
        assertNull(option.unsupportedReason)
    }

    @Test
    fun each_transactional_rel_keeps_its_own_action() {
        assertEquals(
            OpdsAcquisitionAction.BORROW,
            acquisition(kind = OpdsAcquisitionKind.BORROW).toOption().action,
        )
        assertEquals(OpdsAcquisitionAction.BUY, acquisition(kind = OpdsAcquisitionKind.BUY).toOption().action)
        assertEquals(
            OpdsAcquisitionAction.SUBSCRIBE,
            acquisition(kind = OpdsAcquisitionKind.SUBSCRIBE).toOption().action,
        )
        assertEquals(
            OpdsAcquisitionAction.SAMPLE,
            acquisition(kind = OpdsAcquisitionKind.PREVIEW).toOption().action,
        )
    }

    @Test
    fun a_transactional_link_stays_actionable_even_when_it_needs_a_fulfilment_step() {
        val option = acquisition(
            kind = OpdsAcquisitionKind.BORROW,
            requiresIndirectFetch = true,
        ).toOption()

        assertEquals(OpdsAcquisitionAction.BORROW, option.action)
        assertTrue(option.isActionable)
    }

    @Test
    fun drm_and_readium_packages_are_reported_rather_than_offered() {
        listOf(
            acquisition(drm = OpdsDrm.LCP) to "Readium LCP",
            acquisition(drm = OpdsDrm.ADEPT) to "Adobe DRM",
            acquisition(format = OpdsFormat.AUDIOBOOK_PACKAGE) to "Readium audiobook",
            acquisition(format = OpdsFormat.WEBPUB) to "Readium web publication",
            acquisition(format = OpdsFormat.DIVINA) to "Readium Divina",
        ).forEach { (acquisition, fragment) ->
            val option = acquisition.toOption()
            assertEquals(OpdsAcquisitionAction.UNSUPPORTED, option.action)
            assertFalse(option.isActionable)
            assertTrue(
                "expected \"$fragment\" in ${option.unsupportedReason}",
                option.unsupportedReason.orEmpty().contains(fragment),
            )
        }
    }

    @Test
    fun a_free_download_that_needs_fulfilment_is_not_offered() {
        val option = acquisition(requiresIndirectFetch = true).toOption()

        assertEquals(OpdsAcquisitionAction.UNSUPPORTED, option.action)
        assertEquals("Needs a fulfilment step Enve cannot complete", option.unsupportedReason)
    }

    @Test
    fun the_link_title_wins_over_the_generic_label() {
        assertEquals("Borrow (EPUB)", acquisition(title = "Borrow (EPUB)").toOption().label)
    }

    @Test
    fun price_availability_copies_and_holds_all_reach_the_option() {
        val option = acquisition(
            kind = OpdsAcquisitionKind.BORROW,
            price = OpdsPrice(currency = "USD", value = 4.99),
            availability = OpdsAvailability(state = "unavailable", until = "2026-02-01"),
            copies = OpdsCopies(total = 5, available = 0),
            holds = OpdsHolds(total = 3, position = 2),
        ).toOption()

        assertEquals("$4.99", option.priceLabel)
        val availability = option.availability!!
        assertEquals("unavailable", availability.state)
        assertEquals("2026-02-01", availability.until)
        assertEquals(5, availability.copiesTotal)
        assertEquals(0, availability.copiesAvailable)
        assertEquals(3, availability.holdsTotal)
        assertEquals(2, availability.holdPosition)
    }

    @Test
    fun a_zero_price_reads_as_free_and_an_unknown_currency_falls_back_to_its_code() {
        assertEquals("Free", formatPrice("USD", 0.0))
        assertEquals("9 ZZZ", formatPrice("ZZZ", 9.0))
        assertEquals("3", formatPrice(null, 3.0))
    }
}
