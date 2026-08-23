package com.enve.app.ui.screens.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material3.BottomSheetDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.unit.dp
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.ui.screens.ThinSlider
import com.enve.app.ui.screens.pageLabel
import com.enve.app.viewmodel.ComicBackgroundTheme
import com.enve.app.viewmodel.ComicPageFit
import com.enve.app.viewmodel.ComicProgressionMode
import com.enve.app.viewmodel.ComicReaderSettings
import com.enve.app.viewmodel.ComicReaderUiState
import com.enve.app.viewmodel.ComicReadingDirection
import com.enve.app.viewmodel.ComicSpreadMode
import com.enve.hearth.design.EmberAccent
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalHearth
import com.enve.hearth.design.LocalHearthEink
import com.enve.hearth.design.Overline
import kotlin.math.roundToInt

@Composable
fun HearthComicChrome(
    state: ComicReaderUiState,
    baseSettings: ComicReaderSettings,
    visiblePageIndices: List<Int>,
    chromeVisible: Boolean,
    einkActive: Boolean,
    onBack: () -> Unit,
    onToggleBookmark: () -> Unit,
    onOpenSettings: () -> Unit,
    onCloseSettings: () -> Unit,
    onSettingsChange: (ComicReaderSettings) -> Unit,
    onPageChange: (Int) -> Unit,
) {
    val palette = comicChromePalette(state.settings.backgroundTheme, einkActive)
    CompositionLocalProvider(
        LocalHearth provides palette,
        LocalHearthEink provides hearthEinkFor(palette, einkActive),
    ) {
        Box(Modifier.fillMaxSize()) {
            VeilSlot(visible = chromeVisible, fromTop = true) {
                ComicTopVeil(
                    title = state.title,
                    bookmarked = state.currentPage in state.bookmarks,
                    onBack = onBack,
                    onToggleBookmark = onToggleBookmark,
                )
            }
            VeilSlot(visible = chromeVisible && state.pages.isNotEmpty(), fromTop = false) {
                ComicBottomVeil(
                    currentPage = state.currentPage,
                    pageCount = state.pages.size,
                    visiblePageIndices = visiblePageIndices,
                    onPageChange = onPageChange,
                    onOpenSettings = onOpenSettings,
                )
            }
            if (state.showSettingsSheet) {
                HearthComicSettingsSheet(
                    settings = baseSettings,
                    onSettingsChange = onSettingsChange,
                    onDismiss = onCloseSettings,
                )
            }
        }
    }
}

private fun comicChromePalette(bg: ComicBackgroundTheme, eink: Boolean): HearthPalette = readerChromePalette(
    theme = when (bg) {
        ComicBackgroundTheme.WHITE -> ReaderTheme.LIGHT
        ComicBackgroundTheme.BLACK -> ReaderTheme.OLED
        else -> ReaderTheme.DARK
    },
    eink = eink,
    accent = EmberAccent,
)

@Composable
private fun ComicTopVeil(title: String, bookmarked: Boolean, onBack: () -> Unit, onToggleBookmark: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Column(Modifier.fillMaxWidth().background(palette.bg.copy(alpha = if (eink.active) 1f else 0.94f))) {
        Row(
            Modifier.fillMaxWidth().statusBarsPadding()
                .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VeilGlyph(Icons.AutoMirrored.Outlined.ArrowBack, "Close", palette.text, onBack)
            Spacer(Modifier.width(Hearth.Spacing.S))
            Overline(title, modifier = Modifier.weight(1f))
            VeilGlyph(
                if (bookmarked) Icons.Filled.Bookmark else Icons.Filled.BookmarkBorder,
                if (bookmarked) "Remove bookmark" else "Add bookmark",
                if (bookmarked) (if (eink.monochrome) palette.text else palette.ember) else palette.textSecondary,
                onToggleBookmark,
            )
        }
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
    }
}

