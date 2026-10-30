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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ArrowDownward
import androidx.compose.material.icons.outlined.ArrowUpward
import androidx.compose.material.icons.outlined.Bookmarks
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.FilterList
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.library.SavedBookList
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.fadeHorizontalEdges
import com.enve.hearth.design.hearthDisplay

private val ShelfStatuses = listOf(
    StatusFilter.ALL,
    StatusFilter.CURRENTLY_READING,
    StatusFilter.UNREAD,
    StatusFilter.FINISHED,
    StatusFilter.DOWNLOADED,
)

private fun shelfTitle(status: StatusFilter): String =
    if (status == StatusFilter.ALL) "Everything" else status.label

@Composable
internal fun ShelvesMenu(
    facet: LibraryFacet,
    status: StatusFilter,
    savedList: SavedBookList?,
    savedCounts: Map<SavedBookList, Int>,
    onStatus: (StatusFilter) -> Unit,
    onSavedList: (SavedBookList) -> Unit,
    onCollections: () -> Unit,
) {
    val palette = Hearth.palette
    var open by remember { mutableStateOf(false) }
    val showingBooks = savedList == null && facet == LibraryFacet.BOOKS
    val showingCollections = savedList == null && facet == LibraryFacet.SHELVES
    val current = when {
        savedList != null -> savedList.title
        showingCollections -> "Collections"
        showingBooks && status != StatusFilter.ALL -> shelfTitle(status)
        else -> null
    }
    val sectionPadding = Modifier.padding(start = Hearth.Spacing.M, end = Hearth.Spacing.M, top = Hearth.Spacing.S, bottom = Hearth.Spacing.XS)
    Box {
        ControlPill(
            icon = Icons.Outlined.Bookmarks,
            label = current ?: "Shelves",
            active = current != null,
            description = "Shelves",
            state = current,
            onClick = { open = true },
        ) {
            Icon(
                Icons.Outlined.ExpandMore,
                contentDescription = null,
                tint = if (current != null) palette.ember else palette.textSecondary,
                modifier = Modifier.size(16.dp),
            )
        }
        LibraryMenu(expanded = open, onDismissRequest = { open = false }) {
            Overline("Status", modifier = sectionPadding)
            ShelfStatuses.forEach { option ->
                LibraryMenuOption(shelfTitle(option), selected = showingBooks && status == option) {
                    open = false
                    onStatus(option)
                }
            }
            Overline("Saved lists", modifier = sectionPadding)
            SavedBookList.entries.forEach { list ->
                val count = savedCounts[list] ?: 0
                LibraryMenuOption(
                    list.title,
                    supportingText = if (count == 1) "1 book" else "$count books",
                    selected = savedList == list,
                ) {
                    open = false
                    onSavedList(list)
                }
            }
            Overline("Collections", modifier = sectionPadding)
            LibraryMenuOption(
                "Collections",
                supportingText = "Server and personal collections",
                selected = showingCollections,
            ) {
                open = false
                onCollections()
            }
        }
    }
}

@Composable
internal fun FilterSortButton(activeFilterCount: Int, onClick: () -> Unit) {
    val palette = Hearth.palette
    val narrowed = activeFilterCount > 0
    ControlPill(
        icon = Icons.Outlined.FilterList,
        label = "Filter & Sort",
        active = narrowed,
        description = "Filter & Sort",
        state = if (narrowed) "$activeFilterCount active ${if (activeFilterCount == 1) "filter" else "filters"}" else null,
        onClick = onClick,
    ) {
        if (narrowed) {
            Box(
                Modifier
                    .sizeIn(minWidth = 18.dp, minHeight = 18.dp)
                    .clip(if (Hearth.eink.sharpCorners) RectangleShape else CircleShape)
                    .background(palette.ember)
                    .padding(horizontal = Hearth.Spacing.XS)
                    .clearAndSetSemantics {},
                contentAlignment = Alignment.Center,
            ) {
                Text("$activeFilterCount", style = HearthText.Overline, color = palette.readableOnEmber)
            }
        }
    }
}

