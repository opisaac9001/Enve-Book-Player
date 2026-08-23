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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.core.data.model.Book
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.LibraryViewModel
import com.enve.hearth.design.hearthDisplay

@Composable
fun HiddenBooksScreen(
    onBack: () -> Unit,
    dynamicBackgroundEnabled: Boolean = true,
    viewModel: LibraryViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    var showClearConfirm by remember { mutableStateOf(false) }

    val hiddenList = remember(state.hiddenBookIds) {
        state.hiddenBookIds.sorted().map { id -> id to null }
    }

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Text(
                    text = "Hidden Books",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsHeroHeader(
                title = "Hidden Books",
                subtitle = "Manage books hidden from your library. Unhide items anytime.",
                badge = "${state.hiddenBookIds.size} hidden",
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            if (hiddenList.isEmpty()) {
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(DS.Spacing.LG.scaled(metrics)),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(
                            Icons.Default.VisibilityOff,
                            contentDescription = null,
                            tint = colors.tertiaryText,
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(Modifier.height(DS.Spacing.MD.scaled(metrics)))
                        Text(
                            "No hidden books.",
                            color = colors.secondaryText,
                            fontSize = DS.FontSize.Body.scaled(metrics),
                        )
                    }
                }
            } else {
                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "HIDDEN ITEMS",
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.SemiBold,
                            letterSpacing = 1.6.sp,
                            modifier = Modifier.weight(1f),
                        )
                        TextButton(onClick = { showClearConfirm = true }) {
                            Text("Unhide All", color = Color(0xFFB3453E), fontWeight = FontWeight.SemiBold)
                        }
                    }

                    LazyColumn(modifier = Modifier.fillMaxWidth()) {
                        items(hiddenList, key = { it.first }) { (id, book) ->
                            HiddenBookRow(
                                id = id,
                                book = book,
                                onUnhide = { viewModel.unhideBooks(listOf(id)) },
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(80.dp))
        }
    }

    if (showClearConfirm) {
        AlertDialog(
            onDismissRequest = { showClearConfirm = false },
            title = { Text("Unhide all books?", color = colors.primaryText) },
            text = { Text("This will restore every hidden book to your library.", color = colors.secondaryText) },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.clearHiddenBooks()
                    showClearConfirm = false
                }) {
                    Text("Unhide All", color = Color(0xFFB3453E), fontWeight = FontWeight.Bold)
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirm = false }) {
                    Text("Cancel", color = colors.accent)
                }
            },
            containerColor = colors.cardBackground,
        )
    }
}

@Composable
private fun HiddenBookRow(
    id: String,
    book: Book?,
    onUnhide: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = book?.title ?: "Hidden Book",
                color = colors.primaryText,
                fontSize = DS.FontSize.Subheadline.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val subtitle = book?.author ?: id
            Text(
                text = subtitle,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
        TextButton(onClick = onUnhide) {
            Text("Unhide", color = colors.accent, fontWeight = FontWeight.SemiBold)
        }
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .height(0.5.dp)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics))
            .background(colors.separator.copy(alpha = 0.3f)),
    )
}