@Composable
private fun ComicBottomVeil(
    currentPage: Int,
    pageCount: Int,
    visiblePageIndices: List<Int>,
    onPageChange: (Int) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    var scrubTarget by remember { mutableStateOf<Int?>(null) }
    Column(Modifier.fillMaxWidth().background(palette.bg.copy(alpha = if (eink.active) 1f else 0.94f))) {
        if (eink.active) Box(Modifier.fillMaxWidth().height(1.dp).background(palette.hairline))
        Column(
            Modifier.fillMaxWidth().navigationBarsPadding()
                .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            PageRibbon(
                displayPage = scrubTarget ?: currentPage,
                pageCount = pageCount,
                onScrub = { scrubTarget = it },
                onCommit = { scrubTarget = null; onPageChange(it) },
            )
            val target = scrubTarget
            Text(
                if (target != null) "Page ${target + 1} of $pageCount" else pageLabel(visiblePageIndices, pageCount),
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                VeilAction(Icons.Outlined.Tune, "Appearance", onOpenSettings)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HearthComicSettingsSheet(
    settings: ComicReaderSettings,
    onSettingsChange: (ComicReaderSettings) -> Unit,
    onDismiss: () -> Unit,
) {
    val palette = Hearth.palette
    val sheetShape = if (Hearth.eink.sharpCorners) RectangleShape else BottomSheetDefaults.ExpandedShape
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = sheetShape,
        containerColor = palette.bgElevated,
    ) {
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = Hearth.Spacing.XL).padding(bottom = Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            Overline("Page flow")
            ChipRow(ComicProgressionMode.entries, { it.label }, { it == settings.progressionMode }) {
                onSettingsChange(settings.copy(progressionMode = it))
            }

            Overline("Direction")
            ChipRow(ComicReadingDirection.entries, { it.label }, { it == settings.readingDirection }) {
                onSettingsChange(settings.copy(readingDirection = it))
            }

            Overline("Page fit")
            ChipRow(ComicPageFit.entries, { it.label }, { it == settings.pageFit }) {
                onSettingsChange(settings.copy(pageFit = it))
            }

            Overline("Spread")
            ChipRow(ComicSpreadMode.entries, { it.label }, { it == settings.spreadMode }) {
                onSettingsChange(settings.copy(spreadMode = it))
            }

            Overline("Background")
            ChipRow(ComicBackgroundTheme.entries, { it.label }, { it == settings.backgroundTheme }) {
                onSettingsChange(settings.copy(backgroundTheme = it))
            }

            Overline("Brightness")
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                ThinSlider(
                    value = if (settings.brightness < 0f) 0.5f else settings.brightness,
                    onValueChange = { onSettingsChange(settings.copy(brightness = it)) },
                    valueRange = 0.05f..1f,
                    modifier = Modifier.weight(1f),
                    accent = palette.ember,
                )
                Text(
                    if (settings.brightness < 0f) "System" else "${(settings.brightness * 100).roundToInt()}%",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
            }
            if (settings.brightness >= 0f) {
                Text(
                    "Use system brightness", style = HearthText.Label, color = palette.ember,
                    modifier = Modifier.clip(RoundedCornerShape(50))
                        .clickable { onSettingsChange(settings.copy(brightness = -1f)) }
                        .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS),
                )
            }

            HearthToggleRow("Zoom & pan", "Pinch to zoom and pan pages", settings.zoomEnabled) {
                onSettingsChange(settings.copy(zoomEnabled = it))
            }
            HearthToggleRow("Auto-hide controls", "Hide controls while reading", settings.autoHideChrome) {
                onSettingsChange(settings.copy(autoHideChrome = it))
            }
            HearthToggleRow("Volume navigation", "Turn pages with volume buttons", settings.volumeButtonNavigation) {
                onSettingsChange(settings.copy(volumeButtonNavigation = it))
            }
        }
    }
}

@Composable
private fun <T> ChipRow(options: List<T>, label: (T) -> String, selected: (T) -> Boolean, onSelect: (T) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        options.forEach { option ->
            HearthChip(label(option), selected = selected(option), onClick = { onSelect(option) })
        }
    }
}

@Composable
private fun HearthToggleRow(title: String, note: String, checked: Boolean, onCheck: (Boolean) -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Column(Modifier.weight(1f).padding(end = Hearth.Spacing.L)) {
            Text(title, style = HearthText.Body, color = palette.text)
            Text(note, style = HearthText.Caption, color = palette.textSecondary)
        }
        Switch(
            checked = checked,
            onCheckedChange = onCheck,
            colors = SwitchDefaults.colors(checkedTrackColor = palette.ember, checkedThumbColor = palette.readableOnEmber),
        )
    }
}
