package com.enve.hearth.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Library
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

@Composable
internal fun QuickShelves(status: StatusFilter, onStatus: (StatusFilter) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        ShelfHeader("Shelves", modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            ShelfShortcut("Everything", "All sources", selected = status == StatusFilter.ALL) { onStatus(StatusFilter.ALL) }
            ShelfShortcut("Currently reading", "All media", selected = status == StatusFilter.CURRENTLY_READING) { onStatus(StatusFilter.CURRENTLY_READING) }
            ShelfShortcut("Unread", "Not marked read", selected = status == StatusFilter.UNREAD) { onStatus(StatusFilter.UNREAD) }
            ShelfShortcut("Read", "Completed", selected = status == StatusFilter.FINISHED) { onStatus(StatusFilter.FINISHED) }
            ShelfShortcut("Downloaded", "On this device", selected = status == StatusFilter.DOWNLOADED) { onStatus(StatusFilter.DOWNLOADED) }
        }
    }
}

@Composable
private fun ShelfShortcut(title: String, line: String, selected: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)

    Column(
        Modifier
            .widthIn(min = 132.dp)
            .clip(shape)
            .background(if (selected) palette.ember.copy(alpha = 0.18f) else palette.bgElevated)
            .border(1.dp, if (selected) palette.ember.copy(alpha = 0.55f) else palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        Text(title, style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = if (selected) palette.ember else palette.text, maxLines = 1)
        Text(line, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1)
    }
}

@Composable
internal fun FloatingSearch(
    query: String,
    onQuery: (String) -> Unit,
    expanded: Boolean,
    onExpandedChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val focusRequester = remember { FocusRequester() }
    val keyboard = LocalSoftwareKeyboardController.current

    Row(
        modifier
            .fillMaxWidth()
            .imePadding()
            .padding(bottom = if (expanded) Hearth.Spacing.M else LocalMantelInset.current)
            .padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.End,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (expanded) {
            LaunchedEffect(Unit) { focusRequester.requestFocus() }
            val shape = RoundedCornerShape(50)
            Row(
                Modifier
                    .weight(1f)
                    .then(if (eink.suppressShadows) Modifier else Modifier.shadow(14.dp, shape, clip = false))
                    .clip(shape)
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, shape)
                    .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Outlined.Search, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(Hearth.Spacing.S))
                Box(Modifier.weight(1f)) {
                    if (query.isEmpty()) {
                        Text("Find a story…", style = hearthDisplay(18.sp, FontWeight.Normal).copy(fontStyle = FontStyle.Italic), color = palette.textTertiary)
                    }
                    BasicTextField(
                        value = query,
                        onValueChange = onQuery,
                        singleLine = true,
                        textStyle = hearthDisplay(18.sp, FontWeight.Normal).copy(color = palette.text),
                        cursorBrush = SolidColor(palette.ember),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { keyboard?.hide() }),
                        modifier = Modifier.fillMaxWidth().focusRequester(focusRequester),
                    )
                }
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = "Close search",
                    tint = palette.textTertiary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable { keyboard?.hide(); onExpandedChange(false) }
                        .padding(Hearth.Spacing.XS)
                        .size(18.dp),
                )
            }
        } else {
            val shape = CircleShape
            Box(
                Modifier
                    .size(54.dp)
                    .then(if (eink.suppressShadows) Modifier else Modifier.shadow(12.dp, shape, clip = false))
                    .clip(shape)
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, shape)
                    .clickable { onExpandedChange(true) },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.Search, contentDescription = "Search the library", tint = palette.ember, modifier = Modifier.size(22.dp))
            }
        }
    }
}

@Composable
internal fun FacetRow(facet: LibraryFacet, onSelect: (LibraryFacet) -> Unit) {

    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.XL),
        horizontalArrangement = Arrangement.spacedBy(if (Hearth.typeCompact) Hearth.Spacing.L else Hearth.Spacing.XL),
    ) {
        LibraryFacet.entries.forEach { f ->
            val selected = f == facet
            Text(
                f.name.lowercase().replaceFirstChar { it.uppercase() },
                style = HearthText.Overline,
                color = if (selected) Hearth.palette.ember else Hearth.palette.textTertiary,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.clickable { onSelect(f) }.padding(vertical = Hearth.Spacing.XS),
            )
        }
    }
}

