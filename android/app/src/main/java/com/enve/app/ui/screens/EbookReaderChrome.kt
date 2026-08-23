package com.enve.app.ui.screens

import android.content.Context
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.automirrored.filled.FormatListBulleted
import androidx.compose.material.icons.automirrored.filled.NoteAdd
import androidx.compose.material.icons.automirrored.filled.StickyNote2
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DashboardCustomize
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.FormatStrikethrough
import androidx.compose.material.icons.filled.FormatUnderlined
import androidx.compose.material.icons.filled.Headset
import androidx.compose.material.icons.filled.Highlight
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.SwipeDown
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.Waves
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.data.reader.ReaderProgressDisplay
import com.enve.app.data.reader.ReaderToolbarButton
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.ProgressConflictPrompt
import java.util.Locale
import kotlin.math.roundToInt

@Composable
internal fun ProgressConflictDialog(
    prompt: ProgressConflictPrompt,
    onChooseLocal: () -> Unit,
    onChooseRemote: () -> Unit,
) {
    val localPct = (prompt.localPercentage * 100).toInt().coerceIn(0, 100)
    val remotePct = (prompt.remotePercentage * 100).toInt().coerceIn(0, 100)
    val localWhen = formatRelativeTime(prompt.localUpdatedAt)
    val remoteWhen = formatRelativeTime(prompt.remoteUpdatedAt)
    AlertDialog(
        onDismissRequest = {},
        title = { Text("Where do you want to continue?") },
        text = {
            Text(
                buildString {
                    append("This device is at $localPct%")
                    if (localWhen != null) append(" (saved $localWhen)")
                    append(".\n")
                    append("${prompt.remoteSource} is at $remotePct%")
                    if (remoteWhen != null) append(" (saved $remoteWhen)")
                    append(".\n\nThe two disagree. Pick which one to use.")
                },
            )
        },
        confirmButton = {
            TextButton(onClick = onChooseRemote) {
                Text("Use ${prompt.remoteSource} ($remotePct%)")
            }
        },
        dismissButton = {
            TextButton(onClick = onChooseLocal) {
                Text("Use this device ($localPct%)")
            }
        },
    )
}

private fun formatRelativeTime(epochMs: Long?): String? {
    if (epochMs == null || epochMs <= 0L) return null
    val deltaSec = (System.currentTimeMillis() - epochMs) / 1000L
    return when {
        deltaSec < 0L -> null
        deltaSec < 60L -> "just now"
        deltaSec < 3600L -> "${deltaSec / 60} min ago"
        deltaSec < 86_400L -> "${deltaSec / 3600} h ago"
        else -> "${deltaSec / 86_400L} d ago"
    }
}

