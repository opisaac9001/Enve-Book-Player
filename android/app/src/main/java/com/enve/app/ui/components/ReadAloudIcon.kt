package com.enve.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.path
import androidx.compose.ui.unit.dp

val ReadAloudIcon: ImageVector by lazy {
    val outline = SolidColor(Color.Black)
    val strokeWidth = 2f
    ImageVector.Builder(
        name = "ReadAloud",
        defaultWidth = 26.dp,
        defaultHeight = 30.dp,
        viewportWidth = 26f,
        viewportHeight = 30f,
    ).apply {
        path(
            stroke = outline,
            strokeLineWidth = strokeWidth,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        ) {
            moveTo(6.2959f, 12.6312f)
            curveTo(7.14994f, 11.7153f, 8.18258f, 10.9842f, 9.33011f, 10.4828f)
            curveTo(10.4776f, 9.98148f, 11.7157f, 9.72057f, 12.968f, 9.7162f)
            curveTo(14.2202f, 9.71183f, 15.4601f, 9.96408f, 16.6111f, 10.4574f)
            curveTo(17.7621f, 10.9507f, 18.7998f, 11.6746f, 19.6602f, 12.5845f)
        }
        path(
            stroke = outline,
            strokeLineWidth = strokeWidth,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        ) {
            moveTo(8.97753f, 15.1318f)
            curveTo(9.48995f, 14.5823f, 10.1095f, 14.1436f, 10.7981f, 13.8428f)
            curveTo(11.4866f, 13.542f, 12.2294f, 13.3855f, 12.9808f, 13.3828f)
            curveTo(13.7321f, 13.3802f, 14.4761f, 13.5316f, 15.1667f, 13.8276f)
            curveTo(15.8573f, 14.1236f, 16.4799f, 14.5579f, 16.9961f, 15.1038f)
        }
        path(
            stroke = outline,
            strokeLineWidth = strokeWidth,
            strokeLineCap = StrokeCap.Round,
            strokeLineJoin = StrokeJoin.Round,
        ) {
            moveTo(20.9161f, 19.73f)
            lineTo(17.8867f, 19.73f)
            curveTo(16.8823f, 19.73f, 16.3791f, 19.73f, 15.9233f, 19.8685f)
            curveTo(15.5197f, 19.991f, 15.145f, 20.1917f, 14.8192f, 20.4595f)
            curveTo(14.4511f, 20.762f, 14.1722f, 21.1799f, 13.615f, 22.0157f)
            lineTo(13f, 22.9382f)
            lineTo(12.3781f, 22.0055f)
            curveTo(11.8255f, 21.1765f, 11.5484f, 20.7608f, 11.1818f, 20.4595f)
            curveTo(10.8559f, 20.1917f, 10.4794f, 19.991f, 10.0759f, 19.8685f)
            curveTo(9.61998f, 19.73f, 9.1179f, 19.73f, 8.11346f, 19.73f)
            lineTo(5.08398f, 19.73f)
        }
    }.build()
}
