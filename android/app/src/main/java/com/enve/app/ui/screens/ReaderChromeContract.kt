package com.enve.app.ui.screens


internal fun readerPositionText(
    currentPosition: Int,
    totalPositions: Int,
    hasPageList: Boolean,
    currentPageLabel: String? = null,
    lastPageLabel: String? = null,
): String {
    if (totalPositions <= 0) return ""
    return if (hasPageList) {
        "Page ${currentPageLabel ?: currentPosition} of ${lastPageLabel ?: totalPositions}"
    } else {
        "Location $currentPosition of $totalPositions"
    }
}
