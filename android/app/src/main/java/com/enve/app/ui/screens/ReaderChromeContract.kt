package com.enve.app.ui.screens

import com.enve.app.data.reader.ReaderToolbarButton

internal data class ReaderChromeState(
    val title: String,
    val author: String,
    val currentPage: Int,
    val totalPages: Int,
    val hasPageList: Boolean,
    val currentPageLabel: String?,
    val lastPageLabel: String?,
    val progressPct: Int,
    val sectionTitle: String,
    val chromeVisible: Boolean,
    val sliderDragging: Boolean,
    val sliderPreviewPage: Int,
    val sliderPreviewPageLabel: String?,
    val canNavigateBack: Boolean,
    val canNavigateForward: Boolean,
    val readAlongSupported: Boolean,
    val readAlongActive: Boolean,
    val readAlongPlaying: Boolean,
    val ttsEnabled: Boolean,
    val ttsSpeaking: Boolean,
    val moreMenuExpanded: Boolean,
    val toolbarButtons: Set<ReaderToolbarButton>,
)

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

internal data class ReaderChromeActions(
    val onMoreMenuExpandedChange: (Boolean) -> Unit,
    val onBack: () -> Unit,
    val onSearch: () -> Unit,
    val onToc: () -> Unit,
    val onAppearance: () -> Unit,
    val onBookmark: () -> Unit,
    val onAnnotations: () -> Unit,
    val onAddNote: () -> Unit,
    val onAskLibrarian: () -> Unit,
    val onReadAlong: () -> Unit,
    val onTts: () -> Unit,
    val onHistoryBack: () -> Unit,
    val onHistoryForward: () -> Unit,
    val onAutoScroll: () -> Unit,
    val onToolbarCustomize: () -> Unit,
    val onSliderChange: (Float) -> Unit,
    val onSliderDragStart: () -> Unit,
    val onSliderDragEnd: (Float) -> Unit,
    val onSeekProgress: (Float) -> Unit,
    val onSliderDrag: (Boolean, Int) -> Unit,
    val onPagePrev: () -> Unit,
    val onPageNext: () -> Unit,
    val onChromeInteraction: () -> Unit,
)
