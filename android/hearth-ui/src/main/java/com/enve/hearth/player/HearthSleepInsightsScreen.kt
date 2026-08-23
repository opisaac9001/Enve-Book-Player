package com.enve.hearth.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline

@Composable
fun HearthSleepInsightsScreen(onBack: () -> Unit) {
    val vm: HearthPlayerViewModel = hiltViewModel()
    val palette = Hearth.palette

    Column(Modifier.fillMaxSize().background(palette.bg).navigationBarsPadding()) {
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "Back",
                    tint = palette.text,
                    modifier = Modifier.size(26.dp),
                )
            }
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column(Modifier.weight(1f)) {
                Overline("Nights & listening")
                Text("Sleep", style = HearthText.ScreenTitle, color = palette.text)
            }
        }

        SleepInsightsSheet(
            vm = vm,
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(horizontal = Hearth.Spacing.XL),
        )
    }
}