@Composable
internal fun ReadAlongControlsBar(
    isPlaying: Boolean,
    isPreparing: Boolean,
    speed: Float,
    clipIndex: Int,
    clipCount: Int,
    colors: ChromeColors,
    onTogglePlayback: () -> Unit,
    onSkipBackward: () -> Unit,
    onSkipForward: () -> Unit,
    onSpeedChange: (Float) -> Unit,
    modifier: Modifier = Modifier,
) {
    val progress = if (clipCount > 0) ((clipIndex + 1).toFloat() / clipCount.toFloat()).coerceIn(0f, 1f) else 0f

    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(20.dp),
        color = colors.surface.copy(alpha = 0.96f),
        tonalElevation = if (EnveTheme.isEink) 0.dp else 6.dp,
        shadowElevation = if (EnveTheme.isEink) 0.dp else 10.dp,
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(3.dp)
                    .clip(CircleShape)
                    .background(colors.accentText.copy(alpha = 0.14f)),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxHeight()
                        .fillMaxWidth(progress)
                        .background(colors.accentText),
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = if (isPreparing) "Preparing read aloud…" else "Read Aloud",
                    color = colors.primaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    text = if (clipCount > 0) "${clipIndex + 1} / $clipCount" else "Read aloud",
                    color = colors.secondaryText,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                GhostCircleButton(
                    onClick = onSkipBackward,
                    icon = Icons.Default.SkipPrevious,
                    label = "Previous sentence",
                    iconTint = colors.iconTint,
                    bgColor = colors.ghostButtonBg,
                    size = 42.dp,
                    enabled = !isPreparing,
                )
                if (isPreparing) {
                    Box(
                        modifier = Modifier.size(46.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            color = colors.accentText,
                            strokeWidth = 2.5.dp,
                            modifier = Modifier.size(24.dp),
                        )
                    }
                } else {
                    GhostCircleButton(
                        onClick = onTogglePlayback,
                        icon = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        label = if (isPlaying) "Pause read along" else "Resume read along",
                        iconTint = colors.accentText,
                        bgColor = colors.ghostButtonBg,
                        size = 46.dp,
                    )
                }
                GhostCircleButton(
                    onClick = onSkipForward,
                    icon = Icons.Default.SkipNext,
                    label = "Next sentence",
                    iconTint = colors.iconTint,
                    bgColor = colors.ghostButtonBg,
                    size = 42.dp,
                    enabled = !isPreparing,
                )

                Spacer(Modifier.weight(1f))

                ReadAlongSpeedMenu(
                    speed = speed,
                    colors = colors,
                    onSpeedChange = onSpeedChange,
                )
            }
        }
    }
}

@Composable
private fun ReadAlongSpeedMenu(
    speed: Float,
    colors: ChromeColors,
    onSpeedChange: (Float) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val speedOptions = listOf(0.75f, 1.0f, 1.25f, 1.5f, 2.0f, 2.5f, 2.75f, 3.0f)

    Box {
        TextButton(
            onClick = { expanded = true },
            colors = ButtonDefaults.textButtonColors(contentColor = colors.accentText),
            contentPadding = PaddingValues(horizontal = 10.dp, vertical = 4.dp),
            modifier = Modifier
                .clip(CircleShape)
                .background(colors.ghostButtonBg),
        ) {
            Text(
                text = "%.2fx".format(speed),
                fontSize = 13.sp,
                fontWeight = FontWeight.Bold,
            )
        }

        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
            containerColor = colors.surface.copy(alpha = 1f),
        ) {
            speedOptions.forEach { option ->
                DropdownMenuItem(
                    text = {
                        Text(
                            text = "%.2fx".format(option),
                            color = colors.primaryText,
                            fontWeight = if (kotlin.math.abs(speed - option) < 0.01f) FontWeight.Bold else FontWeight.Normal,
                        )
                    },
                    onClick = {
                        expanded = false
                        onSpeedChange(option)
                    },
                )
            }
        }
    }
}

