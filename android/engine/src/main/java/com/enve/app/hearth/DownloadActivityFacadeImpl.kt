package com.enve.app.hearth

import com.enve.app.data.offline.ComicDownloadProgress
import com.enve.app.data.offline.ComicDownloadStatus
import com.enve.app.data.offline.ComicOfflineService
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.OfflineDownloadProgress
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.engine.downloads.DownloadActivityFacade
import com.enve.engine.downloads.DownloadTransfer
import com.enve.engine.downloads.DownloadTransferStatus
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import javax.inject.Inject

class DownloadActivityFacadeImpl @Inject constructor(
    offlineDownloads: OfflineDownloadManager,
    comicOffline: ComicOfflineService,
) : DownloadActivityFacade {
    override val activeTransfers: Flow<List<DownloadTransfer>> =
        combine(offlineDownloads.progressByBookId, comicOffline.progressByBookId) { audio, comic ->
            audio.values.mapNotNull { it.toTransfer() } + comic.values.mapNotNull { it.toTransfer() }
        }.distinctUntilChanged()
}

internal fun OfflineDownloadProgress.toTransfer(): DownloadTransfer? {
    val transferStatus = when (status) {
        OfflineDownloadStatus.QUEUED -> DownloadTransferStatus.QUEUED
        OfflineDownloadStatus.DOWNLOADING -> DownloadTransferStatus.DOWNLOADING
        OfflineDownloadStatus.COMPLETED, OfflineDownloadStatus.FAILED, OfflineDownloadStatus.CANCELLED -> return null
    }
    val fraction = progress.coerceIn(0f, 1f)
    if (totalTracks != 1) return DownloadTransfer(transferStatus, fraction)
    return DownloadTransfer(transferStatus, fraction, downloadedBytes, totalBytes)
}

private fun ComicDownloadProgress.toTransfer(): DownloadTransfer? {
    val transferStatus = when (status) {
        ComicDownloadStatus.QUEUED -> DownloadTransferStatus.QUEUED
        ComicDownloadStatus.DOWNLOADING -> DownloadTransferStatus.DOWNLOADING
        ComicDownloadStatus.COMPLETED, ComicDownloadStatus.FAILED, ComicDownloadStatus.CANCELLED -> return null
    }
    return DownloadTransfer(transferStatus, progress.coerceIn(0f, 1f))
}
