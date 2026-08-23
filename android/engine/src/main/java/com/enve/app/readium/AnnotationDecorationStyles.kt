package com.enve.app.readium

import android.graphics.Color
import androidx.annotation.ColorInt
import kotlinx.parcelize.Parcelize
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.html.HtmlDecorationTemplate

@Parcelize
data class StrikethroughStyle(@get:ColorInt val tint: Int) : Decoration.Style

@Parcelize
data class SquigglyStyle(@get:ColorInt val tint: Int) : Decoration.Style

private fun @receiver:ColorInt Int.toRgba(alpha: Double = 0.85): String {
    val r = Color.red(this)
    val g = Color.green(this)
    val b = Color.blue(this)
    return "rgba($r,$g,$b,${alpha.coerceIn(0.0, 1.0)})"
}

fun strikethroughTemplate(@ColorInt defaultTint: Int = Color.RED): HtmlDecorationTemplate {
    val cls = "enve-strikethrough"
    return HtmlDecorationTemplate(
        layout = HtmlDecorationTemplate.Layout.BOXES,
        element = { decoration ->
            val tint = (decoration.style as? StrikethroughStyle)?.tint ?: defaultTint
            val color = tint.toRgba(0.9)
            """<div class="$cls" style="--enve-st-color: $color !important"/>"""
        },
        stylesheet = """
            .$cls {
                display: block;
                position: relative;
                pointer-events: none;
            }
            .$cls::after {
                content: '';
                position: absolute;
                left: 0; right: 0;
                top: 50%;
                height: 2px;
                background-color: var(--enve-st-color, rgba(220,50,50,0.9));
                transform: translateY(-50%);
            }
        """.trimIndent(),
    )
}

fun squigglyTemplate(@ColorInt defaultTint: Int = Color.BLUE): HtmlDecorationTemplate {
    val cls = "enve-squiggly"
    return HtmlDecorationTemplate(
        layout = HtmlDecorationTemplate.Layout.BOXES,
        element = { decoration ->
            val tint = (decoration.style as? SquigglyStyle)?.tint ?: defaultTint
            val color = tint.toRgba(0.9)
            """<div class="$cls" style="--enve-sq-color: $color !important"/>"""
        },
        stylesheet = """
            .$cls {
                display: block;
                position: relative;
                pointer-events: none;
            }
            .$cls::after {
                content: '';
                position: absolute;
                left: 0; right: 0;
                bottom: 1px;
                height: 3px;
                background:
                    repeating-linear-gradient(
                        135deg,
                        var(--enve-sq-color, rgba(50,50,220,0.9)) 0px,
                        var(--enve-sq-color, rgba(50,50,220,0.9)) 1px,
                        transparent 1px,
                        transparent 4px
                    ),
                    repeating-linear-gradient(
                        45deg,
                        var(--enve-sq-color, rgba(50,50,220,0.9)) 0px,
                        var(--enve-sq-color, rgba(50,50,220,0.9)) 1px,
                        transparent 1px,
                        transparent 4px
                    );
            }
        """.trimIndent(),
    )
}
