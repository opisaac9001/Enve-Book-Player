package com.enve.hearth.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.BrowseGroup
import com.enve.engine.library.BookOrbitCollectionEdit
import com.enve.engine.library.LibraryConnectionOption
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText

internal enum class BulkAction(val title: String, val confirmLabel: String) {
    MARK_READ("Mark selected books as read?", "Mark read"),
    HIDE("Hide selected books?", "Hide"),
    ;

    fun message(count: Int): String = when (this) {
        MARK_READ -> "This will update the reading status for $count selected ${if (count == 1) "book" else "books"}."
        HIDE -> "This will hide $count selected ${if (count == 1) "book" else "books"} from the library."
    }
}

@Composable
internal fun HeaderGlyph(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    Icon(
        icon, contentDescription = label, tint = Hearth.palette.textSecondary,
        modifier = Modifier.clip(RoundedCornerShape(50)).alpha(if (enabled) 1f else 0.4f).clickable(enabled = enabled, onClick = onClick).padding(Hearth.Spacing.S).size(22.dp),
    )
}

@Composable
internal fun BulkActionBar(
    count: Int,
    canDownload: Boolean,
    onSelectAll: () -> Unit,
    onPlay: () -> Unit,
    onDownload: () -> Unit,
    onCollections: () -> Unit,
    onQueue: () -> Unit,
    onFinished: () -> Unit,
    onHide: () -> Unit,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Bar)
    var menuExpanded by remember { mutableStateOf(false) }
    Row(
        modifier.padding(horizontal = Hearth.Spacing.XL).fillMaxWidth().clip(shape)
            .background(palette.bgElevated).border(1.dp, palette.hairline, shape)
            .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Text("$count selected", style = HearthText.Label, color = palette.ember, modifier = Modifier.weight(1f))
        HeaderGlyph(Icons.Filled.PlayArrow, "Play selected", onClick = onPlay)
        if (canDownload) HeaderGlyph(Icons.Outlined.Download, "Download selected", onClick = onDownload)
        HeaderGlyph(Icons.Outlined.Folder, "Add selected to collection", onClick = onCollections)
        Box {
            HeaderGlyph(Icons.Outlined.MoreVert, "More selection actions") { menuExpanded = true }
            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                DropdownMenuItem(
                    text = { Text("Select all") },
                    onClick = { menuExpanded = false; onSelectAll() },
                )
                DropdownMenuItem(
                    text = { Text("Add to Up Next") },
                    onClick = { menuExpanded = false; onQueue() },
                )
                DropdownMenuItem(
                    text = { Text("Mark as read") },
                    onClick = { menuExpanded = false; onFinished() },
                )
                DropdownMenuItem(
                    text = { Text("Hide from library") },
                    onClick = { menuExpanded = false; onHide() },
                )
            }
        }
        HeaderGlyph(Icons.Outlined.Close, "Cancel selection", onClick = onCancel)
    }
}

@Composable
internal fun BatchCollectionPickerDialog(
    state: BatchCollectionPickerState,
    onDismiss: () -> Unit,
    onSelect: (BrowseGroup) -> Unit,
    onCreate: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add to BookOrbit collection") },
        text = {
            when {
                state.isLoading -> Box(Modifier.fillMaxWidth().padding(Hearth.Spacing.XL), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Hearth.palette.ember, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
                }
                state.connection == null -> Text("No editable BookOrbit collections are available.")
                else -> Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    TextButton(onClick = onCreate) { Text("+ New collection", color = Hearth.palette.ember) }
                    if (state.collections.isEmpty()) {
                        Text("Create a collection for the selected books.", style = HearthText.Body, color = Hearth.palette.textSecondary)
                    } else {
                        Column(Modifier.fillMaxWidth().heightIn(max = 360.dp).verticalScroll(rememberScrollState())) {
                            state.collections.forEach { collection ->
                                Row(
                                    Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner))
                                        .clickable { onSelect(collection) }
                                        .padding(horizontal = Hearth.Spacing.M, vertical = Hearth.Spacing.M),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Column(Modifier.weight(1f)) {
                                        Text(collection.name, style = HearthText.Body, color = Hearth.palette.text)
                                        Text(
                                            "${collection.count} ${if (collection.count == 1) "book" else "books"}",
                                            style = HearthText.Caption,
                                            color = Hearth.palette.textSecondary,
                                        )
                                    }
                                    Text("+", style = HearthText.Label, color = Hearth.palette.ember)
                                }
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
internal fun BookOrbitCollectionDialog(
    collection: BrowseGroup?,
    connections: List<LibraryConnectionOption>,
    onDismiss: () -> Unit,
    onSave: (String, BookOrbitCollectionEdit) -> Unit,
    onDelete: (() -> Unit)? = null,
) {
    var name by remember(collection?.key) { mutableStateOf(collection?.name.orEmpty()) }
    var description by remember(collection?.key) { mutableStateOf(collection?.description.orEmpty()) }
    var icon by remember(collection?.key) { mutableStateOf(collection?.icon ?: "FolderOpen") }
    var syncToKobo by remember(collection?.key) { mutableStateOf(collection?.syncToKobo ?: false) }
    var connectionId by remember(collection?.key, connections) {
        mutableStateOf(collection?.sourceConnectionId ?: connections.firstOrNull()?.id.orEmpty())
    }
    var connectionMenu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }

    if (!confirmDelete) AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (collection == null) "New BookOrbit collection" else "Edit collection") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                if (collection == null && connections.size > 1) {
                    Box {
                        TextButton(onClick = { connectionMenu = true }) {
                            Text(connections.firstOrNull { it.id == connectionId }?.name ?: "Choose server")
                        }
                        DropdownMenu(expanded = connectionMenu, onDismissRequest = { connectionMenu = false }) {
                            connections.forEach { connection ->
                                DropdownMenuItem(
                                    text = { Text(connection.name) },
                                    onClick = { connectionId = connection.id; connectionMenu = false },
                                )
                            }
                        }
                    }
                }
                OutlinedTextField(value = name, onValueChange = { name = it }, label = { Text("Name") }, singleLine = true)
                OutlinedTextField(value = description, onValueChange = { description = it }, label = { Text("Description") }, minLines = 2)
                OutlinedTextField(value = icon, onValueChange = { icon = it }, label = { Text("Icon") }, singleLine = true)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Sync to Kobo", modifier = Modifier.weight(1f))
                    Switch(checked = syncToKobo, onCheckedChange = { syncToKobo = it })
                }
                if (onDelete != null) {
                    TextButton(onClick = { confirmDelete = true }) {
                        Text("Delete collection", color = Hearth.palette.statusError)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = name.isNotBlank() && connectionId.isNotBlank(),
                onClick = {
                    onSave(
                        connectionId,
                        BookOrbitCollectionEdit(
                            name = name.trim(),
                            description = description.trim().ifBlank { null },
                            icon = icon.trim().ifBlank { "FolderOpen" },
                            syncToKobo = syncToKobo,
                        ),
                    )
                },
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )

    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete this collection?") },
            text = { Text("This permanently deletes \"$name\" from BookOrbit. Books in the collection remain in the library.") },
            confirmButton = {
                TextButton(onClick = { confirmDelete = false; onDelete?.invoke() }) {
                    Text("Delete", color = Hearth.palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}
