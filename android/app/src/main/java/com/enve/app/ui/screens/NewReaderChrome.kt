package com.enve.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.automirrored.filled.NoteAdd
import androidx.compose.material.icons.automirrored.filled.StickyNote2
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwipeDown
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
internal fun NewReaderChrome(
    state: ReaderChromeState,
    actions: ReaderChromeActions,
    colors: ChromeColors,
    einkActive: Boolean,
) {
    Box(modifier = Modifier.fillMaxSize()) {

        AnimatedVisibility(
            visible = state.chromeVisible,
            enter = if (einkActive) EnterTransition.None
                else fadeIn(tween(180)) + slideInVertically(tween(180)) { -it },
            exit = if (einkActive) ExitTransition.None
                else fadeOut(tween(140)) + slideOutVertically(tween(140)) { -it },
            modifier = Modifier.align(Alignment.TopCenter),
        ) {
            NewReaderTopBar(
                title = state.title,
                author = state.author,
                currentPage = state.currentPage,
                totalPages = state.totalPages,
                hasPageList = state.hasPageList,
                currentPageLabel = state.currentPageLabel,
                lastPageLabel = state.lastPageLabel,
                colors = colors,
                canNavigateBack = state.canNavigateBack,
                canNavigateForward = state.canNavigateForward,
                readAlongSupported = state.readAlongSupported,
                readAlongPlaying = state.readAlongPlaying,
                ttsEnabled = state.ttsEnabled,
                ttsSpeaking = state.ttsSpeaking,
                einkActive = einkActive,
                menuExpanded = state.moreMenuExpanded,
                onMenuExpandedChange = actions.onMoreMenuExpandedChange,
                onBack = actions.onBack,
                onSearch = { actions.onChromeInteraction(); actions.onSearch() },
                onToc = { actions.onChromeInteraction(); actions.onToc() },
                onAppearance = { actions.onChromeInteraction(); actions.onAppearance() },
                onBookmark = { actions.onChromeInteraction(); actions.onBookmark() },
                onAnnotations = { actions.onChromeInteraction(); actions.onAnnotations() },
                onAddNote = { actions.onChromeInteraction(); actions.onAddNote() },
                onAskLibrarian = { actions.onChromeInteraction(); actions.onAskLibrarian() },
                onReadAlong = { actions.onChromeInteraction(); actions.onReadAlong() },
                onTts = { actions.onChromeInteraction(); actions.onTts() },
                onHistoryBack = { actions.onChromeInteraction(); actions.onHistoryBack() },
                onHistoryForward = { actions.onChromeInteraction(); actions.onHistoryForward() },
                onAutoScroll = { actions.onChromeInteraction(); actions.onAutoScroll() },
            )
        }

        AnimatedVisibility(
            visible = state.chromeVisible && !state.readAlongActive,
            enter = if (einkActive) EnterTransition.None
                else fadeIn(tween(180)) + slideInVertically(tween(180)) { it },
            exit = if (einkActive) ExitTransition.None
                else fadeOut(tween(140)) + slideOutVertically(tween(140)) { it },
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            NewReaderBottomBar(
                currentPage = state.currentPage,
                totalPages = state.totalPages,
                hasPageList = state.hasPageList,
                currentPageLabel = state.currentPageLabel,
                lastPageLabel = state.lastPageLabel,
                progressPct = state.progressPct,
                sectionTitle = state.sectionTitle,
                sliderDragging = state.sliderDragging,
                sliderPreviewPage = state.sliderPreviewPage,
                sliderPreviewPageLabel = state.sliderPreviewPageLabel,
                colors = colors,
                einkActive = einkActive,
                onSliderChange = actions.onSliderChange,
                onSliderDragStart = { actions.onChromeInteraction(); actions.onSliderDragStart() },
                onSliderDragEnd = actions.onSliderDragEnd,
                onPagePrev = { actions.onChromeInteraction(); actions.onPagePrev() },
                onPageNext = { actions.onChromeInteraction(); actions.onPageNext() },
            )
        }
    }
}

