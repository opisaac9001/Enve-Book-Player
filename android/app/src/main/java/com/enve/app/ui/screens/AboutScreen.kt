package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.PrivacyTip
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.BuildConfig
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.einkAwareBackground
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.hearth.design.hearthDisplay

@Composable
fun AboutScreen(
    dynamicBackgroundEnabled: Boolean = true,
    onOpenTipJar: () -> Unit = {},
    onReportIssue: () -> Unit = {},
    onRateApp: () -> Unit = {},
    onOpenWebsite: () -> Unit = {},
    onOpenPrivacyPolicy: () -> Unit = {},
    onBack: () -> Unit = {},
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.5f)
    var dialogState by remember { mutableStateOf<Pair<String, String>?>(null) }

    dialogState?.let { (title, message) ->
        AlertDialog(
            onDismissRequest = { dialogState = null },
            title = { Text(title) },
            text = { Text(message) },
            confirmButton = {
                TextButton(onClick = { dialogState = null }) {
                    Text("OK")
                }
            },
        )
    }

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(bottom = 80.dp),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {

            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            ) {
                IconButton(
                    onClick = onBack,
                    modifier = Modifier
                        .align(Alignment.CenterStart)
                        .background(colors.cardBackground, CircleShape),
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = colors.primaryText)
                }
                Text(
                    text = "About",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            val einkActive = EnveTheme.eink.active
            val heroShape = if (einkActive) RoundedCornerShape(4.dp) else RoundedCornerShape(30.dp)
            Box(
                modifier = Modifier
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics))
                    .fillMaxWidth()
                    .clip(heroShape)
                    .einkAwareBackground(
                        brush = SolidColor(colors.cardBackground),
                        einkFill = colors.background,
                        einkBorder = colors.primaryText,
                        shape = heroShape,
                    )
                    .then(
                        if (einkActive) Modifier
                        else Modifier.border(0.5.dp, Color.White.copy(alpha = 0.08f), heroShape)
                    ),
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 40.dp, horizontal = DS.Spacing.LG.scaled(metrics)),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {

                    val iconShape = if (einkActive) RoundedCornerShape(4.dp) else RoundedCornerShape(28.dp)
                    Box(
                        modifier = Modifier
                            .size(96.dp)
                            .einkAwareBackground(
                                brush = SolidColor(colors.accent),
                                einkFill = colors.primaryText,
                                shape = iconShape,
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            "E",
                            color = if (einkActive) colors.background else Color.White,
                            fontSize = 52.sp,
                            fontWeight = FontWeight.Black,
                        )
                    }

                    Spacer(Modifier.height(20.dp))

                    Text(
                        text = "Enve",
                        color = colors.primaryText,
                        style = hearthDisplay(36.sp),
                    )

                    Text(
                        text = "Version ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})",
                        color = colors.secondaryText,
                        fontSize = 14.sp,
                    )

                    Spacer(Modifier.height(DS.Spacing.LG.scaled(metrics)))

                    Text(
                        text = "Your premium audiobook and ebook companion. Built for listeners and readers who want one beautiful home for everything.",
                        color = colors.secondaryText,
                        fontSize = 14.sp,
                        textAlign = TextAlign.Center,
                        lineHeight = 22.sp,
                    )
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                AboutLinkRow(
                    icon = Icons.Default.Star,
                    tint = colors.accent,
                    title = "Rate Enve",
                    subtitle = "Leave a review on the Play Store",
                    onClick = onRateApp,
                )
                HorizontalDivider(color = dividerColor)
                AboutLinkRow(
                    icon = Icons.Default.Favorite,
                    tint = Color(0xFFA05252),
                    title = "Tip Jar",
                    subtitle = "Support Enve's development",
                    onClick = onOpenTipJar,
                )
                HorizontalDivider(color = dividerColor)
                AboutLinkRow(
                    icon = Icons.Default.Language,
                    tint = Color(0xFF64748B),
                    title = "Website",
                    subtitle = "enveapp.io",
                    onClick = onOpenWebsite,
                )
                HorizontalDivider(color = dividerColor)
                AboutLinkRow(
                    icon = Icons.Default.AutoAwesome,
                    tint = Color(0xFF6F8F6A),
                    title = "Report an Issue",
                    subtitle = "Help us improve Enve",
                    onClick = onReportIssue,
                )
                HorizontalDivider(color = dividerColor)
                AboutLinkRow(
                    icon = Icons.Default.PrivacyTip,
                    tint = Color(0xFF64748B),
                    title = "Privacy Policy",
                    subtitle = "How Enve handles your data",
                    onClick = onOpenPrivacyPolicy,
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                ) {
                    Icon(
                        Icons.Default.Info,
                        null,
                        tint = colors.accent,
                        modifier = Modifier.size(22.dp),
                    )
                    Spacer(Modifier.height(DS.Spacing.XS.scaled(metrics)))
                    AboutTechRow(label = "Version", value = BuildConfig.VERSION_NAME)
                    HorizontalDivider(color = dividerColor)
                    AboutTechRow(label = "Build", value = BuildConfig.VERSION_CODE.toString())
                    HorizontalDivider(color = dividerColor)
                    AboutTechRow(label = "Platform", value = "Android")
                    HorizontalDivider(color = dividerColor)
                    AboutTechRow(label = "Min API", value = "26 (Android 8)")
                    HorizontalDivider(color = dividerColor)
                    AboutTechRow(label = "Target API", value = "35")
                    HorizontalDivider(color = dividerColor)
                }
            }
        }
    }
}

@Composable
private fun AboutLinkRow(
    icon: ImageVector,
    tint: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .background(tint.copy(alpha = 0.14f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, color = colors.primaryText, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(subtitle, color = colors.secondaryText, fontSize = 12.sp)
        }
        Icon(Icons.AutoMirrored.Filled.OpenInNew, null, tint = colors.tertiaryText, modifier = Modifier.size(16.dp))
    }
}

@Composable
private fun AboutTechRow(label: String, value: String) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = DS.Spacing.SM.scaled(metrics)),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, color = colors.secondaryText, fontSize = 14.sp)
        Text(value, color = colors.primaryText, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}
