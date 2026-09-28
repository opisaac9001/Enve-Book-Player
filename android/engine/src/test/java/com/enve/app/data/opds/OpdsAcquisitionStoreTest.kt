package com.enve.app.data.opds

import com.enve.app.data.repository.OpdsAcquisition
import com.enve.app.data.repository.OpdsAcquisitionKind
import com.enve.app.data.repository.OpdsAvailability
import com.enve.app.data.repository.OpdsCopies
import com.enve.app.data.repository.OpdsDrm
import com.enve.app.data.repository.OpdsFormat
import com.enve.app.data.repository.OpdsHolds
import com.enve.app.data.repository.OpdsIndirectAcquisition
import com.enve.app.data.repository.OpdsPrice
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsAcquisitionStoreTest {

    private val dao = FakeOpdsAcquisitionDao()
    private val store = OpdsAcquisitionStore(dao)

    private val borrow = OpdsAcquisition(
        kind = OpdsAcquisitionKind.BORROW,
        href = "https://opds.example.com/borrow/1",
        mediaType = "application/atom+xml;type=entry;profile=opds-catalog",
        format = OpdsFormat.EPUB,
        drm = OpdsDrm.LCP,
        title = "Borrow (EPUB)",
        requiresIndirectFetch = true,
        indirect = listOf(
            OpdsIndirectAcquisition(
                type = "application/vnd.readium.lcp.license.v1.0+json",
                children = listOf(OpdsIndirectAcquisition("application/epub+zip")),
            ),
        ),
        price = OpdsPrice(currency = "USD", value = 4.99),
        availability = OpdsAvailability(state = "available", since = "2026-01-01", until = "2026-02-01"),
        copies = OpdsCopies(total = 5, available = 2),
        holds = OpdsHolds(total = 3, position = 1),
    )

    private val free = OpdsAcquisition(
        kind = OpdsAcquisitionKind.OPEN_ACCESS,
        href = "https://opds.example.com/free.epub",
        mediaType = "application/epub+zip",
        format = OpdsFormat.EPUB,
    )

    @Test
    fun every_acquisition_field_survives_the_round_trip_in_order() = runBlocking {
        store.saveAll("conn-1", mapOf("urn:uuid:1" to listOf(borrow, free)))

        val restored = store.acquisitions("conn-1", "urn:uuid:1")
        assertEquals(listOf(borrow, free), restored)
    }

    @Test
    fun a_refresh_replaces_the_previous_rows_rather_than_appending() = runBlocking {
        store.saveAll("conn-1", mapOf("urn:uuid:1" to listOf(borrow, free)))
        store.saveAll("conn-1", mapOf("urn:uuid:1" to listOf(free)))

        assertEquals(listOf(free), store.acquisitions("conn-1", "urn:uuid:1"))
    }

    @Test
    fun rows_are_kept_apart_by_connection_and_book() = runBlocking {
        store.saveAll("conn-1", mapOf("urn:uuid:1" to listOf(free)))
        store.saveAll("conn-2", mapOf("urn:uuid:1" to listOf(borrow)))

        assertEquals(listOf(free), store.acquisitions("conn-1", "urn:uuid:1"))
        assertEquals(listOf(borrow), store.acquisitions("conn-2", "urn:uuid:1"))
        assertTrue(store.acquisitions("conn-1", "urn:uuid:missing").isEmpty())
    }

    @Test
    fun a_publication_with_no_acquisitions_clears_its_rows() = runBlocking {
        store.saveAll("conn-1", mapOf("urn:uuid:1" to listOf(free)))
        store.saveAll("conn-1", mapOf("urn:uuid:1" to emptyList()))

        assertTrue(store.acquisitions("conn-1", "urn:uuid:1").isEmpty())
    }

    @Test
    fun a_page_of_publications_is_written_in_one_transaction() = runBlocking {
        store.saveAll(
            "conn-1",
            mapOf("urn:uuid:1" to listOf(borrow, free), "urn:uuid:2" to listOf(free)),
        )

        assertEquals(1, dao.transactions)
        assertEquals(listOf(borrow, free), store.acquisitions("conn-1", "urn:uuid:1"))
        assertEquals(listOf(free), store.acquisitions("conn-1", "urn:uuid:2"))
    }

    @Test
    fun an_indirect_chain_survives_encoding() {
        val chain = listOf(
            OpdsIndirectAcquisition(
                type = "application/vnd.adobe.adept+xml",
                children = listOf(
                    OpdsIndirectAcquisition("application/epub+zip"),
                    OpdsIndirectAcquisition("application/pdf"),
                ),
            ),
        )

        assertEquals(chain, decodeIndirect(encodeIndirect(chain)))
        assertTrue(decodeIndirect("not json").isEmpty())
    }

    @Test
    fun an_acquisition_with_no_commerce_metadata_stays_null_rather_than_empty() = runBlocking {
        store.saveAll("conn-1", mapOf("urn:uuid:2" to listOf(free)))

        val restored = store.acquisitions("conn-1", "urn:uuid:2").single()
        assertNull(restored.price)
        assertNull(restored.availability)
        assertNull(restored.copies)
        assertNull(restored.holds)
    }
}

private class FakeOpdsAcquisitionDao : OpdsAcquisitionDao {
    private val rows = mutableMapOf<String, OpdsAcquisitionEntity>()

    var transactions: Int = 0
        private set

    override suspend fun forBook(bookKey: String): List<OpdsAcquisitionEntity> =
        rows.values.filter { it.bookKey == bookKey }.sortedBy { it.position }

    override suspend fun insert(rows: List<OpdsAcquisitionEntity>) {
        rows.forEach { this.rows[it.rowKey] = it }
    }

    override suspend fun delete(bookKey: String) {
        rows.values.filter { it.bookKey == bookKey }.forEach { rows.remove(it.rowKey) }
    }

    override suspend fun replaceAll(rowsByBookKey: Map<String, List<OpdsAcquisitionEntity>>) {
        transactions += 1
        super<OpdsAcquisitionDao>.replaceAll(rowsByBookKey)
    }
}
