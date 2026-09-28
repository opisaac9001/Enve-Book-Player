package com.enve.app.data.sync

import com.enve.core.data.sync.KOReaderBookLink
import com.enve.core.data.sync.KOReaderFileIdentity
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class KOReaderHashRepairTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun legacy_link_json_decodes_without_repair_fields() {
        val legacy = """
            [{"bookStableId":"local:x:1","documentHash":"${"1".repeat(32)}",
              "isAutomatic":true,"lastSyncedAt":1700000000000,"lastSyncedPercentage":0.25}]
        """.trimIndent()

        val decoded = json.decodeFromString(ListSerializer(KOReaderBookLink.serializer()), legacy)

        assertEquals(1, decoded.size)
        assertEquals("1".repeat(32), decoded[0].documentHash)
        assertEquals(0.25, decoded[0].lastSyncedPercentage!!, 0.0)
        assertNull(decoded[0].fileIdentity)
        assertNull(decoded[0].filename)
        assertTrue(decoded[0].previousHashes.isEmpty())
    }

    @Test
    fun file_identity_reflects_size_and_is_null_when_missing() {
        val file = File.createTempFile("koreader-repair", ".epub")
        file.writeBytes(ByteArray(4_000) { (it * 37 + 11).toByte() })

        val first = KOReaderFileIdentity.read(file)
        assertEquals(4_000L, first!!.sizeBytes)
        assertEquals(file.absolutePath, first.path)

        file.writeBytes(ByteArray(6_000) { (it * 13 + 7).toByte() })
        assertNotEquals(first, KOReaderFileIdentity.read(file))

        file.delete()
        assertNull(KOReaderFileIdentity.read(file))
    }

    @Test
    fun unchanged_hash_keeps_sync_metadata_and_refreshes_identity() {
        val identity = KOReaderFileIdentity("/tmp/a.epub", 10L, 5L)
        val previous = KOReaderBookLink(
            bookStableId = "book",
            documentHash = "a".repeat(32),
            isAutomatic = true,
            lastSyncedAt = 100L,
            lastSyncedPercentage = 0.4,
        )

        val repaired = KOReaderHubService.repairedLink(
            previous = previous,
            bookStableId = "book",
            documentHash = previous.documentHash,
            isAutomatic = true,
            fileIdentity = identity,
        )

        assertEquals(previous.documentHash, repaired.documentHash)
        assertEquals(100L, repaired.lastSyncedAt)
        assertEquals(0.4, repaired.lastSyncedPercentage!!, 0.0)
        assertEquals(identity, repaired.fileIdentity)
        assertTrue(repaired.previousHashes.isEmpty())
    }

    @Test
    fun changed_hash_records_history_and_resets_sync_metadata() {
        val previous = KOReaderBookLink(
            bookStableId = "book",
            documentHash = "a".repeat(32),
            isAutomatic = true,
            lastSyncedAt = 100L,
            lastSyncedPercentage = 0.4,
            previousHashes = listOf("9".repeat(32)),
        )

        val repaired = KOReaderHubService.repairedLink(
            previous = previous,
            bookStableId = "book",
            documentHash = "b".repeat(32),
            isAutomatic = true,
            fileIdentity = null,
        )

        assertEquals("b".repeat(32), repaired.documentHash)
        assertEquals(listOf("a".repeat(32), "9".repeat(32)), repaired.previousHashes)
        assertNull(repaired.lastSyncedAt)
        assertNull(repaired.lastSyncedPercentage)
    }

    @Test
    fun hash_history_stays_bounded() {
        var link = KOReaderBookLink(
            bookStableId = "book",
            documentHash = "0".repeat(32),
            isAutomatic = true,
        )

        for (marker in "123456789") {
            link = KOReaderHubService.repairedLink(
                previous = link,
                bookStableId = "book",
                documentHash = marker.toString().repeat(32),
                isAutomatic = true,
                fileIdentity = null,
            )
        }

        assertEquals(KOReaderHubService.MAX_HASH_HISTORY, link.previousHashes.size)
        assertEquals("8".repeat(32), link.previousHashes.first())
    }

    @Test
    fun filename_identity_survives_a_binary_hash_change() {
        val previous = KOReaderBookLink(
            bookStableId = "book",
            documentHash = "a".repeat(32),
            isAutomatic = true,
            filename = "Dune.epub",
        )

        val repaired = KOReaderHubService.repairedLink(
            previous = previous,
            bookStableId = "book",
            documentHash = "b".repeat(32),
            isAutomatic = true,
            fileIdentity = null,
        )

        assertEquals("Dune.epub", repaired.filename)
        assertEquals(listOf("a".repeat(32)), repaired.previousHashes)
    }

    @Test
    fun a_filename_only_link_never_records_an_empty_previous_hash() {
        val previous = KOReaderBookLink(
            bookStableId = "book",
            isAutomatic = true,
            filename = "Dune.epub",
        )

        val repaired = KOReaderHubService.repairedLink(
            previous = previous,
            bookStableId = "book",
            documentHash = "b".repeat(32),
            isAutomatic = true,
            fileIdentity = KOReaderFileIdentity("/tmp/b.epub", 20L, 7L),
        )

        assertEquals("b".repeat(32), repaired.documentHash)
        assertEquals("Dune.epub", repaired.filename)
        assertTrue(repaired.previousHashes.isEmpty())
    }

    @Test
    fun manual_pin_drops_the_tracked_file_identity() {
        val previous = KOReaderBookLink(
            bookStableId = "book",
            documentHash = "a".repeat(32),
            isAutomatic = true,
            fileIdentity = KOReaderFileIdentity("/tmp/a.epub", 10L, 5L),
        )

        val pinned = KOReaderHubService.repairedLink(
            previous = previous,
            bookStableId = "book",
            documentHash = "b".repeat(32),
            isAutomatic = false,
            fileIdentity = null,
        )

        assertFalse(pinned.isAutomatic)
        assertNull(pinned.fileIdentity)
        assertEquals(listOf("a".repeat(32)), pinned.previousHashes)
    }
}