@Composable
internal fun ChipBar(
    sortStack: List<SortDescriptor>,
    resultCount: Int,
    activeFilterCount: Int,
    usesDefaultSorting: Boolean,
    onOpenSort: () -> Unit,
) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val narrowed = activeFilterCount > 0
        val title = when {
            narrowed -> "Filters $activeFilterCount"
            usesDefaultSorting -> "Filter & Sort"
            else -> "Sort: ${sortStack.firstOrNull()?.field?.label ?: "Recent"}"
        }
        Row(
            Modifier.clip(RoundedCornerShape(50))
                .background(if (narrowed) palette.ember.copy(alpha = 0.16f) else palette.bgElevated)
                .border(1.dp, if (narrowed) palette.ember.copy(alpha = 0.5f) else palette.hairline, RoundedCornerShape(50))
                .clickable(onClick = onOpenSort)
                .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Outlined.FilterList, contentDescription = null, tint = if (narrowed) palette.ember else palette.textSecondary, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(Hearth.Spacing.XS))
            Text(title, style = HearthText.Caption, color = if (narrowed) palette.ember else palette.textSecondary, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        Text(
            if (resultCount == 1) "1 book" else "$resultCount books",
            style = HearthText.Caption,
            color = palette.textTertiary,
            maxLines = 1,
        )
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
internal fun FilterSortSheet(vm: HearthLibraryViewModel, onDismiss: () -> Unit) {
    val palette = Hearth.palette
    val sortStack by vm.sortStack.collectAsStateWithLifecycle()
    val status by vm.status.collectAsStateWithLifecycle()
    val media by vm.media.collectAsStateWithLifecycle()
    val advanced by vm.advancedFilters.collectAsStateWithLifecycle()
    val advancedOptions by vm.advancedFilterOptions.collectAsStateWithLifecycle()
    val sheetShape = if (Hearth.eink.sharpCorners) {
        androidx.compose.ui.graphics.RectangleShape
    } else {
        androidx.compose.material3.BottomSheetDefaults.ExpandedShape
    }
    androidx.compose.material3.ModalBottomSheet(onDismissRequest = onDismiss, shape = sheetShape, containerColor = palette.bgElevated) {
        Column(
            Modifier.fillMaxWidth()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Hearth.Spacing.XL)
                .padding(bottom = Hearth.Spacing.XXL),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Overline("Library")
                    Text("Filter & Sort", style = hearthDisplay(22.sp, FontWeight.SemiBold), color = palette.text)
                }
                Text(
                    "Done", style = HearthText.Label, color = palette.ember,
                    modifier = Modifier.clip(RoundedCornerShape(50)).clickable(onClick = onDismiss)
                        .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
                )
            }

            Overline("Sort priority")
            sortStack.forEachIndexed { index, descriptor ->
                SortPriorityRow(
                    index = index,
                    descriptor = descriptor,
                    canMoveUp = index > 0,
                    canMoveDown = index < sortStack.lastIndex,
                    canRemove = sortStack.size > 1,
                    onDirection = { vm.setSortDirection(descriptor.field, it) },
                    onUp = { vm.moveSortUp(descriptor.field) },
                    onDown = { vm.moveSortDown(descriptor.field) },
                    onRemove = { vm.removeSort(descriptor.field) },
                )
            }

            val unused = LibrarySort.entries.filter { field -> sortStack.none { it.field == field } }
            if (unused.isNotEmpty()) {
                Overline("Add sort")
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                ) {
                    unused.forEach { field ->
                        HearthChip("+ ${field.label}", selected = false, onClick = { vm.addSort(field) })
                    }
                }
            }

            Overline("Primary direction")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                SortDirection.entries.forEach { dir ->
                    HearthChip(
                        "${dir.arrow} ${dir.label}",
                        selected = sortStack.firstOrNull()?.direction == dir,
                        onClick = { vm.setPrimaryDirection(dir) },
                    )
                }
            }

            Overline("Status")
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                StatusFilter.entries.forEach { s ->
                    HearthChip(s.label, selected = s == status, onClick = { vm.setStatus(s) })
                }
            }

            Overline("Media")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                MediaFilter.entries.forEach { m ->
                    HearthChip(m.label, selected = m == media, onClick = { vm.setMedia(m) })
                }
            }

            Overline("Rating")
            androidx.compose.foundation.layout.FlowRow(
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                listOf<Float?>(null, 3f, 4f, 4.5f).forEach { rating ->
                    HearthChip(
                        label = rating?.let { "${"%.1f".format(it)}+ stars" } ?: "Any rating",
                        selected = advanced.minimumRating == rating,
                        onClick = { vm.setMinimumRating(rating) },
                    )
                }
            }

            Overline("Series")
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                SeriesFilter.entries.forEach { series ->
                    HearthChip(
                        series.label,
                        selected = advanced.series == series,
                        onClick = { vm.setSeriesFilter(series) },
                    )
                }
            }

            val genres = (advancedOptions.genres + advanced.genres)
                .distinct()
                .sortedWith(String.CASE_INSENSITIVE_ORDER)
            if (genres.isNotEmpty()) {
                Overline("Genres")
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                ) {
                    genres.forEach { genre ->
                        HearthChip(
                            genre,
                            selected = genre in advanced.genres,
                            onClick = { vm.toggleGenre(genre) },
                        )
                    }
                }
            }

            val languages = (advancedOptions.languages + advanced.languages)
                .distinct()
                .sortedWith(String.CASE_INSENSITIVE_ORDER)
            if (languages.isNotEmpty()) {
                Overline("Languages")
                androidx.compose.foundation.layout.FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
                ) {
                    languages.forEach { language ->
                        HearthChip(
                            language,
                            selected = language in advanced.languages,
                            onClick = { vm.toggleLanguage(language) },
                        )
                    }
                }
            }

            Text(
                "Reset filters and sorting",
                style = HearthText.Label, color = palette.ember,
                modifier = Modifier.clip(RoundedCornerShape(50))
                    .clickable { vm.resetFiltersAndSorting() }
                    .padding(vertical = Hearth.Spacing.M),
            )
        }
    }
}

