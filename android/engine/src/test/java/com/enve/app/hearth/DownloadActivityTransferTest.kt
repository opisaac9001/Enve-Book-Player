package com.enve.app.hearth

import com.enve.app.data.offline.OfflineDownloadProgress
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.engine.downloads.DownloadTransfer
import com.enve.engine.downloads.DownloadTransferStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DownloadActivityTransferTest {
    @Test
    fun `single-track download exposes byte counts`() {
        val transfer = audio(progress = 0.4f, downloadedBytes = 40L, totalBytes = 100L, completedTracks = 0, totalTracks = 1).toTransfer()

        assertEquals(DownloadTransfer(DownloadTransferStatus.DOWNLOADING, 0.4f, 40L, 100L), transfer)
    }

    @Test
    fun `multi-track download exposes fraction only while total bytes are partial`() {
        val transfer = audio(progress = 0.55f, downloadedBytes = 300L, totalBytes = 350L, completedTracks = 2, totalTracks = 4).toTransfer()

        assertEquals(DownloadTransfer(DownloadTransferStatus.DOWNLOADING, 0.55f), transfer)
    }

    @Test
    fun `queued download without a track plan exposes fraction only`() {
        val transfer = audio(
            status = OfflineDownloadStatus.QUEUED,
            progress = 0f,
            downloadedBytes = 0L,
            totalBytes = 0L,
            completedTracks = 0,
            totalTracks = 0,
        ).toTransfer()

        assertEquals(DownloadTransfer(DownloadTransferStatus.QUEUED, 0f), transfer)
    }

    @Test
    fun `finished downloads are not active transfers`() {
        listOf(OfflineDownloadStatus.COMPLETED, OfflineDownloadStatus.FAILED, OfflineDownloadStatus.CANCELLED).forEach { status ->
            assertNull(audio(status = status, progress = 1f, downloadedBytes = 10L, totalBytes = 10L, completedTracks = 1, totalTracks = 1).toTransfer())
        }
    }

    private fun audio(
        status: OfflineDownloadStatus = OfflineDownloadStatus.DOWNLOADING,
        progress: Float,
        downloadedBytes: Long,
        totalBytes: Long,
        completedTracks: Int,
        totalTracks: Int,
    ) = OfflineDownloadProgress(
        bookId = "book",
        title = "Book",
        status = status,
        progress = progress,
        downloadedBytes = downloadedBytes,
        totalBytes = totalBytes,
        completedTracks = completedTracks,
        totalTracks = totalTracks,
    )
}
