package com.enve.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.einkAwareBackground
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.BookmarkBorder
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.enve.app.viewmodel.ComicReaderUiState
import kotlin.math.roundToInt

@Composable
internal fun ComicTopBar(
    title: String,
    author: String,
    formatLabel: String,
    isBookmarked: Boolean,
    onBack: () -> Unit,
    onToggleBookmark: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    val accent = MaterialTheme.colorScheme.primary
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .einkAwareBackground(
                brush = Brush.verticalGradient(
                    colors = listOf(Color.Black.copy(alpha = 0.88f), Color.Transparent),
                ),
                einkFill = Color.Black,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = 10.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.10f))
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = Color.White, modifier = Modifier.size(20.dp))
            }
            Spacer(Modifier.width(8.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    color = Color.White,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (author.isNotBlank()) {
                    Text(
                        text = author,
                        color = Color.White.copy(alpha = 0.50f),
                        fontSize = 11.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            Spacer(Modifier.width(8.dp))
            Surface(shape = RoundedCornerShape(999.dp), color = accent.copy(alpha = 0.15f)) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(Icons.Default.AutoStories, contentDescription = null, tint = accent, modifier = Modifier.size(12.dp))
                    Text(formatLabel, color = accent, fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.width(4.dp))
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(if (isBookmarked) accent.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.10f))
                    .clickable(onClick = onToggleBookmark),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (isBookmarked) Icons.Default.Bookmark else Icons.Default.BookmarkBorder,
                    contentDescription = if (isBookmarked) "Remove bookmark" else "Add bookmark",
                    tint = if (isBookmarked) accent else Color.White,
                    modifier = Modifier.size(20.dp),
                )
            }
            Spacer(Modifier.width(4.dp))
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.10f))
                    .clickable(onClick = onOpenSettings),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White, modifier = Modifier.size(20.dp))
            }
        }
    }
}

@Composable
internal fun ComicBottomBar(
    state: ComicReaderUiState,
    visiblePageIndices: List<Int>,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onPageChange: (Int) -> Unit,
    isRtl: Boolean,
) {
    val accent = MaterialTheme.colorScheme.primary
    var scrubbing by remember { mutableStateOf(false) }
    var scrubPage by remember { mutableFloatStateOf(state.currentPage.toFloat()) }
    var swipeAccum by remember { mutableFloatStateOf(0f) }

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .einkAwareBackground(
                brush = Brush.verticalGradient(
                    colors = listOf(Color.Transparent, Color.Black.copy(alpha = 0.88f)),
                ),
                einkFill = Color.Black,
            ),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            AnimatedVisibility(visible = scrubbing && state.pages.isNotEmpty()) {
                val stripTarget = scrubPage.roundToInt().coerceIn(0, state.pages.lastIndex)
                LazyRow(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(90.dp)
                        .padding(bottom = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    val start = (stripTarget - 4).coerceAtLeast(0)
                    val end = (stripTarget + 4).coerceAtMost(state.pages.lastIndex)
                    itemsIndexed(state.pages.subList(start, end + 1)) { relIdx, file ->
                        val absIdx = start + relIdx
                        val isTarget = absIdx == stripTarget
                        AsyncImage(
                            model = file,
                            contentDescription = "Page ${absIdx + 1}",
                            modifier = Modifier
                                .width(if (isTarget) 58.dp else 46.dp)
                                .fillMaxHeight()
                                .clip(RoundedCornerShape(6.dp))
                                .border(
                                    width = if (isTarget) 2.dp else 0.dp,
                                    color = if (isTarget) accent else Color.Transparent,
                                    shape = RoundedCornerShape(6.dp),
                                ),
                            contentScale = ContentScale.Crop,
                        )
                    }
                }
            }

            ThinSlider(
                value = if (scrubbing) scrubPage else state.currentPage.toFloat(),
                onValueChange = { v ->
                    scrubbing = true
                    scrubPage = v
                },
                onValueChangeFinished = {
                    onPageChange(scrubPage.roundToInt().coerceIn(0, state.pages.lastIndex))
                    scrubbing = false
                },
                valueRange = 0f..state.pages.lastIndex.toFloat().coerceAtLeast(0f),
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                accent = accent,
            )

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .pointerInput(state.currentPage, state.pages.size) {
                        detectHorizontalDragGestures(
                            onHorizontalDrag = { change, dragAmount ->
                                change.consume()
                                swipeAccum += dragAmount
                            },
                            onDragEnd = {
                                val threshold = 48f
                                val swipedLeft = swipeAccum <= -threshold
                                val swipedRight = swipeAccum >= threshold
                                when {
                                    swipedLeft && !isRtl -> onNext()
                                    swipedRight && !isRtl -> onPrevious()
                                    swipedRight && isRtl -> onNext()
                                    swipedLeft && isRtl -> onPrevious()
                                }
                                swipeAccum = 0f
                            },
                            onDragCancel = { swipeAccum = 0f },
                        )
                    },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                val hasPrev = state.currentPage > 0
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = if (hasPrev) 0.10f else 0.04f))
                        .clickable(enabled = hasPrev, onClick = onPrevious),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.ChevronLeft,
                        contentDescription = "Previous",
                        tint = Color.White.copy(alpha = if (hasPrev) 1f else 0.28f),
                        modifier = Modifier.size(22.dp),
                    )
                }
                Text(
                    text = pageLabel(indices = visiblePageIndices, total = state.pages.size),
                    color = Color.White.copy(alpha = 0.68f),
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center,
                )
                val hasNext = state.currentPage < state.pages.lastIndex
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = if (hasNext) 0.10f else 0.04f))
                        .clickable(enabled = hasNext, onClick = onNext),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.ChevronRight,
                        contentDescription = "Next",
                        tint = Color.White.copy(alpha = if (hasNext) 1f else 0.28f),
                        modifier = Modifier.size(22.dp),
                    )
                }
            }
        }
    }
}
