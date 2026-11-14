package com.enve.engine.downloads

import kotlinx.coroutines.flow.Flow

enum class DownloadTransferStatus { QUEUED, DOWNLOADING }

data class DownloadTransfer(
    val status: DownloadTransferStatus,
    val progress: Float,
    val downloadedBytes: Long = 0L,
    val totalBytes: Long = 0L,
)

interface DownloadActivityFacade {
    val activeTransfers: Flow<List<DownloadTransfer>>
}
