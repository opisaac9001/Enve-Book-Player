package com.enve.hearth.shell

import com.enve.engine.downloads.DownloadTransfer
import com.enve.engine.downloads.DownloadTransferStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadProgressPillTest {

    @Test
    fun hidesWithoutActiveTransfers() {
        assertNull(downloadPillSummary(emptyList()))
    }

    @Test
    fun reportsQueuedOnlyTransfers() {
        val summary = downloadPillSummary(listOf(queued(), queued()))!!

        assertFalse(summary.transferring)
        assertEquals("2 queued", summary.label)
        assertEquals("2 items queued", summary.accessibilityValue)
    }

    @Test
    fun treatsUnstartedTransferAsIndeterminate() {
        val summary = downloadPillSummary(listOf(downloading(0f), queued()))!!

        assertTrue(summary.transferring)
        assertNull(summary.fraction)
        assertEquals("Downloading 2", summary.label)
        assertEquals("2 items, starting", summary.accessibilityValue)
    }

    @Test
    fun weightsByBytesWhenEveryTransferKnowsItsSize() {
        val summary = downloadPillSummary(
            listOf(
                downloading(0.5f, downloadedBytes = 50, totalBytes = 100),
                DownloadTransfer(DownloadTransferStatus.QUEUED, 0f, totalBytes = 300),
            ),
        )!!

        assertEquals(0.125f, summary.fraction!!, 0.0001f)
        assertEquals("2 items, 13 percent", summary.accessibilityValue)
    }

    @Test
    fun averagesProgressWhenAnySizeIsUnknown() {
        val summary = downloadPillSummary(listOf(downloading(0.8f, downloadedBytes = 80, totalBytes = 100), downloading(0.4f)))!!

        assertEquals(0.6f, summary.fraction!!, 0.0001f)
    }

    @Test
    fun labelsSingleTransfer() {
        val summary = downloadPillSummary(listOf(downloading(1.2f)))!!

        assertEquals("Downloading", summary.label)
        assertEquals(1f, summary.fraction!!, 0f)
        assertEquals("1 item, 100 percent", summary.accessibilityValue)
    }

    private fun queued() = DownloadTransfer(DownloadTransferStatus.QUEUED, 0f)

    private fun downloading(progress: Float, downloadedBytes: Long = 0, totalBytes: Long = 0) =
        DownloadTransfer(DownloadTransferStatus.DOWNLOADING, progress, downloadedBytes, totalBytes)
}