@Composable
internal fun ReaderStatusStrip(
    showClock: Boolean,
    showBattery: Boolean,
    progressDisplay: ReaderProgressDisplay,
    currentPage: Int,
    totalPages: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    progressPct: Int,
    chapter: String,
    chromeVisible: Boolean,
    textColor: Color,
    modifier: Modifier = Modifier,
) {
    if (chromeVisible) return

    val context = LocalContext.current

    val timeText = if (showClock) {
        val now by produceState(initialValue = System.currentTimeMillis()) {
            while (true) {
                value = System.currentTimeMillis()
                kotlinx.coroutines.delay(30_000)
            }
        }
        val fmt = remember { java.text.SimpleDateFormat("h:mm a", Locale.getDefault()) }
        fmt.format(java.util.Date(now))
    } else null

    val batteryPct = if (showBattery) {
        val pct by produceState(initialValue = readBatteryPercent(context)) {
            while (true) {
                value = readBatteryPercent(context)
                kotlinx.coroutines.delay(60_000)
            }
        }
        pct
    } else null

    val progressText = when (progressDisplay) {
        ReaderProgressDisplay.NONE -> null
        ReaderProgressDisplay.PAGE ->
            readerPositionText(
                currentPage,
                totalPages,
                hasPageList,
                currentPageLabel,
                lastPageLabel,
            ).takeIf { it.isNotEmpty() }
        ReaderProgressDisplay.PERCENT -> "$progressPct%"
        ReaderProgressDisplay.CHAPTER -> chapter.takeIf { it.isNotBlank() }
        ReaderProgressDisplay.PAGE_AND_PERCENT ->
            readerPositionText(
                currentPage,
                totalPages,
                hasPageList,
                currentPageLabel,
                lastPageLabel,
            )
                .takeIf { it.isNotEmpty() }
                ?.let { "$it · $progressPct%" }
                ?: "$progressPct%"
    }

    if (timeText == null && batteryPct == null && progressText == null) return

    Row(
        modifier = modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = listOfNotNull(timeText).joinToString("  "),
            color = textColor,
            fontSize = 11.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        progressText?.let {
            Text(
                text = it,
                color = textColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (batteryPct != null) {
            if (progressText != null) Spacer(Modifier.width(10.dp))
            Text(
                text = "$batteryPct%",
                color = textColor,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
            )
        }
    }
}

private fun readBatteryPercent(context: Context): Int {
    val mgr = context.getSystemService(Context.BATTERY_SERVICE) as? android.os.BatteryManager
    return mgr?.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY) ?: 0
}

@Composable
internal fun GhostCircleButton(
    onClick: () -> Unit,
    icon: ImageVector,
    label: String,
    iconTint: Color,
    bgColor: Color,
    size: Dp = 44.dp,
    enabled: Boolean = true,
) {
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(bgColor)
            .clickable(
                enabled = enabled,
                interactionSource = remember { MutableInteractionSource() },
                indication = LocalIndication.current,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = iconTint.copy(alpha = if (enabled) iconTint.alpha else iconTint.alpha * 0.38f),
            modifier = Modifier.size((size.value * 0.48f).dp),
        )
    }
}

@Composable
internal fun LegacyReaderChrome(
    state: ReaderChromeState,
    actions: ReaderChromeActions,
    colors: ChromeColors,
) {
    Box(modifier = Modifier.fillMaxSize()) {
        AnimatedVisibility(
            visible = state.chromeVisible,
            enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { -it },
            exit = fadeOut(tween(200)) + slideOutVertically(tween(200)) { -it },
            modifier = Modifier.align(Alignment.TopCenter),
        ) {
            ReaderTopBar(
                title = state.title,
                author = state.author,
                currentPage = state.currentPage,
                totalPages = state.totalPages,
                hasPageList = state.hasPageList,
                currentPageLabel = state.currentPageLabel,
                lastPageLabel = state.lastPageLabel,
                colors = colors,
                readAlongSupported = state.readAlongSupported,
                readAlongPlaying = state.readAlongActive,
                toolbarButtons = state.toolbarButtons,
                overflowExpanded = state.moreMenuExpanded,
                onOverflowExpandedChange = actions.onMoreMenuExpandedChange,
                onBack = actions.onBack,
                onSearch = { actions.onChromeInteraction(); actions.onSearch() },
                onToc = { actions.onChromeInteraction(); actions.onToc() },
                onAppearance = { actions.onChromeInteraction(); actions.onAppearance() },
                onBookmark = { actions.onChromeInteraction(); actions.onBookmark() },
                onAskLibrarian = { actions.onChromeInteraction(); actions.onAskLibrarian() },
                onReadAlong = { actions.onChromeInteraction(); actions.onReadAlong() },
                onAutoScroll = { actions.onChromeInteraction(); actions.onAutoScroll() },
                onToolbarCustomize = { actions.onChromeInteraction(); actions.onToolbarCustomize() },
                onAnnotations = { actions.onChromeInteraction(); actions.onAnnotations() },
                onAddNote = { actions.onChromeInteraction(); actions.onAddNote() },
                onChromeInteraction = actions.onChromeInteraction,
            )
        }
        AnimatedVisibility(
            visible = state.chromeVisible && !state.readAlongActive,
            enter = fadeIn(tween(200)) + slideInVertically(tween(200)) { it },
            exit = fadeOut(tween(200)) + slideOutVertically(tween(200)) { it },
            modifier = Modifier.align(Alignment.BottomCenter),
        ) {
            ReaderBottomBar(
                currentPage = state.currentPage,
                totalPages = state.totalPages,
                hasPageList = state.hasPageList,
                currentPageLabel = state.currentPageLabel,
                lastPageLabel = state.lastPageLabel,
                section = state.sectionTitle,
                progress = state.progressPct / 100f,
                colors = colors,
                sliderDragging = state.sliderDragging,
                sliderPreviewPage = state.sliderPreviewPage,
                sliderPreviewPageLabel = state.sliderPreviewPageLabel,
                onPrevPage = { actions.onChromeInteraction(); actions.onPagePrev() },
                onNextPage = { actions.onChromeInteraction(); actions.onPageNext() },
                onSeekProgress = { actions.onChromeInteraction(); actions.onSeekProgress(it) },
                onSliderDrag = actions.onSliderDrag,
            )
        }
    }
}

