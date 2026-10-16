package com.enve.hearth.library

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.RadioButtonUnchecked
import androidx.compose.material.icons.filled.CheckCircle
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import androidx.compose.ui.text.font.FontWeight

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
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        SelectorPill(
            label = "Source",
            value = sourceFilter?.displayName ?: "All sources",
            options = listOf(
                SelectorOption(
                    title = "All sources",
                    selected = sourceFilter == null,
                    onSelect = { onSource(null) },
                ),
            ) + sources.map { source ->
                SelectorOption(
                    title = source.displayName,
                    selected = sourceFilter == source,
                    onSelect = { onSource(source) },
                )
            },
            active = sourceFilter != null,
            modifier = Modifier.weight(1f),
        )
        SelectorPill(
            label = "Library",
            value = when {
                selectedLibrary != null -> selectedLibrary.name
                sourceFilter != null -> "All in ${sourceFilter.displayName}"
                else -> "All libraries"
            },
            options = listOf(
                SelectorOption(
                    title = if (sourceFilter != null) "All in ${sourceFilter.displayName}" else "All libraries",
                    selected = libraryFilter == null,
                    onSelect = { onLibrary(null) },
                ),
            ) + libraries.map { lib ->
                SelectorOption(
                    title = lib.name,
                    supportingText = librarySupportingText(lib),
                    selected = libraryFilter == lib.id,
                    onSelect = { onLibrary(lib.id) },
                )
            },
            active = libraryFilter != null || sourceFilter != null,
            modifier = Modifier.weight(1f),
        )
    }
}

private data class SelectorOption(
    val title: String,
    val supportingText: String? = null,
    val selected: Boolean = false,
    val onSelect: () -> Unit,
)

@Composable
private fun SelectorPill(
    label: String,
    value: String,
    options: List<SelectorOption>,
    active: Boolean,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(22.dp)
    var open by remember { mutableStateOf(false) }
    Box(modifier) {
        Row(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(palette.bgElevated)
                .border(1.dp, if (active) palette.ember.copy(alpha = 0.45f) else palette.hairline, shape)
                .clickable { open = true }
                .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            Box(
                Modifier
                    .size(10.dp)
                    .clip(RoundedCornerShape(999.dp))
                    .background(if (active) palette.ember else palette.textTertiary.copy(alpha = 0.45f)),
            )
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Text(label, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1)
                Text(
                    value,
                    style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        DropdownMenu(
            expanded = open,
            onDismissRequest = { open = false },
            shape = RoundedCornerShape(28.dp),
            containerColor = palette.bgElevated,
            tonalElevation = 0.dp,
            shadowElevation = 0.dp,
            border = BorderStroke(1.dp, palette.hairline),
        ) {
            Column(Modifier.widthIn(min = 220.dp, max = 280.dp).padding(vertical = Hearth.Spacing.S)) {
                options.forEach { option ->
                    SelectorMenuRow(
                        option = option,
                        onClick = {
                            option.onSelect()
                            open = false
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun SelectorMenuRow(option: SelectorOption, onClick: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Icon(
            imageVector = if (option.selected) Icons.Filled.CheckCircle else Icons.Filled.RadioButtonUnchecked,
            contentDescription = null,
            tint = if (option.selected) palette.text else palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                option.title,
                style = HearthText.Label.copy(fontWeight = if (option.selected) FontWeight.SemiBold else FontWeight.Normal),
                color = palette.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            option.supportingText?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
