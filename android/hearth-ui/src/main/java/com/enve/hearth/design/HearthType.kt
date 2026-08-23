package com.enve.hearth.design

import androidx.compose.material3.Typography
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.sp

val HearthSerif = FontFamily.Serif
val HearthSans = FontFamily.SansSerif

fun hearthDisplay(size: TextUnit, weight: FontWeight = FontWeight.Bold) = TextStyle(
    fontFamily = HearthSerif,
    fontWeight = weight,
    fontSize = size,
)

fun hearthUI(size: TextUnit, weight: FontWeight = FontWeight.Normal) = TextStyle(
    fontFamily = HearthSans,
    fontWeight = weight,
    fontSize = size,
)

object HearthText {
    val ScreenTitle = hearthDisplay(32.sp)
    val BookTitle = hearthDisplay(22.sp, FontWeight.SemiBold)
    val SectionNumber = hearthDisplay(40.sp)
    val Body = hearthUI(16.sp)
    val Caption = hearthUI(13.sp)
    val Label = hearthUI(15.sp, FontWeight.Medium)

    val Overline = TextStyle(
        fontFamily = HearthSans,
        fontWeight = FontWeight.SemiBold,
        fontSize = 11.sp,
        letterSpacing = 1.5.sp,
    )
}

@Composable
fun hearthMaterialTypography(): Typography {
    val base = Typography()
    return Typography(
        displayLarge = base.displayLarge.copy(fontFamily = HearthSerif),
        displayMedium = base.displayMedium.copy(fontFamily = HearthSerif),
        displaySmall = base.displaySmall.copy(fontFamily = HearthSerif),
        headlineLarge = base.headlineLarge.copy(fontFamily = HearthSerif),
        headlineMedium = base.headlineMedium.copy(fontFamily = HearthSerif),
        headlineSmall = base.headlineSmall.copy(fontFamily = HearthSerif),
        titleLarge = base.titleLarge.copy(fontFamily = HearthSerif),
        titleMedium = base.titleMedium.copy(fontFamily = HearthSans),
        titleSmall = base.titleSmall.copy(fontFamily = HearthSans),
        bodyLarge = base.bodyLarge.copy(fontFamily = HearthSans),
        bodyMedium = base.bodyMedium.copy(fontFamily = HearthSans),
        bodySmall = base.bodySmall.copy(fontFamily = HearthSans),
        labelLarge = base.labelLarge.copy(fontFamily = HearthSans),
        labelMedium = base.labelMedium.copy(fontFamily = HearthSans),
        labelSmall = base.labelSmall.copy(fontFamily = HearthSans),
    )
}
