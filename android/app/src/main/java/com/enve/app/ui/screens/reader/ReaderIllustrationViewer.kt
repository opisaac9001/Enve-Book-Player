package com.enve.app.ui.screens.reader

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.enve.app.R
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText

object ReaderIllustrationZoom {
    const val MIN_SCALE = 1f
    const val MAX_SCALE = 6f
    const val DOUBLE_TAP_SCALE = 2.5f
    private const val FIT_TOLERANCE = 0.02f

    fun atFit(scale: Float): Boolean = scale <= MIN_SCALE + FIT_TOLERANCE

    fun clampScale(scale: Float): Float = scale.coerceIn(MIN_SCALE, MAX_SCALE)

    fun fitted(contentWidth: Float, contentHeight: Float, viewWidth: Float, viewHeight: Float): Size {
        if (contentWidth <= 0f || contentHeight <= 0f || viewWidth <= 0f || viewHeight <= 0f) return Size.Zero
        val ratio = minOf(viewWidth / contentWidth, viewHeight / contentHeight)
        return Size(contentWidth * ratio, contentHeight * ratio)
    }

    fun clampPan(offset: Float, viewExtent: Float, scaledContentExtent: Float): Float {
        val slack = ((scaledContentExtent - viewExtent) / 2f).coerceAtLeast(0f)
        return offset.coerceIn(-slack, slack)
    }
}

private class PendingTransform {
    var active = false
    var scale = ReaderIllustrationZoom.MIN_SCALE
    var offset = Offset.Zero
}

@Composable
fun ReaderIllustrationViewer(
    illustration: ReaderIllustration,
    palette: HearthPalette,
    eink: Boolean,
    onDismiss: () -> Unit,
) {
    var scale by remember(illustration) { mutableFloatStateOf(ReaderIllustrationZoom.MIN_SCALE) }
    var offset by remember(illustration) { mutableStateOf(Offset.Zero) }
    var viewport by remember { mutableStateOf(IntSize.Zero) }
    val pending = remember(illustration) { PendingTransform() }
    val bitmap = remember(illustration) { illustration.bitmap.asImageBitmap() }
    val contentWidth = illustration.bitmap.width.toFloat()
    val contentHeight = illustration.bitmap.height.toFloat()
    val backdrop = if (eink) palette.bg else Color.Black
    val ink = if (eink) palette.text else Color.White
    val title = illustration.alt ?: "Illustration"

    fun settle(nextScale: Float, nextOffset: Offset) {
        val fitted = ReaderIllustrationZoom.fitted(
            contentWidth,
            contentHeight,
            viewport.width.toFloat(),
            viewport.height.toFloat(),
        )
        scale = ReaderIllustrationZoom.clampScale(nextScale)
        offset = Offset(
            ReaderIllustrationZoom.clampPan(nextOffset.x, viewport.width.toFloat(), fitted.width * scale),
            ReaderIllustrationZoom.clampPan(nextOffset.y, viewport.height.toFloat(), fitted.height * scale),
        )
    }

    BackHandler(onBack = onDismiss)

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(
            Modifier
                .fillMaxSize()
                .background(backdrop)
                .semantics {
                    isTraversalGroup = true
                    paneTitle = title
                }
                .onSizeChanged { viewport = it }
                .pointerInput(illustration) {
                    detectTapGestures(
                        onTap = { if (ReaderIllustrationZoom.atFit(scale)) onDismiss() },
                        onDoubleTap = { point ->
                            if (ReaderIllustrationZoom.atFit(scale)) {
                                val target = ReaderIllustrationZoom.DOUBLE_TAP_SCALE
                                settle(
                                    target,
                                    Offset(
                                        (viewport.width / 2f - point.x) * (target - 1f),
                                        (viewport.height / 2f - point.y) * (target - 1f),
                                    ),
                                )
                            } else {
                                settle(ReaderIllustrationZoom.MIN_SCALE, Offset.Zero)
                            }
                        },
                    )
                }
                .pointerInput(illustration, eink) {
                    detectTransformGestures { _, pan, zoom, _ ->
                        if (eink) {
                            if (!pending.active) {
                                pending.active = true
                                pending.scale = scale
                                pending.offset = offset
                            }
                            pending.scale = ReaderIllustrationZoom.clampScale(pending.scale * zoom)
                            pending.offset += pan
                        } else {
                            settle(scale * zoom, offset + pan)
                        }
                    }
                }
                .pointerInput(illustration, eink) {
                    awaitEachGesture {
                        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                        do {
                            val event = awaitPointerEvent(PointerEventPass.Final)
                        } while (event.changes.any { it.pressed })
                        if (pending.active) {
                            pending.active = false
                            settle(pending.scale, pending.offset)
                        }
                    }
                },
        ) {
            Image(
                bitmap = bitmap,
                contentDescription = illustration.alt,
                contentScale = ContentScale.Fit,
                modifier = Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = scale
                        scaleY = scale
                        translationX = offset.x
                        translationY = offset.y
                    }
                    .drawBehind {
                        if (eink) return@drawBehind
                        val fitted = ReaderIllustrationZoom.fitted(contentWidth, contentHeight, size.width, size.height)
                        if (fitted.width <= 0f || fitted.height <= 0f) return@drawBehind
                        drawRect(
                            color = Color.White,
                            topLeft = Offset((size.width - fitted.width) / 2f, (size.height - fitted.height) / 2f),
                            size = fitted,
                        )
                    },
            )

            illustration.description?.let { caption ->
                Text(
                    text = caption,
                    color = ink,
                    style = HearthText.Caption,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .safeDrawingPadding()
                        .padding(horizontal = 24.dp, vertical = 16.dp)
                        .background(
                            if (eink) backdrop else Color.Black.copy(alpha = 0.66f),
                            if (eink) RectangleShape else RoundedCornerShape(8.dp),
                        )
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                )
            }

            IconButton(
                onClick = onDismiss,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .safeDrawingPadding()
                    .padding(8.dp),
            ) {
                Icon(
                    Icons.Outlined.Close,
                    contentDescription = stringResource(R.string.close_illustration),
                    tint = ink,
                )
            }
        }
    }
}
