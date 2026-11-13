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
        "Page ${currentPageLabel?.let(::printedPageLabel) ?: currentPosition} of ${lastPageLabel?.let(::printedPageLabel) ?: totalPositions}"
    } else {
        "Location $currentPosition of $totalPositions"
    }
}

internal fun readingTimeLeft(minutes: Int): String =
    if (minutes >= 60) "~${minutes / 60}h ${minutes % 60}m left" else "~${minutes}m left"

internal fun printedPageLabel(label: String): String =
    label.trim().removeSurrounding("[", "]").removeSurrounding("(", ")").trim().ifEmpty { label }
