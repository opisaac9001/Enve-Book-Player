package com.enve.hearth.detail

import android.content.ClipData
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.LocalClipboard
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.engine.library.LibraryDownloadState
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.engine.library.BookOrbitCollectionMembership
import com.enve.hearth.MarkUnreadDialog
import com.enve.hearth.design.CoverTile
import com.enve.hearth.needsUnreadConfirmation
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Ribbon
import com.enve.hearth.design.hearthDisplay
import kotlinx.coroutines.launch

@Composable
internal fun DetailSecondaryActions(
    b: Book,
    vm: HearthDetailViewModel,
    downloadState: LibraryDownloadState,
    counterpart: Book?,
    counterpartDownloadState: LibraryDownloadState,
    metadataEditSupported: Boolean,
    onHidden: () -> Unit,
    onAskLibrarian: (Book) -> Unit,
    onEditMetadata: () -> Unit,
    onFindBetterMatch: () -> Unit,
    onLinkEditions: () -> Unit,
    onAudiobookshelfHistory: () -> Unit,
    canManageBookOrbitCollections: Boolean,
    onBookOrbitCollections: () -> Unit,
    isFavorite: Boolean,
    isForLater: Boolean,
    onToggleFavorite: () -> Unit,
    onToggleForLater: () -> Unit,
    onDelete: () -> Unit,
) {
    val palette = Hearth.palette
    val clipboard = LocalClipboard.current
    val coroutineScope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var confirmRemoveDownload by remember(b.uniqueKey) { mutableStateOf(false) }
    var confirmRemoveCounterpart by remember(b.uniqueKey) { mutableStateOf(false) }
    var confirmResetProgress by remember(b.uniqueKey) { mutableStateOf(false) }
    var confirmMarkUnread by remember(b.uniqueKey) { mutableStateOf(false) }
    var confirmHide by remember(b.uniqueKey) { mutableStateOf(false) }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.M),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DownloadStatusPill(
            book = b,
            state = downloadState,
            formatLabel = if (counterpart?.source == BookSource.GRIMMORY) {
                if (b.mediaType == AppMediaType.AUDIOBOOK) "audiobook" else "ebook"
            } else null,
            onClick = {
                if (b.isDownloaded || downloadState.status == LibraryDownloadStatus.COMPLETED) confirmRemoveDownload = true
                else vm.toggleDownload()
            },
        )
        FinishedStatusPill(
            finished = b.isFinished,
            onClick = vm::toggleFinished,
        )
        Box {
            Box(
                Modifier.size(52.dp)
                    .clip(CircleShape)
                    .background(palette.bgElevated)
                    .border(1.dp, palette.hairline, CircleShape)
                    .clickable { menu = true },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.MoreHoriz,
                    contentDescription = "More",
                    tint = palette.textSecondary,
                    modifier = Modifier.size(22.dp),
                )
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text(if (isFavorite) "Remove from Favorites" else "Add to Favorites") }, onClick = {
                    menu = false
                    onToggleFavorite()
                })
                DropdownMenuItem(text = { Text(if (isForLater) "Remove from For Later" else "Add to For Later") }, onClick = {
                    menu = false
                    onToggleForLater()
                })
                DropdownMenuItem(text = { Text("Copy title") }, onClick = {
                    menu = false
                    coroutineScope.launch {
                        clipboard.setClipEntry(ClipEntry(ClipData.newPlainText("Book title", b.title)))
                    }
                })
                DropdownMenuItem(text = { Text("Ask Librarian") }, onClick = {
                    menu = false
                    onAskLibrarian(b)
                })
                DropdownMenuItem(text = { Text("Edit metadata") }, onClick = {
                    menu = false
                    if (metadataEditSupported) onEditMetadata() else vm.metadataEditUnavailable()
                })
                DropdownMenuItem(text = { Text("Find a better match") }, onClick = {
                    menu = false
                    onFindBetterMatch()
                })
                DropdownMenuItem(text = { Text("Link ebook/audiobook") }, onClick = {
                    menu = false
                    onLinkEditions()
                })
                if (b.source == BookSource.GRIMMORY && b.mediaType == AppMediaType.AUDIOBOOK) {
                    DropdownMenuItem(text = { Text("Share listening history with Audiobookshelf") }, onClick = {
                        menu = false
                        onAudiobookshelfHistory()
                    })
                }
                DropdownMenuItem(text = { Text("Fetch chapters") }, onClick = {
                    menu = false
                    vm.fetchChaptersFromMenu()
                })
                DropdownMenuItem(text = { Text("Reset progress") }, onClick = { menu = false; confirmResetProgress = true })
                DropdownMenuItem(text = { Text("Mark as unread") }, onClick = {
                    menu = false
                    if (b.needsUnreadConfirmation()) confirmMarkUnread = true else vm.markUnread()
                })
                if (canManageBookOrbitCollections) {
                    DropdownMenuItem(text = { Text("BookOrbit collections") }, onClick = {
                        menu = false
                        onBookOrbitCollections()
                    })
                }
                DropdownMenuItem(text = { Text("Hide from library") }, onClick = { menu = false; confirmHide = true })
                DropdownMenuItem(text = { Text("Delete from library") }, onClick = { menu = false; onDelete() })
            }
        }
    }
    if (counterpart?.source == BookSource.GRIMMORY) {
        Box(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S), contentAlignment = Alignment.Center) {
            DownloadStatusPill(
                book = counterpart,
                state = counterpartDownloadState,
                formatLabel = if (counterpart.mediaType == AppMediaType.AUDIOBOOK) "audiobook" else "ebook",
                onClick = {
                    if (counterpart.isDownloaded || counterpartDownloadState.status == LibraryDownloadStatus.COMPLETED) confirmRemoveCounterpart = true
                    else vm.toggleCounterpartDownload()
                },
            )
        }
    }
    if (confirmRemoveDownload) {
        AlertDialog(
            onDismissRequest = { confirmRemoveDownload = false },
            title = { Text("Remove download?") },
            text = { Text("This removes the downloaded files for \"${b.title}\" from this device.") },
            confirmButton = {
                TextButton(onClick = { confirmRemoveDownload = false; vm.removeDownload() }) {
                    Text("Remove", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmRemoveDownload = false }) { Text("Cancel") } },
        )
    }
    if (confirmRemoveCounterpart && counterpart != null) {
        AlertDialog(
            onDismissRequest = { confirmRemoveCounterpart = false },
            title = { Text("Remove ${if (counterpart.mediaType == AppMediaType.AUDIOBOOK) "audiobook" else "ebook"} download?") },
            text = { Text("This removes the downloaded files for \"${counterpart.title}\" from this device.") },
            confirmButton = {
                TextButton(onClick = { confirmRemoveCounterpart = false; vm.removeCounterpartDownload() }) {
                    Text("Remove", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmRemoveCounterpart = false }) { Text("Cancel") } },
        )
    }
    if (confirmResetProgress) {
        AlertDialog(
            onDismissRequest = { confirmResetProgress = false },
            title = { Text("Reset reading progress?") },
            text = { Text("This resets saved progress for \"${b.title}\" locally and on its connected server.") },
            confirmButton = {
                TextButton(onClick = { confirmResetProgress = false; vm.resetProgress() }) {
                    Text("Reset", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmResetProgress = false }) { Text("Cancel") } },
        )
    }
    if (confirmMarkUnread) {
        MarkUnreadDialog(
            book = b,
            onConfirm = { confirmMarkUnread = false; vm.markUnread() },
            onDismiss = { confirmMarkUnread = false },
        )
    }
    if (confirmHide) {
        AlertDialog(
            onDismissRequest = { confirmHide = false },
            title = { Text("Hide from library?") },
            text = { Text("This hides \"${b.title}\" from Enve's library.") },
            confirmButton = {
                TextButton(onClick = { confirmHide = false; vm.hide(); onHidden() }) {
                    Text("Hide", color = palette.statusError)
                }
            },
            dismissButton = { TextButton(onClick = { confirmHide = false }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun BookOrbitMembershipDialog(
    book: Book,
    memberships: List<BookOrbitCollectionMembership>,
    onDismiss: () -> Unit,
    onChange: (String, Boolean) -> Unit,
) {
    var pendingRemoval by remember { mutableStateOf<BookOrbitCollectionMembership?>(null) }

    if (pendingRemoval == null) {
        AlertDialog(
            onDismissRequest = onDismiss,
            title = { Text("BookOrbit collections") },
            text = {
                Column {
                    memberships.forEach { membership ->
                        Row(
                            Modifier.fillMaxWidth().clickable {
                                if (membership.containsBook) pendingRemoval = membership
                                else onChange(membership.collection.key, true)
                            }.padding(vertical = Hearth.Spacing.M),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(membership.collection.name, modifier = Modifier.weight(1f))
                            Text(if (membership.containsBook) "✓" else "+", color = Hearth.palette.ember)
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
        )
    }

    pendingRemoval?.let { membership ->
        AlertDialog(
            onDismissRequest = { pendingRemoval = null },
            title = { Text("Remove from collection?") },
            text = { Text("Remove \"${book.title}\" from \"${membership.collection.name}\" on BookOrbit?") },
            confirmButton = {
                TextButton(onClick = {
                    onChange(membership.collection.key, false)
                    pendingRemoval = null
                }) { Text("Remove", color = Hearth.palette.statusError) }
            },
            dismissButton = { TextButton(onClick = { pendingRemoval = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun DetailHeader(b: Book, ambientColor: Color, onBack: () -> Unit) {
    val palette = Hearth.palette
    Box(Modifier.fillMaxWidth()) {
        Column(Modifier.fillMaxWidth().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(Hearth.Spacing.S)) {
                Box(
                    Modifier.size(48.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onBack),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, contentDescription = "Back", tint = palette.text, modifier = Modifier.size(26.dp))
                }
            }
            Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), horizontalAlignment = Alignment.CenterHorizontally) {
                val coverWidth = if (b.mediaType == AppMediaType.EBOOK) 156.dp else 112.dp
                CoverTile(
                    model = b.coverUrl,
                    ambient = ambientColor,
                    mediaType = b.mediaType,
                    modifier = Modifier.width(coverWidth),
                )
                Spacer(Modifier.height(Hearth.Spacing.M))
                Text(
                    b.title,
                    style = hearthDisplay(24.sp, FontWeight.Bold),
                    color = palette.text,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                )
                b.author?.let {
                    Text(
                        it,
                        style = HearthText.Body,
                        color = palette.textSecondary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                    )
                }
                if (!b.narrator.isNullOrBlank() && b.mediaType != AppMediaType.EBOOK) {
                    Text("Read by ${b.narrator}", style = HearthText.Caption, color = palette.textTertiary, textAlign = TextAlign.Center)
                }
                b.seriesName?.let {
                    val seq = b.seriesNumber?.let { n -> " · #$n" } ?: ""
                    Text("$it$seq", style = HearthText.Caption, color = palette.ember, textAlign = TextAlign.Center)
                }
            }
        }
    }
}

@Composable
internal fun DetailActions(
    b: Book,
    chapters: List<Chapter>,
    linkedAudiobook: Book?,
    linkedEbook: Book?,
    onListen: (Book) -> Unit,
    onRead: (Book) -> Unit,
) {
    val palette = Hearth.palette
    val progress = HearthFormat.progress(b)
    val listenTarget = detailListenTarget(b, linkedAudiobook)
    val readTarget = detailReadTarget(b, linkedEbook)
    val canListen = listenTarget != null
    val canRead = readTarget != null
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL).padding(top = Hearth.Spacing.L)) {
        if (progress > 0f) {
            Ribbon(progress = progress)
            Spacer(Modifier.height(Hearth.Spacing.XS))
            Text(
                detailStatusLine(b, chapters),
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(Hearth.Spacing.M))
        }
        when {

            canListen && canRead && b.mediaType == AppMediaType.EBOOK ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                    ActionPill("Read", Icons.AutoMirrored.Outlined.MenuBook, { onRead(readTarget) }, Modifier.weight(1f))
                    ActionPill("Listen", Icons.Filled.PlayArrow, { onListen(listenTarget) }, Modifier.weight(1f))
                }
            canListen && canRead -> Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                ActionPill("Listen", Icons.Filled.PlayArrow, { onListen(listenTarget) }, Modifier.weight(1f))
                ActionPill("Read", Icons.AutoMirrored.Outlined.MenuBook, { onRead(readTarget) }, Modifier.weight(1f))
            }
            canListen -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                EmberButton(
                    text = "Listen",
                    onClick = { onListen(listenTarget) },
                    leadingIcon = Icons.Filled.PlayArrow,
                )
            }
            else -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                EmberButton(
                    text = "Read",
                    onClick = { readTarget?.let(onRead) },
                    leadingIcon = Icons.AutoMirrored.Outlined.MenuBook,
                )
            }
        }
    }
}

internal fun detailListenTarget(book: Book, linkedAudiobook: Book?): Book? =
    if (book.source == BookSource.GRIMMORY && book.mediaType == AppMediaType.EBOOK && linkedAudiobook != null) {
        linkedAudiobook
    } else if (
        book.mediaType == AppMediaType.AUDIOBOOK ||
        book.hasAudio ||
        book.readAlongAvailable
    ) book else linkedAudiobook

internal fun detailReadTarget(book: Book, linkedEbook: Book?): Book? =
    if (book.source == BookSource.GRIMMORY && book.mediaType == AppMediaType.AUDIOBOOK && linkedEbook != null) {
        linkedEbook
    } else if (book.mediaType == AppMediaType.EBOOK || book.hasEbook) {
        book
    } else {
        linkedEbook
    }

@Composable
private fun ActionPill(text: String, icon: ImageVector, onClick: () -> Unit, modifier: Modifier = Modifier) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(0.dp) else RoundedCornerShape(50)
    Row(
        modifier
            .clip(shape)
            .background(if (eink.active) palette.bg else palette.ember)
            .then(if (eink.active) Modifier.border(2.dp, palette.ember, shape) else Modifier)
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.L, vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = if (eink.active) palette.ember else palette.readableOnEmber
        Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(Hearth.Spacing.S))
        Text(text, style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = fg)
    }
}