@Composable
internal fun ReaderTopBar(
    title: String,
    author: String,
    currentPage: Int,
    totalPages: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    colors: ChromeColors,
    readAlongSupported: Boolean,
    readAlongPlaying: Boolean,
    toolbarButtons: Set<ReaderToolbarButton>,
    overflowExpanded: Boolean,
    onOverflowExpandedChange: (Boolean) -> Unit,
    onBack: () -> Unit,
    onSearch: () -> Unit,
    onToc: () -> Unit,
    onAppearance: () -> Unit, onBookmark: () -> Unit,
    onAskLibrarian: () -> Unit,
    onReadAlong: () -> Unit,
    onAutoScroll: () -> Unit,
    onToolbarCustomize: () -> Unit,
    onAnnotations: () -> Unit = {},
    onAddNote: () -> Unit = {},
    onChromeInteraction: () -> Unit = {},
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
            .background(colors.background.copy(alpha = 1f)),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GhostCircleButton(
                onClick = onBack,
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                label = "Back",
                iconTint = colors.iconTint,
                bgColor = colors.ghostButtonBg,
                size = 36.dp,
            )

            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = title,
                    color = colors.primaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (pageSubtitle.isNotBlank()) {
                    Text(
                        text = pageSubtitle,
                        color = colors.secondaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                    )
                } else if (author.isNotBlank()) {
                    Text(
                        text = author,
                        color = colors.secondaryText,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            toolbarButtons.forEach { button ->
                when (button) {
                    ReaderToolbarButton.TOC ->
                        GhostCircleButton(onClick = onToc, icon = Icons.AutoMirrored.Filled.FormatListBulleted, label = "Contents", iconTint = colors.iconTint, bgColor = colors.ghostButtonBg, size = 36.dp)
                    ReaderToolbarButton.APPEARANCE -> Unit
                    ReaderToolbarButton.BOOKMARK ->
                        GhostCircleButton(onClick = onBookmark, icon = Icons.Default.BookmarkAdd, label = "Bookmark", iconTint = colors.iconTint, bgColor = colors.ghostButtonBg, size = 36.dp)
                    ReaderToolbarButton.READ_ALONG ->
                        if (readAlongSupported) GhostCircleButton(
                            onClick = onReadAlong,
                            icon = if (readAlongPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                            label = "Read Aloud",
                            iconTint = if (readAlongPlaying) colors.accentText else colors.iconTint,
                            bgColor = colors.ghostButtonBg,
                            size = 36.dp,
                        ) else Unit
                    ReaderToolbarButton.AUTO_SCROLL ->
                        GhostCircleButton(onClick = onAutoScroll, icon = Icons.Default.SwipeDown, label = "Auto Scroll", iconTint = colors.iconTint, bgColor = colors.ghostButtonBg, size = 36.dp)
                    ReaderToolbarButton.SHARE -> Unit
                    ReaderToolbarButton.SEARCH -> Unit
                }
                if (button != ReaderToolbarButton.APPEARANCE && button != ReaderToolbarButton.SEARCH) {
                    Spacer(Modifier.width(2.dp))
                }
            }

            Box {
                GhostCircleButton(
                    onClick = {
                        onChromeInteraction()
                        onOverflowExpandedChange(true)
                    },
                    icon = Icons.Default.MoreHoriz,
                    label = "More",
                    iconTint = colors.iconTint,
                    bgColor = colors.ghostButtonBg,
                    size = 36.dp,
                )
                DropdownMenu(
                    expanded = overflowExpanded,
                    onDismissRequest = { onOverflowExpandedChange(false) },
                    containerColor = colors.surface.copy(alpha = 1f),
                ) {
                    DropdownMenuItem(
                        text = { Text("Search", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.Search, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onSearch() },
                    )
                    DropdownMenuItem(
                        text = { Text("Bookmark", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.BookmarkAdd, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onBookmark() },
                    )
                    DropdownMenuItem(
                        text = { Text("New Note", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.NoteAdd, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onAddNote() },
                    )
                    DropdownMenuItem(
                        text = { Text("Notes & Highlights", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.StickyNote2, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onAnnotations() },
                    )
                    DropdownMenuItem(
                        text = { Text("Ask Librarian", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.AutoStories, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onAskLibrarian() },
                    )
                    DropdownMenuItem(
                        text = { Text("Appearance", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.TextFields, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onAppearance() },
                    )
                    DropdownMenuItem(
                        text = { Text("Contents", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.AutoMirrored.Filled.FormatListBulleted, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onToc() },
                    )
                    DropdownMenuItem(
                        text = { Text("Auto Scroll", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.SwipeDown, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onAutoScroll() },
                    )
                    DropdownMenuItem(
                        text = { Text("Customize Toolbar", color = colors.primaryText, fontSize = 14.sp) },
                        leadingIcon = { Icon(Icons.Default.DashboardCustomize, null, tint = colors.iconTint) },
                        onClick = { onOverflowExpandedChange(false); onToolbarCustomize() },
                    )
                    if (readAlongSupported) {
                        DropdownMenuItem(
                            text = {
                                Text(
                                    if (readAlongPlaying) "Pause Read Aloud" else "Start Read Aloud",
                                    color = colors.primaryText,
                                    fontSize = 14.sp,
                                )
                            },
                            leadingIcon = {
                                Icon(
                                    if (readAlongPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                                    null,
                                    tint = colors.iconTint,
                                )
                            },
                            onClick = { onOverflowExpandedChange(false); onReadAlong() },
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun ReaderBottomBar(
    currentPage: Int,
    totalPages: Int,
    hasPageList: Boolean,
    currentPageLabel: String?,
    lastPageLabel: String?,
    section: String,
    progress: Float,
    colors: ChromeColors,
    sliderDragging: Boolean,
    sliderPreviewPage: Int,
    sliderPreviewPageLabel: String?,
    onPrevPage: () -> Unit,
    onNextPage: () -> Unit,
    onSeekProgress: (Float) -> Unit,
    onSliderDrag: (Boolean, Int) -> Unit,
) {
    val pct = (progress * 100).roundToInt()
    val displayPage = if (sliderDragging && sliderPreviewPage > 0) sliderPreviewPage else currentPage
    val pageLabel = readerPositionText(
        displayPage,
        totalPages,
        hasPageList,
        if (sliderDragging) sliderPreviewPageLabel else currentPageLabel,
        lastPageLabel,
    ).ifEmpty { "$pct%" }
    var sliderValue by remember { mutableFloatStateOf(progress) }

    LaunchedEffect(progress) {
        if (!sliderDragging) sliderValue = progress
    }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.background.copy(alpha = 1f)),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 6.dp),
        ) {
        Spacer(Modifier.height(10.dp))
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {

            androidx.compose.animation.AnimatedVisibility(
                visible = sliderDragging,
                enter = fadeIn(tween(100)) + scaleIn(tween(100), initialScale = 0.8f),
                exit = fadeOut(tween(100)) + scaleOut(tween(100), targetScale = 0.8f),
                modifier = Modifier.align(Alignment.TopCenter).offset(y = (-48).dp),
            ) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = colors.surface,
                    tonalElevation = if (EnveTheme.isEink) 0.dp else 4.dp,
                    shadowElevation = if (EnveTheme.isEink) 0.dp else 8.dp,
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(width = 48.dp, height = 64.dp)
                                .clip(RoundedCornerShape(4.dp))
                                .background(colors.primaryText.copy(alpha = 0.1f)),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                text = sliderPreviewPageLabel ?: "$sliderPreviewPage",
                                color = colors.primaryText,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Bold,
                            )
                        }
                        Spacer(Modifier.height(2.dp))
                        Text(
                            text = readerPositionText(
                                sliderPreviewPage,
                                totalPages,
                                hasPageList,
                                sliderPreviewPageLabel,
                                lastPageLabel,
                            ).ifEmpty { "$pct%" },
                            color = colors.secondaryText,
                            fontSize = 10.sp,
                        )
                    }
                }
            }

            ThinSlider(
                value = sliderValue,
                onValueChange = {
                    sliderValue = it
                    val previewPg = if (totalPages > 0) {
                        (it * totalPages).roundToInt().coerceAtLeast(1)
                    } else {
                        0
                    }
                    onSliderDrag(true, previewPg)
                },
                onValueChangeFinished = {
                    onSeekProgress(sliderValue)
                    onSliderDrag(false, displayPage)
                },
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                accent = colors.accentText,
            )
        }

        Spacer(Modifier.height(4.dp))

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            GhostCircleButton(
                onClick = onPrevPage,
                icon = Icons.AutoMirrored.Filled.ArrowBack,
                label = "Previous page",
                iconTint = colors.iconTint,
                bgColor = colors.ghostButtonBg,
                size = 40.dp,
            )

            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = pageLabel,
                        color = colors.primaryText,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        text = "$pct%",
                        color = colors.accentText,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
                if (section.isNotBlank()) {
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = section.uppercase(Locale.US),
                        color = colors.secondaryText,
                        fontSize = 10.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            GhostCircleButton(
                onClick = onNextPage,
                icon = Icons.AutoMirrored.Filled.ArrowForward,
                label = "Next page",
                iconTint = colors.iconTint,
                bgColor = colors.ghostButtonBg,
                size = 40.dp,
            )
        }
        }
    }
}

@Composable
internal fun QuickAnnotateBar(
    colors: ChromeColors,
    onHighlight: () -> Unit, onUnderline: () -> Unit,
    onStrikethrough: () -> Unit, onSquiggly: () -> Unit,
    onAddNote: () -> Unit, onDismiss: () -> Unit,
) {
    val annotationColors = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0", "#FFCC80", "#CE93D8")
    var selectedColor by remember { mutableStateOf(annotationColors[0]) }

    Surface(
        shape  = RoundedCornerShape(16.dp),
        color  = colors.background,
        tonalElevation = if (EnveTheme.isEink) 0.dp else 8.dp,
        shadowElevation = if (EnveTheme.isEink) 0.dp else 12.dp,
    ) {
        Column(modifier = Modifier.padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AnnotateButton("Highlight", Icons.Default.Highlight, Color(parseHexColor(selectedColor)), onHighlight)
                AnnotateButton("Underline", Icons.Default.FormatUnderlined, colors.iconTint, onUnderline)
                AnnotateButton("Strike",    Icons.Default.FormatStrikethrough, colors.iconTint, onStrikethrough)
                AnnotateButton("Squiggle",  Icons.Default.Waves, colors.iconTint, onSquiggly)
                Spacer(Modifier.width(4.dp))
                AnnotateButton("Note",      Icons.Default.Edit, colors.accentText, onAddNote)
                AnnotateButton("Clear",     Icons.Default.Close, colors.secondaryText, onDismiss)
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                annotationColors.forEach { hex ->
                    Box(
                        modifier = Modifier
                            .size(26.dp)
                            .clip(CircleShape)
                            .background(Color(parseHexColor(hex)))
                            .then(
                                if (hex == selectedColor) Modifier.border(2.dp, Color.White, CircleShape)
                                else Modifier
                            )
                            .clickable { selectedColor = hex },
                    )
                }
            }
        }
    }
}

@Composable
private fun AnnotateButton(label: String, icon: ImageVector, tint: Color, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(36.dp)) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(20.dp))
    }
}

@Composable
internal fun SelectionPopup(
    colors: ChromeColors,
    selectedText: String,
    onHighlight: (String) -> Unit,
    onUnderline: (String) -> Unit,
    onStrikethrough: (String) -> Unit,
    onSquiggly: (String) -> Unit,
    onAddNote: () -> Unit,
    onShare: () -> Unit,
    onCopy: () -> Unit,
    onSpeak: () -> Unit,
    onDefine: () -> Unit,
    onDismiss: () -> Unit,
) {
    val annotationColors = listOf("#FFF59D", "#A5D6A7", "#90CAF9", "#F8BBD0", "#FFCC80", "#CE93D8", "#FF8A80", "#B39DDB")

    val defaultColor = annotationColors[0]

    Surface(
        shape = RoundedCornerShape(20.dp),
        color = colors.background,
        tonalElevation = if (EnveTheme.isEink) 0.dp else 8.dp,
        shadowElevation = if (EnveTheme.isEink) 0.dp else 16.dp,
        modifier = Modifier.padding(16.dp),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
            ) {
                Text(
                    text = if (selectedText.isNotBlank())
                        "“${selectedText.take(70)}${if (selectedText.length > 70) "…" else "”"}"
                    else "Selection",
                    color = colors.primaryText,
                    fontSize = 13.sp,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, "Close", tint = colors.secondaryText, modifier = Modifier.size(20.dp))
                }
            }

            Text(
                "Tap a colour to highlight",
                color = colors.secondaryText,
                fontSize = 11.sp,
                modifier = Modifier.padding(bottom = 6.dp),
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.padding(bottom = 14.dp),
            ) {
                annotationColors.forEach { hex ->
                    Box(
                        modifier = Modifier
                            .size(34.dp)
                            .clip(CircleShape)
                            .background(Color(parseHexColor(hex)))
                            .clickable { onHighlight(hex) },
                    )
                }
            }

            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(bottom = 8.dp),
            ) {
                PopupActionButton("Note", Icons.Default.Edit, colors) { onAddNote() }
                PopupActionButton("Underline", Icons.Default.FormatUnderlined, colors) { onUnderline(defaultColor) }
                PopupActionButton("Strike", Icons.Default.FormatStrikethrough, colors) { onStrikethrough(defaultColor) }
                PopupActionButton("Squiggle", Icons.Default.Waves, colors) { onSquiggly(defaultColor) }
            }
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                PopupActionButton("Define", Icons.Default.Search, colors) { onDefine() }
                PopupActionButton("Copy", Icons.Default.ContentCopy, colors) { onCopy() }
                PopupActionButton("Share", Icons.Default.Share, colors) { onShare() }
                PopupActionButton("Speak", Icons.Default.Headset, colors) { onSpeak() }
            }
        }
    }
}

