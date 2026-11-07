package com.enve.app.cloud

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.data.fileimport.CompletedFileImporter
import com.enve.app.profiles.ProfileRuntimeComponent
import com.enve.app.ui.theme.AppTheme
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.engine.eink.EinkMode
import com.enve.engine.eink.EinkState
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthTheme

internal fun ProfileRuntimeComponent.completedFileImporter(): CompletedFileImporter = CompletedFileImporter(
    audioStorage = audioStorage(),
    comicStorage = comicStorage(),
    database = database(),
    locations = storageLocations(),
) {
    downloads().refreshCompletedDownloads()
    comicDownloads().refreshCompletedDownloads()
}

@Composable
internal fun ImportActivityTheme(
    themeViewModel: ThemeViewModel,
    preferences: PreferencesFacade,
    content: @Composable () -> Unit,
) {
    val themeState by themeViewModel.themeState.collectAsStateWithLifecycle()
    val uiTextScale by preferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f)
    val paletteStyle by preferences.paletteStyle.collectAsStateWithLifecycle(initialValue = HearthPaletteStyle.PARCHMENT)
    val profile = themeState.einkProfile
    HearthTheme(
        mode = when (themeState.effectiveAppTheme) {
            AppTheme.SYSTEM -> HearthThemeMode.SYSTEM
            AppTheme.LIGHT, AppTheme.PAPER_WHITE -> HearthThemeMode.PAPER
            else -> HearthThemeMode.INK
        },
        accent = themeState.themeColor,
        oledEnabled = themeState.effectiveAppTheme == AppTheme.OLED,
        paletteStyle = paletteStyle,
        uiTextScale = uiTextScale,
        eink = if (profile.active) {
            HearthEink(
                EinkState(
                    active = true,
                    monochrome = profile.monochrome,
                    mode = EinkMode.valueOf(profile.displayMode.name),
                    boldText = profile.boldText,
                    refreshStrength = profile.refreshStrength,
                ),
            )
        } else {
            HearthEink.Inactive
        },
    ) {
        EnveTheme(
            appTheme = themeState.effectiveAppTheme,
            themeColor = themeState.themeColor,
            dynamicBackgroundEnabled = false,
            einkProfile = profile,
            content = content,
        )
    }
}