@Composable
private fun NewReaderTopBar(
    title: String,
    author: String,
    currentPage: Int,
    totalPages: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    colors: ChromeColors,
    canNavigateBack: Boolean,
    canNavigateForward: Boolean,
    readAlongSupported: Boolean,
    readAlongPlaying: Boolean,
    ttsEnabled: Boolean,
    ttsSpeaking: Boolean,
    einkActive: Boolean,
    menuExpanded: Boolean,
    onMenuExpandedChange: (Boolean) -> Unit,
    onBack: () -> Unit,
    onSearch: () -> Unit,
    onToc: () -> Unit,
    onAppearance: () -> Unit,
    onBookmark: () -> Unit,
    onAnnotations: () -> Unit,
    onAddNote: () -> Unit,
    onAskLibrarian: () -> Unit,
    onReadAlong: () -> Unit,
    onTts: () -> Unit,
    onHistoryBack: () -> Unit,
    onHistoryForward: () -> Unit,
    onAutoScroll: () -> Unit,
) {
    val pageSubtitle = readerPositionText(
        currentPage,
        totalPages,
        hasPageList,
        currentPageLabel,
        lastPageLabel,
    )

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .then(
                if (einkActive) Modifier.border(
                    width = 1.dp,
                    color = colors.divider,
                ) else Modifier
            )
            .statusBarsPadding()
            .padding(horizontal = 8.dp, vertical = 8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChromeButton(
                onClick = onBack,
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                label = "Back",
                colors = colors,
                einkActive = einkActive,
            )
            Spacer(Modifier.width(4.dp))
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp),
            ) {
                Text(
                    text = title,
                    color = colors.primaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (pageSubtitle.isNotEmpty()) {
                    Text(
                        text = pageSubtitle,
                        color = colors.secondaryText,
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            ChromeButton(
                onClick = onToc,
                icon = Icons.AutoMirrored.Filled.FormatListBulleted,
                label = "Contents",
                colors = colors,
                einkActive = einkActive,
            )
            ChromeButton(
                onClick = onBookmark,
                icon = Icons.Default.BookmarkAdd,
                label = "Bookmark",
                colors = colors,
                einkActive = einkActive,
            )
            Box {
                ChromeButton(
                    onClick = { onMenuExpandedChange(true) },
                    icon = Icons.Default.MoreHoriz,
                    label = "More",
                    colors = colors,
                    einkActive = einkActive,
                )
                DropdownMenu(
                    expanded = menuExpanded,
                    onDismissRequest = { onMenuExpandedChange(false) },
                    containerColor = colors.surface,
                ) {
                    DropdownMenuItem(
                        text = { Text("Back in History", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = colors.iconTint) },
                        enabled = canNavigateBack,
                        onClick = { onMenuExpandedChange(false); onHistoryBack() },
                    )
                    DropdownMenuItem(
                        text = { Text("Forward in History", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = colors.iconTint) },
                        enabled = canNavigateForward,
                        onClick = { onMenuExpandedChange(false); onHistoryForward() },
                    )
                    DropdownMenuItem(
                        text = { Text("New Note", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.NoteAdd, null, tint = colors.iconTint) },
                        onClick = { onMenuExpandedChange(false); onAddNote() },
                    )
                    DropdownMenuItem(
                        text = { Text("Notes & Highlights", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.StickyNote2, null, tint = colors.iconTint) },
                        onClick = { onMenuExpandedChange(false); onAnnotations() },
                    )
                    DropdownMenuItem(
                        text = { Text("Appearance", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.TextFields, null, tint = colors.iconTint) },
                        onClick = { onMenuExpandedChange(false); onAppearance() },
                    )
                    DropdownMenuItem(
                        text = { Text("Search", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.Search, null, tint = colors.iconTint) },
                        onClick = { onMenuExpandedChange(false); onSearch() },
                    )
                    DropdownMenuItem(
                        text = { Text("Ask Librarian", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.AutoStories, null, tint = colors.iconTint) },
                        onClick = { onMenuExpandedChange(false); onAskLibrarian() },
                    )
                    if (readAlongSupported) {
                        DropdownMenuItem(
                            text = { Text(if (readAlongPlaying) "Pause Read Aloud" else "Read Aloud", color = colors.primaryText, fontSize = 14.sp) },
                            leadingIcon = {
                                Icon(
                                    if (readAlongPlaying) Icons.Default.Pause else Icons.Default.Headset,
                                    null,
                                    tint = colors.iconTint,
                                )
                            },
                            onClick = { onMenuExpandedChange(false); onReadAlong() },
                        )
                    }
                    if (ttsEnabled || ttsSpeaking) {
                        DropdownMenuItem(
                            text = { Text(if (ttsSpeaking) "Stop Read Aloud" else "Read Aloud", color = colors.primaryText, fontSize = 14.sp) },
                            leadingIcon = {
                                Icon(
                                    if (ttsSpeaking) Icons.Default.Pause else Icons.Default.Headset,
                                    null,
                                    tint = colors.iconTint,
                                )
                            },
                            onClick = { onMenuExpandedChange(false); onTts() },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("Auto Scroll", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.SwipeDown, null, tint = colors.iconTint) },
                        onClick = { onMenuExpandedChange(false); onAutoScroll() },
                    )
                }
            }
        }
    }
}

@Composable
private fun NewReaderBottomBar(
    currentPage: Int,
    totalPages: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    progressPct: Int,
    sectionTitle: String,
    sliderDragging: Boolean,
    sliderPreviewPage: Int,
    sliderPreviewPageLabel: String?,
    colors: ChromeColors,
    einkActive: Boolean,
    onSliderChange: (Float) -> Unit,
    onSliderDragStart: () -> Unit,
    onSliderDragEnd: (Float) -> Unit,
    onPagePrev: () -> Unit,
    onPageNext: () -> Unit,
) {
    val displayPage = if (sliderDragging && sliderPreviewPage > 0) sliderPreviewPage else currentPage
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.surface)
            .then(
                if (einkActive) Modifier.border(width = 1.dp, color = colors.divider)
                else Modifier
            )
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (sectionTitle.isNotBlank()) {
            Text(
                text = sectionTitle,
                color = colors.secondaryText,
                fontSize = 12.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ChromeButton(
                onClick = onPagePrev,
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                label = "Previous",
                colors = colors,
                einkActive = einkActive,
            )
            Box(modifier = Modifier.weight(1f).padding(horizontal = 8.dp)) {
                if (totalPages > 0) {

                    var lastDraggedValue by remember { mutableFloatStateOf(currentPage.toFloat()) }
                    val displayedValue = when {
                        sliderDragging -> sliderPreviewPage.coerceIn(1, totalPages).toFloat()
                        else -> currentPage.toFloat()
                    }
                    Slider(
                        value = displayedValue,
                        valueRange = 1f..totalPages.toFloat(),
                        onValueChange = { v ->
                            if (!sliderDragging) onSliderDragStart()
                            lastDraggedValue = v
                            onSliderChange(v)
                        },
                        onValueChangeFinished = { onSliderDragEnd(lastDraggedValue) },
                        colors = SliderDefaults.colors(
                            thumbColor = colors.accentText,
                            activeTrackColor = colors.accentText,
                            inactiveTrackColor = colors.progressTrack,
                        ),
                    )
                }
            }
            ChromeButton(
                onClick = onPageNext,
                icon = Icons.AutoMirrored.Filled.ArrowForward,
                label = "Next",
                colors = colors,
                einkActive = einkActive,
            )
        }
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                text = readerPositionText(
                    displayPage,
                    totalPages,
                    hasPageList,
                    if (sliderDragging) sliderPreviewPageLabel else currentPageLabel,
                    lastPageLabel,
                ),
                color = colors.secondaryText,
                fontSize = 11.sp,
            )
            Text(
                text = "$progressPct%",
                color = colors.secondaryText,
                fontSize = 11.sp,
            )
        }
    }
}

@Composable
private fun ChromeButton(
    onClick: () -> Unit,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    colors: ChromeColors,
    einkActive: Boolean,
    size: Int = 36,
) {
    val shape = if (einkActive) RoundedCornerShape(4.dp) else CircleShape
    Box(
        modifier = Modifier
            .size(size.dp)
            .clip(shape)
            .then(
                if (einkActive) Modifier.border(1.dp, colors.iconTint, shape)
                else Modifier.background(colors.ghostButtonBg)
            )
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = colors.iconTint,
            modifier = Modifier.size((size * 0.5).dp),
        )
    }
}