@Composable
private fun PopupActionButton(label: String, icon: ImageVector, colors: ChromeColors, onClick: () -> Unit) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 6.dp),
    ) {
        Box(
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .background(colors.ghostButtonBg),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, label, tint = colors.iconTint, modifier = Modifier.size(18.dp))
        }
        Spacer(Modifier.height(2.dp))
        Text(label, color = colors.secondaryText, fontSize = 9.sp)
    }
}

@Composable
internal fun AutoScrollPanel(
    isActive: Boolean,
    speed: Float,
    colors: ChromeColors,
    onSpeedChange: (Float) -> Unit,
    onToggle: () -> Unit,
    onClose: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = colors.background,
        tonalElevation = if (EnveTheme.isEink) 0.dp else 8.dp,
        shadowElevation = if (EnveTheme.isEink) 0.dp else 12.dp,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    "Auto Scroll",
                    color = colors.primaryText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onClose, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Default.Close, "Close", tint = colors.secondaryText, modifier = Modifier.size(16.dp))
                }
            }

            Spacer(Modifier.height(8.dp))

            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Speed, null, tint = colors.secondaryText, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(8.dp))
                ThinSlider(
                    value = speed.coerceIn(0f, 10f),
                    onValueChange = onSpeedChange,
                    valueRange = 0f..10f,
                    modifier = Modifier.weight(1f),
                    accent = colors.accentText,
                )
                Spacer(Modifier.width(8.dp))
                Text(
                    "${speed.toInt()}",
                    color = colors.accentText,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.widthIn(min = 24.dp),
                )
            }

            Spacer(Modifier.height(8.dp))

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (isActive) colors.accentText.copy(alpha = 0.15f) else colors.ghostButtonBg)
                    .clickable(onClick = onToggle)
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        if (isActive) Icons.Default.Pause else Icons.Default.PlayArrow,
                        null,
                        tint = if (isActive) colors.accentText else colors.iconTint,
                        modifier = Modifier.size(20.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        if (isActive) "Pause" else "Start",
                        color = if (isActive) colors.accentText else colors.iconTint,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

@Composable
internal fun ToolbarCustomizerPanel(
    currentButtons: Set<ReaderToolbarButton>,
    colors: ChromeColors,
    onToggle: (ReaderToolbarButton) -> Unit,
    onClose: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = colors.background,
        tonalElevation = if (EnveTheme.isEink) 0.dp else 8.dp,
        shadowElevation = if (EnveTheme.isEink) 0.dp else 12.dp,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    "Customize Toolbar",
                    color = colors.primaryText,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = onClose, modifier = Modifier.size(28.dp)) {
                    Icon(Icons.Default.Close, "Close", tint = colors.secondaryText, modifier = Modifier.size(16.dp))
                }
            }

            Spacer(Modifier.height(8.dp))
            Text(
                "Tap to toggle buttons on the top bar",
                color = colors.secondaryText,
                fontSize = 12.sp,
            )
            Spacer(Modifier.height(12.dp))

            ReaderToolbarButton.entries.chunked(3).forEach { row ->
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    row.forEach { button ->
                        val isActive = currentButtons.contains(button)
                        val icon = when (button) {
                            ReaderToolbarButton.TOC -> Icons.AutoMirrored.Filled.FormatListBulleted
                            ReaderToolbarButton.APPEARANCE -> Icons.Default.TextFields
                            ReaderToolbarButton.BOOKMARK -> Icons.Default.BookmarkAdd
                            ReaderToolbarButton.READ_ALONG -> Icons.Default.Headset
                            ReaderToolbarButton.AUTO_SCROLL -> Icons.Default.SwipeDown
                            ReaderToolbarButton.SHARE -> Icons.Default.Share
                            ReaderToolbarButton.SEARCH -> Icons.Default.Search
                        }
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(10.dp))
                                .background(if (isActive) colors.accentText.copy(alpha = 0.15f) else colors.ghostButtonBg)
                                .border(
                                    width = if (isActive) 1.dp else 0.dp,
                                    color = if (isActive) colors.accentText else Color.Transparent,
                                    shape = RoundedCornerShape(10.dp),
                                )
                                .clickable { onToggle(button) }
                                .padding(vertical = 10.dp),
                        ) {
                            Icon(icon, button.label, tint = if (isActive) colors.accentText else colors.secondaryText, modifier = Modifier.size(20.dp))
                            Spacer(Modifier.height(2.dp))
                            Text(button.label, color = if (isActive) colors.accentText else colors.secondaryText, fontSize = 10.sp)
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}
