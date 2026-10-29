package com.enve.hearth.library

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.LocalLibrary
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText

@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun SourceLibraryControls(
    sources: List<BookSource>,
    libraries: List<Library>,
    libraryConnectionLabels: Map<String, String>,
    sourceFilter: BookSource?,
    libraryFilter: String?,
    onSource: (BookSource?) -> Unit,
    onLibrary: (String?) -> Unit,
    modifier: Modifier = Modifier,
) {
    val selectedLibrary = libraries.firstOrNull { it.id == libraryFilter }
    val duplicateLibraryNames = libraries.groupingBy { it.name }.eachCount().filterValues { it > 1 }.keys
    fun librarySupportingText(lib: Library): String? {
        val connection = lib.connectionId?.let(libraryConnectionLabels::get)
        return when {
            lib.name in duplicateLibraryNames && connection != null -> connection
            lib.name in duplicateLibraryNames -> lib.source.displayName
            else -> null
        }
    }
    val allLibrariesTitle = sourceFilter?.let { "All in ${it.displayName}" } ?: "All libraries"
    FlowRow(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        ScopeSelector(
            label = "Source",
            value = sourceFilter?.displayName ?: "All sources",
            icon = Icons.Outlined.Dns,
            active = sourceFilter != null,
        ) { close ->
            LibraryMenuOption("All sources", selected = sourceFilter == null) {
                onSource(null)
                close()
            }
            sources.forEach { source ->
                LibraryMenuOption(source.displayName, selected = sourceFilter == source) {
                    onSource(source)
                    close()
                }
            }
        }
        ScopeSelector(
            label = "Library",
            value = selectedLibrary?.name ?: allLibrariesTitle,
            detail = selectedLibrary?.let { librarySupportingText(it) },
            icon = Icons.Outlined.LocalLibrary,
            active = libraryFilter != null,
        ) { close ->
            LibraryMenuOption(allLibrariesTitle, selected = libraryFilter == null) {
                onLibrary(null)
                close()
            }
            libraries.forEach { lib ->
                LibraryMenuOption(lib.name, supportingText = librarySupportingText(lib), selected = libraryFilter == lib.id) {
                    onLibrary(lib.id)
                    close()
                }
            }
        }
    }
}

@Composable
private fun ScopeSelector(
    label: String,
    value: String,
    icon: ImageVector,
    active: Boolean,
    detail: String? = null,
    menu: @Composable (close: () -> Unit) -> Unit,
) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Inner)
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier
                .heightIn(min = 48.dp)
                .clip(shape)
                .semantics {
                    contentDescription = label
                    stateDescription = listOfNotNull(value, detail).joinToString(", ")
                }
                .clickable(role = Role.Button, onClickLabel = "Choose ${label.lowercase()}") { open = true }
                .padding(horizontal = Hearth.Spacing.XS),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
        ) {
            Icon(icon, contentDescription = null, tint = if (active) palette.ember else palette.textTertiary, modifier = Modifier.size(18.dp))
            Text(
                value,
                style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold),
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 220.dp).clearAndSetSemantics {},
            )
            Icon(Icons.Outlined.ExpandMore, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(18.dp))
        }
        LibraryMenu(expanded = open, onDismissRequest = { open = false }) {
            menu { open = false }
        }
    }
}

@Composable
internal fun LibraryMenu(
    expanded: Boolean,
    onDismissRequest: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val palette = Hearth.palette
    DropdownMenu(
        expanded = expanded,
        onDismissRequest = onDismissRequest,
        modifier = Modifier.widthIn(min = 220.dp, max = 320.dp),
        shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Card),
        containerColor = palette.bgElevated,
        tonalElevation = 0.dp,
        shadowElevation = 0.dp,
        border = BorderStroke(1.dp, palette.hairline),
        content = content,
    )
}

@Composable
internal fun LibraryMenuOption(
    title: String,
    supportingText: String? = null,
    selected: Boolean,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Icon(
            imageVector = if (selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (selected) palette.text else palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                title,
                style = HearthText.Label.copy(fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal),
                color = palette.text,
            )
            supportingText?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Overline, color = palette.textTertiary, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
