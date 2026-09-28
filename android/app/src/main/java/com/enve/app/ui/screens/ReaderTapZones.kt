package com.enve.app.ui.screens

enum class ReaderTapZone {
    LEFT_EDGE,
    CENTER,
    RIGHT_EDGE,
}

object ReaderTapZones {
    fun zoneAt(x: Float, width: Float, edgeFraction: Float): ReaderTapZone {
        val edge = width * edgeFraction.coerceIn(0.15f, 0.35f)
        return when {
            x < edge -> ReaderTapZone.LEFT_EDGE
            x > width - edge -> ReaderTapZone.RIGHT_EDGE
            else -> ReaderTapZone.CENTER
        }
    }
}
