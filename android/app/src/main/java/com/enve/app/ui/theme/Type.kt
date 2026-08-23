package com.enve.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.enve.app.R

val InterFontFamily = FontFamily.SansSerif

fun enveTypography(): Typography {
    val default = Typography()
    return Typography(
        displayLarge = default.displayLarge.copy(fontFamily = InterFontFamily),
        displayMedium = default.displayMedium.copy(fontFamily = InterFontFamily),
        displaySmall = default.displaySmall.copy(fontFamily = InterFontFamily),
        headlineLarge = default.headlineLarge.copy(fontFamily = InterFontFamily),
        headlineMedium = default.headlineMedium.copy(fontFamily = InterFontFamily),
        headlineSmall = default.headlineSmall.copy(fontFamily = InterFontFamily),
        titleLarge = default.titleLarge.copy(fontFamily = InterFontFamily),
        titleMedium = default.titleMedium.copy(fontFamily = InterFontFamily),
        titleSmall = default.titleSmall.copy(fontFamily = InterFontFamily),
        bodyLarge = default.bodyLarge.copy(fontFamily = InterFontFamily),
        bodyMedium = default.bodyMedium.copy(fontFamily = InterFontFamily),
        bodySmall = default.bodySmall.copy(fontFamily = InterFontFamily),
        labelLarge = default.labelLarge.copy(fontFamily = InterFontFamily),
        labelMedium = default.labelMedium.copy(fontFamily = InterFontFamily),
        labelSmall = default.labelSmall.copy(fontFamily = InterFontFamily),
    )
}

object EnveType {
    val LargeTitle = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Bold,
        fontSize = 34.sp,
        lineHeight = 40.sp,
    )
    val Title = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Bold,
        fontSize = 28.sp,
        lineHeight = 34.sp,
    )
    val Title2 = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Bold,
        fontSize = 24.sp,
        lineHeight = 30.sp,
    )
    val Title3 = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
    )
    val Headline = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.SemiBold,
        fontSize = 16.sp,
        lineHeight = 22.sp,
    )
    val Body = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Normal,
        fontSize = 15.sp,
        lineHeight = 21.sp,
    )
    val Subheadline = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Medium,
        fontSize = 14.sp,
        lineHeight = 20.sp,
    )
    val Footnote = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Normal,
        fontSize = 13.sp,
        lineHeight = 18.sp,
    )
    val Caption = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
    )
    val Caption2 = TextStyle(
        fontFamily = InterFontFamily,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 14.sp,
    )
}
