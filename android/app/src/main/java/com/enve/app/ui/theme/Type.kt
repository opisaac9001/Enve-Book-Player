package com.enve.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.FontFamily

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
