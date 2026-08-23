package com.enve.core.data.sync

data class SyncSnapshot(
    val percentage: Float,
    val positionMs: Long? = null,
    val locatorJson: String? = null,
    val epubCfi: String? = null,
    val href: String? = null,
    val source: String,

    val updatedAt: Long? = null,

    val finished: Boolean = false,
)
