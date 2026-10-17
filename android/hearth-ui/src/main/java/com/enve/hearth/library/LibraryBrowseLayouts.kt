package com.enve.hearth.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items as listItems
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.BrowseGroup
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.hearthDisplay
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

@Composable
internal fun BrowseLayout(groups: List<BrowseGroup>, columns: Int, onOpen: (BrowseGroup) -> Unit) {
    if (columns == 1 || Hearth.eink.denseListLibrary) {
        BrowseList(groups, onOpen)
    } else {
        BrowseGrid(groups, columns, onOpen)
    }
}

@Composable
private fun BrowseGrid(groups: List<BrowseGroup>, columns: Int, onOpen: (BrowseGroup) -> Unit) {
    val palette = Hearth.palette
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns.coerceIn(2, 4)),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL,
            end = Hearth.Spacing.XL,
            bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(groups, key = { it.key }) { group ->
            Column(Modifier.fillMaxWidth().clickable { onOpen(group) }) {
                CoverTile(model = group.coverUrl, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.size(Hearth.Spacing.S))
                Text(
                    group.name,
                    style = hearthDisplay(14.sp, FontWeight.SemiBold),
                    color = palette.text,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    listOfNotNull(
                        "${group.count} ${if (group.count == 1) "book" else "books"}",
                        group.secondary,
                    ).joinToString(" · "),
                    style = HearthText.Caption,
                    color = if (group.secondary == "✓ All read") palette.ember else palette.textTertiary,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun BrowseList(groups: List<BrowseGroup>, onOpen: (BrowseGroup) -> Unit) {
    val palette = Hearth.palette
    LazyColumn(
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        listItems(groups, key = { it.key }) { g ->
            Row(
                Modifier.fillMaxWidth().clickable { onOpen(g) }.padding(vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverTile(model = g.coverUrl, modifier = Modifier.width(44.dp))
                Spacer(Modifier.width(Hearth.Spacing.M))
                Column(Modifier.weight(1f)) {
                    Text(g.name, style = hearthDisplay(17.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    val count = "${g.count} ${if (g.count == 1) "book" else "books"}"
                    Text(listOfNotNull(g.secondary, count).joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary)
                }
            }
        }
    }
}

@Composable
internal fun ShelvesList(
    groups: List<BrowseGroup>,
    canCreate: Boolean,
    onCreate: () -> Unit,
    onOpen: (BrowseGroup) -> Unit,
    onEdit: (BrowseGroup) -> Unit,
    onMove: (BrowseGroup, Int) -> Unit,
) {
    val palette = Hearth.palette
    LazyColumn(
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            start = Hearth.Spacing.XL,
            end = Hearth.Spacing.XL,
            bottom = LocalMantelInset.current + Hearth.Spacing.L,
        ),
        modifier = Modifier.fillMaxSize(),
    ) {
        if (canCreate) {
            item {
                TextButton(onClick = onCreate) { Text("+ New BookOrbit collection", color = palette.ember) }
            }
        }
        listItems(groups, key = { it.key }) { group ->
            Row(
                Modifier.fillMaxWidth().clickable { onOpen(group) }.padding(vertical = Hearth.Spacing.M),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CoverTile(model = group.coverUrl, modifier = Modifier.width(44.dp))
                Spacer(Modifier.width(Hearth.Spacing.M))
                Column(Modifier.weight(1f)) {
                    Text(group.name, style = hearthDisplay(17.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text("${group.count} ${if (group.count == 1) "book" else "books"}", style = HearthText.Caption, color = palette.textSecondary)
                }
                if (group.isEditable) {
                    TextButton(onClick = { onMove(group, -1) }) { Text("↑") }
                    TextButton(onClick = { onMove(group, 1) }) { Text("↓") }
                    TextButton(onClick = { onEdit(group) }) { Text("Edit") }
                }
            }
        }
    }
}

@Composable
internal fun BrowseLoadingState() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Hearth.palette.ember, strokeWidth = 2.dp, modifier = Modifier.size(28.dp))
    }
}

@Composable
internal fun BrowseEmptyState(title: String, message: String) {
    val palette = Hearth.palette
    Box(Modifier.fillMaxSize().padding(horizontal = Hearth.Spacing.XL), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            Text(title, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = palette.text)
            Text(
                message,
                style = HearthText.Caption,
                color = palette.textSecondary,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
        }
    }
}