@Composable
private fun ControlPill(
    icon: ImageVector,
    label: String,
    active: Boolean,
    description: String,
    state: String?,
    onClick: () -> Unit,
    trailing: @Composable () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(50)
    val tint = if (active) palette.ember else palette.textSecondary
    val fill = when {
        active && eink.active -> palette.bg
        active -> palette.ember.copy(alpha = 0.16f)
        else -> palette.bgElevated
    }
    val outline = when {
        active && eink.active -> palette.ember
        active -> palette.ember.copy(alpha = 0.5f)
        else -> palette.hairline
    }
    Row(
        Modifier
            .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
            .clip(shape)
            .background(fill)
            .border(if (active && eink.active) 2.dp else 1.dp, outline, shape)
            .semantics {
                contentDescription = description
                state?.let { stateDescription = it }
            }
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
        Text(label, style = HearthText.Caption, color = tint, modifier = Modifier.clearAndSetSemantics {})
        trailing()
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
internal fun FacetRow(selected: LibraryFacet?, onSelect: (LibraryFacet) -> Unit) {
    Row(
        Modifier.fillMaxWidth().fadeHorizontalEdges().horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.L),
        horizontalArrangement = Arrangement.spacedBy(if (Hearth.typeCompact) Hearth.Spacing.XS else Hearth.Spacing.S),
    ) {
        LibraryFacet.entries.filter { it != LibraryFacet.SHELVES }.forEach { f ->
            val isSelected = f == selected
            Box(
                Modifier
                    .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                    .selectable(selected = isSelected, role = Role.Tab) { onSelect(f) }
                    .padding(horizontal = Hearth.Spacing.XS),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    f.name.lowercase().replaceFirstChar { it.uppercase() },
                    style = HearthText.Overline,
                    color = if (isSelected) Hearth.palette.ember else Hearth.palette.textTertiary,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
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
    androidx.compose.material3.ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = androidx.compose.material3.rememberModalBottomSheetState(skipPartiallyExpanded = true),
        shape = sheetShape,
        containerColor = palette.bgElevated,
    ) {
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
            if (sortStack.isEmpty()) {
                Text(
                    "Default order: recent books first.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
            }
            sortStack.forEachIndexed { index, descriptor ->
                SortPriorityRow(
                    index = index,
                    descriptor = descriptor,
                    canMoveUp = index > 0,
                    canMoveDown = index < sortStack.lastIndex,
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

            if (sortStack.isNotEmpty()) {
                Overline("Primary direction")
                Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    SortDirection.entries.forEach { dir ->
                        HearthChip(
                            "${dir.arrow} ${dir.label}",
                            selected = sortStack.first().direction == dir,
                            onClick = { vm.setPrimaryDirection(dir) },
                        )
                    }
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

@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun SortPriorityRow(
    index: Int,
    descriptor: SortDescriptor,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onDirection: (SortDirection) -> Unit,
    onUp: () -> Unit,
    onDown: () -> Unit,
    onRemove: () -> Unit,
) {
    val palette = Hearth.palette
    val sharp = Hearth.eink.sharpCorners
    val shape = if (sharp) RectangleShape else RoundedCornerShape(Hearth.Radius.Inner)
    val field = descriptor.field.label
    val ascending = descriptor.direction == SortDirection.ASCENDING
    val flipped = if (ascending) SortDirection.DESCENDING else SortDirection.ASCENDING
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bg).border(1.dp, palette.hairline, shape)
            .padding(start = Hearth.Spacing.M, end = Hearth.Spacing.XS, top = Hearth.Spacing.S),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            Box(
                Modifier.size(24.dp).clip(if (sharp) RectangleShape else CircleShape).background(palette.ember.copy(alpha = 0.16f)),
                contentAlignment = Alignment.Center,
            ) {
                Text("${index + 1}", style = HearthText.Overline, color = palette.ember)
            }
            Text(field, style = HearthText.Body, color = palette.text, modifier = Modifier.weight(1f))
        }
        androidx.compose.foundation.layout.FlowRow(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(
                Modifier
                    .heightIn(min = 48.dp)
                    .clip(shape)
                    .semantics {
                        contentDescription = "$field order"
                        stateDescription = descriptor.direction.label
                    }
                    .clickable(role = Role.Button, onClickLabel = "Switch to ${flipped.label.lowercase()}") { onDirection(flipped) }
                    .padding(horizontal = Hearth.Spacing.XS),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
            ) {
                Icon(
                    if (ascending) Icons.Outlined.ArrowUpward else Icons.Outlined.ArrowDownward,
                    contentDescription = null,
                    tint = palette.ember,
                    modifier = Modifier.size(18.dp),
                )
                Text(
                    descriptor.direction.label,
                    style = HearthText.Label,
                    color = palette.textSecondary,
                    modifier = Modifier.clearAndSetSemantics {},
                )
            }
            Row {
                SortActionButton(Icons.Outlined.KeyboardArrowUp, "Move $field up", enabled = canMoveUp, onClick = onUp)
                SortActionButton(Icons.Outlined.KeyboardArrowDown, "Move $field down", enabled = canMoveDown, onClick = onDown)
                SortActionButton(Icons.Outlined.Close, "Remove $field sort", enabled = true, onClick = onRemove)
            }
        }
    }
}

@Composable
private fun SortActionButton(icon: ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    IconButton(onClick = onClick, enabled = enabled, modifier = Modifier.size(48.dp)) {
        Icon(
            icon,
            contentDescription = label,
            tint = if (enabled) palette.textSecondary else palette.textTertiary.copy(alpha = 0.4f),
        )
    }
}