@Composable
private fun SortPriorityRow(
    index: Int,
    descriptor: SortDescriptor,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    canRemove: Boolean,
    onDirection: (SortDirection) -> Unit,
    onUp: () -> Unit,
    onDown: () -> Unit,
    onRemove: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Box(
            Modifier.size(24.dp).clip(RoundedCornerShape(50)).background(palette.ember.copy(alpha = 0.16f)),
            contentAlignment = Alignment.Center,
        ) {
            Text("${index + 1}", style = HearthText.Overline, color = palette.ember)
        }
        Text(descriptor.field.label, style = HearthText.Body, color = palette.text, modifier = Modifier.weight(1f))
        val flipped = if (descriptor.direction == SortDirection.ASCENDING) SortDirection.DESCENDING else SortDirection.ASCENDING
        RowGlyph(descriptor.direction.arrow, enabled = true) { onDirection(flipped) }
        RowGlyph("▲", enabled = canMoveUp, onClick = onUp)
        RowGlyph("▼", enabled = canMoveDown, onClick = onDown)
        RowGlyph("✕", enabled = canRemove, onClick = onRemove)
    }
}

@Composable
private fun RowGlyph(glyph: String, enabled: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    Text(
        glyph,
        style = HearthText.Label,
        color = if (enabled) palette.textSecondary else palette.textTertiary.copy(alpha = 0.4f),
        modifier = Modifier.clip(RoundedCornerShape(50))
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS),
    )
}
