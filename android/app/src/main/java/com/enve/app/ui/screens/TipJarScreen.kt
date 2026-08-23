package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Coffee
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.TipJarState
import com.enve.app.viewmodel.TipProduct
import com.enve.hearth.design.hearthDisplay

@Composable
fun TipJarScreen(
    state: TipJarState,
    dynamicBackgroundEnabled: Boolean = true,
    onBack: () -> Unit = {},
    onRetry: () -> Unit = {},
    onDismissNotice: () -> Unit = {},
    onTip: (String) -> Unit = {},
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

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
                    text = "Tip Jar",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.align(Alignment.Center),
                )
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    Text(
                        text = "Tip Jar",
                        color = colors.primaryText,
                        style = hearthDisplay(28.sp),
                    )
                    Text(
                        text = "Support the development of Enve.",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Title3.scaled(metrics),
                    )
                    Spacer(Modifier.size(10.dp))
                    Row(
                        modifier = Modifier
                            .background(colors.accent.copy(alpha = 0.12f), RoundedCornerShape(999.dp))
                            .padding(horizontal = 14.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            modifier = Modifier
                                .size(10.dp)
                                .background(colors.accent.copy(alpha = 0.7f), CircleShape),
                        )
                        Spacer(Modifier.width(8.dp))
                        Text("100% optional", color = colors.accent, fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics))) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(66.dp)
                                .background(colors.accent.copy(alpha = 0.16f), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) {
                            Icon(Icons.Default.Favorite, null, tint = colors.accent, modifier = Modifier.size(30.dp))
                        }
                        Spacer(Modifier.width(14.dp))
                        Column {
                            Text("Support Development", color = colors.primaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                            Text("Help keep Enve growing", color = colors.secondaryText, fontSize = 14.sp)
                        }
                    }
                    Spacer(Modifier.size(12.dp))
                    Text(
                        text = "Your tips help support continued development of Enve. Every contribution helps add new features and improve quality.",
                        color = colors.secondaryText,
                        fontSize = 15.sp,
                        lineHeight = 24.sp,
                    )
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(modifier = Modifier.padding(DS.Spacing.LG.scaled(metrics)), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("CHOOSE AN AMOUNT", color = colors.tertiaryText, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 1.6.sp)
                    state.products.forEachIndexed { index, product ->
                        TipAmountRow(
                            icon = when (index) {
                                0, 1 -> Icons.Default.Coffee
                                2 -> Icons.Default.Favorite
                                else -> Icons.Default.Star
                            },
                            product = product,
                            isPurchasing = state.purchasingProductId == product.productId,
                            enabled = product.formattedPrice != null && state.purchasingProductId == null,
                            onTip = onTip,
                        )
                    }
                    if (state.isLoading) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            horizontalArrangement = Arrangement.Center,
                        ) {
                            CircularProgressIndicator(color = colors.accent, modifier = Modifier.size(24.dp))
                        }
                    }
                    state.error?.let { error ->
                        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(error, color = colors.secondaryText, fontSize = 14.sp, lineHeight = 20.sp)
                            TextButton(onClick = onRetry) {
                                Text("Try again", color = colors.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    state.notice?.let { notice ->
        AlertDialog(
            onDismissRequest = onDismissNotice,
            title = { Text(notice.title) },
            text = { Text(notice.message) },
            confirmButton = {
                TextButton(onClick = onDismissNotice) {
                    Text("Done")
                }
            },
        )
    }
}

@Composable
private fun TipAmountRow(
    icon: ImageVector,
    product: TipProduct,
    isPurchasing: Boolean,
    enabled: Boolean,
    onTip: (String) -> Unit,
) {
    val colors = EnveTheme.colors
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(colors.secondaryBackground, RoundedCornerShape(18.dp))
            .clickable(enabled = enabled) { onTip(product.productId) }
            .padding(horizontal = 14.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(52.dp)
                .background(colors.accent.copy(alpha = 0.18f), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, null, tint = colors.accent)
        }
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(product.title, color = colors.primaryText, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Text(product.subtitle, color = colors.secondaryText, fontSize = 15.sp)
        }
        if (isPurchasing) {
            CircularProgressIndicator(
                color = colors.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.size(22.dp),
            )
        } else {
            Text(
                product.formattedPrice ?: "Unavailable",
                color = if (enabled) colors.accent else colors.tertiaryText,
                fontSize = 18.sp,
                fontWeight = FontWeight.Black,
            )
        }
    }
}
