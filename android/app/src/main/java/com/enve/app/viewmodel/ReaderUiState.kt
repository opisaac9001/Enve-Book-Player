package com.enve.app.viewmodel

import com.enve.app.data.reader.LayoutPreset
import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.readium.EbookTTSState
import com.enve.app.readium.narrator.NarratorPack
import com.enve.app.ui.screens.reader.ReaderSelectionBounds
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import org.readium.r2.shared.publication.Locator

data class PageMark(val start: Float, val label: String)

data class ReaderTTSVoice(
    val name: String,
    val label: String,
    val title: String,
    val detail: String,
    val language: String,
    val languageName: String,
)

sealed interface ReaderNarratorPackState {
    data object NotInstalled : ReaderNarratorPackState
    data class Downloading(val progress: Float) : ReaderNarratorPackState
    data object Removing : ReaderNarratorPackState
    data object Installed : ReaderNarratorPackState
    data class Failed(val message: String) : ReaderNarratorPackState
}

data class ReaderUiState(
    val prefs: ReaderPreferences = ReaderPreferences(),
    val showChrome: Boolean = false,
    val annotations: List<ReaderAnnotation> = emptyList(),
    val tocEntries: List<TocEntry> = emptyList(),
    val bookmarks: List<ReaderAnnotation> = emptyList(),
    val layoutPresets: List<LayoutPreset> = emptyList(),
    val totalPages: Int = 0,
    val currentPage: Int = 0,
    val hasPageList: Boolean = false,
    val currentPageLabel: String? = null,
    val lastPageLabel: String? = null,
    val currentSection: String = "",
    val currentTocEntryId: String? = null,
    val tocPageCounts: Map<String, TocPageCount> = emptyMap(),
    val chapterMarks: List<ChapterMark> = emptyList(),
    val pageMarks: List<PageMark> = emptyList(),
    val progressPct: Int = 0,
    val minutesLeftInBook: Int? = null,
    val showAppearanceSheet: Boolean = false,
    val showTocSheet: Boolean = false,
    val showSearchSheet: Boolean = false,
    val search: ReaderSearchState = ReaderSearchState(),
    val showMoreMenu: Boolean = false,
    val showAnnotationDialog: Boolean = false,
    val readAlongSupported: Boolean = false,
    val readAlongActive: Boolean = false,
    val readAlongPlaying: Boolean = false,
    val readAlongClipIndex: Int = 0,
    val readAlongClipCount: Int = 0,
    val showReadAloudSheet: Boolean = false,
    val showReadAloudLyrics: Boolean = false,
    val readAlongChapterClips: List<ReadAloudClipRow> = emptyList(),
    val pendingSelection: Locator? = null,
    val selectionText: String = "",
    val selectionBounds: ReaderSelectionBounds? = null,
    val definition: ReaderDefinition? = null,
    val isReady: Boolean = false,

    val showSelectionPopup: Boolean = false,
    val showAutoScrollPanel: Boolean = false,
    val showToolbarCustomizer: Boolean = false,
    val autoScrollActive: Boolean = false,
    val ttsPlayback: EbookTTSState = EbookTTSState(),
    val ttsReady: Boolean = false,
    val ttsVoices: List<ReaderTTSVoice> = emptyList(),
    val ttsVoice: String? = null,
    val ttsNarratorPack: NarratorPack? = null,
    val ttsNarratorVoice: String? = null,
    val ttsNarratorPacks: Map<NarratorPack, ReaderNarratorPackState> = emptyMap(),
    val showTtsSheet: Boolean = false,
    val ttsControlsVisible: Boolean = false,
    val sliderDragging: Boolean = false,
    val sliderPreviewPage: Int = 0,
    val sliderPreviewPageLabel: String? = null,
    val activeDecorationAnnotation: ReaderAnnotation? = null,
    val undoableDelete: ReaderAnnotation? = null,
    val showAnnotationsSheet: Boolean = false,
    val nextInSeries: Book? = null,
    val pendingProgressConflict: ProgressConflictPrompt? = null,

    val transientMessage: String? = null,

    val readAlongPreparing: Boolean = false,
    val liveReadAlongAvailable: Boolean = false,
    val liveReadAlongActive: Boolean = false,
    val liveReadAlongPlaying: Boolean = false,
    val liveReadAlongPreparing: Boolean = false,
    val liveReadAlongFollowing: Boolean = true,
    val liveReadAlongStatus: String = "",
    val liveReadAlongRetryable: Boolean = false,
    val liveReadAlongFinding: Boolean = false,
    val linkReturnLocator: Locator? = null,
)

data class ReaderDefinition(
    val id: Long,
    val term: String,
    val locator: Locator,
    val chapterTitle: String?,
    val text: String? = null,
    val loading: Boolean = true,
    val saved: Boolean = false,
)

data class ReadAloudClipRow(
    val index: Int,
    val startMs: Long,
    val skippable: Boolean,
    val textHref: String,
    val fragmentId: String?,
    val resourceProgression: Double?,
    val text: String = "",
)
