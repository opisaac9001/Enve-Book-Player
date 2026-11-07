package com.enve.app.ui.screens.reader

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.runtime.Composable
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.center
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.toSize
import com.enve.core.reader.PdfPageAdjust
import com.enve.core.reader.PdfSpread
import com.enve.hearth.design.Hearth
import kotlin.math.roundToInt

internal data class PdfPageTransform(
    val scale: Float = PdfPageZoom.MIN_SCALE,
    val offset: Offset = Offset.Zero,
)

internal object PdfPageZoom {
    const val MIN_SCALE = 1f
    const val MAX_SCALE = 6f
    const val DOUBLE_TAP_SCALE = 2.5f
    private const val FIT_TOLERANCE = 0.02f
    private const val OVERFLOW_TOLERANCE = 1f

    fun baseSize(content: Size, viewport: Size, adjust: PdfPageAdjust): Size {
        if (content.width <= 0f || content.height <= 0f || viewport.width <= 0f || viewport.height <= 0f) return Size.Zero
        val widthRatio = viewport.width / content.width
        val heightRatio = viewport.height / content.height
        val ratio = when (adjust) {
            PdfPageAdjust.CROP -> maxOf(widthRatio, heightRatio)
            PdfPageAdjust.FIT -> minOf(widthRatio, heightRatio)
            PdfPageAdjust.FILL_HEIGHT -> heightRatio
            PdfPageAdjust.FILL_WIDTH -> widthRatio
        }
        return content * ratio
    }

    fun atBase(transform: PdfPageTransform): Boolean = transform.scale <= MIN_SCALE + FIT_TOLERANCE

    fun overflows(transform: PdfPageTransform, viewport: Size, base: Size): Boolean =
        base.width * transform.scale > viewport.width + OVERFLOW_TOLERANCE ||
            base.height * transform.scale > viewport.height + OVERFLOW_TOLERANCE

    fun zoomed(
        transform: PdfPageTransform,
        centroid: Offset,
        pan: Offset,
        zoom: Float,
        viewport: Size,
        base: Size,
    ): PdfPageTransform {
        val scale = (transform.scale * zoom).coerceIn(MIN_SCALE, MAX_SCALE)
        val anchor = centroid - viewport.center
        val offset = anchor + pan - (anchor - transform.offset) * (scale / transform.scale)
        val slackX = ((base.width * scale - viewport.width) / 2f).coerceAtLeast(0f)
        val slackY = ((base.height * scale - viewport.height) / 2f).coerceAtLeast(0f)
        return PdfPageTransform(
            scale,
            Offset(
                if (slackX == 0f) 0f else offset.x.coerceIn(-slackX, slackX),
                if (slackY == 0f) 0f else offset.y.coerceIn(-slackY, slackY),
            ),
        )
    }

    fun toggled(transform: PdfPageTransform, point: Offset, viewport: Size, base: Size): PdfPageTransform =
        if (atBase(transform)) {
            zoomed(transform, point, Offset.Zero, DOUBLE_TAP_SCALE / transform.scale, viewport, base)
        } else {
            PdfPageTransform()
        }

    fun destination(transform: PdfPageTransform, viewport: Size, base: Size): Rect {
        val size = base * transform.scale
        return Rect(viewport.center + transform.offset - Offset(size.width / 2f, size.height / 2f), size)
    }
}

private class PendingPdfTransform {
    var value: PdfPageTransform? = null
}

@Composable
internal fun PdfPageViewport(
    bitmap: Bitmap,
    spread: PdfSpread,
    pageAdjust: PdfPageAdjust,
    contentDescription: String,
    modifier: Modifier = Modifier,
) {
    val eink = Hearth.eink.active
    val image = remember(bitmap) { bitmap.asImageBitmap() }
    val content = Size(bitmap.width.toFloat(), bitmap.height.toFloat())
    var viewport by remember { mutableStateOf(Size.Zero) }
    val base = PdfPageZoom.baseSize(content, viewport, pageAdjust)
    val transform = remember(spread, pageAdjust, viewport, bitmap) { mutableStateOf(PdfPageTransform()) }
    val pending = remember(transform) { PendingPdfTransform() }
    val zoomed = remember(transform) { derivedStateOf { !PdfPageZoom.atBase(transform.value) } }.value
    val overflows = remember(transform, viewport, base) {
        derivedStateOf { PdfPageZoom.overflows(transform.value, viewport, base) }
    }.value

    fun panAction(label: String, dx: Float, dy: Float) = CustomAccessibilityAction(label) {
        val next = PdfPageZoom.zoomed(transform.value, viewport.center, Offset(dx, dy), 1f, viewport, base)
        val moved = next != transform.value
        transform.value = next
        moved
    }

    Canvas(
        modifier
            .clipToBounds()
            .onSizeChanged { viewport = it.toSize() }
            .semantics {
                this.contentDescription = contentDescription
                role = Role.Image
                customActions = buildList {
                    if (zoomed) {
                        add(
                            CustomAccessibilityAction("Reset zoom") {
                                transform.value = PdfPageTransform()
                                true
                            },
                        )
                    } else {
                        add(
                            CustomAccessibilityAction("Zoom in") {
                                transform.value = PdfPageZoom.toggled(transform.value, viewport.center, viewport, base)
                                true
                            },
                        )
                    }
                    if (overflows) {
                        add(panAction("Pan left", viewport.width / 2f, 0f))
                        add(panAction("Pan right", -viewport.width / 2f, 0f))
                        add(panAction("Pan up", 0f, viewport.height / 2f))
                        add(panAction("Pan down", 0f, -viewport.height / 2f))
                    }
                }
            }
            .pointerInput(transform, base) {
                detectTapGestures(
                    onDoubleTap = { point -> transform.value = PdfPageZoom.toggled(transform.value, point, viewport, base) },
                )
            }
            .pointerInput(transform, base, eink) {
                detectTransformGestures { centroid, pan, zoom, _ ->
                    if (eink) {
                        pending.value = PdfPageZoom.zoomed(pending.value ?: transform.value, centroid, pan, zoom, viewport, base)
                    } else {
                        transform.value = PdfPageZoom.zoomed(transform.value, centroid, pan, zoom, viewport, base)
                    }
                }
            }
            .pointerInput(transform) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
                    do {
                        val event = awaitPointerEvent(PointerEventPass.Final)
                    } while (event.changes.any { it.pressed })
                    pending.value?.let { settled ->
                        pending.value = null
                        transform.value = settled
                    }
                }
            },
    ) {
        val target = PdfPageZoom.destination(transform.value, size, PdfPageZoom.baseSize(content, size, pageAdjust))
        drawImage(
            image = image,
            dstOffset = IntOffset(target.left.roundToInt(), target.top.roundToInt()),
            dstSize = IntSize(target.width.roundToInt(), target.height.roundToInt()),
        )
    }
}
