package com.enve.app.ui.screens.reader

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect

internal data class PdfPageSlot(
    val pageIndex: Int,
    val left: Float,
    val width: Float,
    val pageWidth: Int,
    val pageHeight: Int,
)

internal data class PdfPagePoint(val x: Int, val y: Int)

internal object PdfSpreadGeometry {
    fun slots(pages: List<Int>, pageSizes: List<Pair<Int, Int>>, pixelWidths: List<Int>): List<PdfPageSlot> {
        val total = pixelWidths.sum().toFloat()
        var left = 0
        return pages.mapIndexed { slot, pageIndex ->
            val width = pixelWidths[slot]
            PdfPageSlot(pageIndex, left / total, width / total, pageSizes[slot].first, pageSizes[slot].second).also { left += width }
        }
    }

    fun slotAt(slots: List<PdfPageSlot>, fraction: Offset): PdfPageSlot? {
        if (fraction.y !in 0f..1f) return null
        return slots.firstOrNull { fraction.x >= it.left && fraction.x <= it.left + it.width }
    }

    fun pagePoint(slot: PdfPageSlot, fraction: Offset): PdfPagePoint {
        val x = ((fraction.x - slot.left) / slot.width).coerceIn(0f, 1f) * slot.pageWidth
        val y = fraction.y.coerceIn(0f, 1f) * slot.pageHeight
        return PdfPagePoint(x.toInt(), y.toInt())
    }

    fun spreadRect(slot: PdfPageSlot, left: Float, top: Float, right: Float, bottom: Float): Rect = Rect(
        left = slot.left + left / slot.pageWidth * slot.width,
        top = top / slot.pageHeight,
        right = slot.left + right / slot.pageWidth * slot.width,
        bottom = bottom / slot.pageHeight,
    )
}
