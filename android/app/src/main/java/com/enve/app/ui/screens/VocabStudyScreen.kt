package com.enve.app.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.VocabViewModel
import com.enve.core.data.vocab.LeitnerScheduler
import com.enve.hearth.design.hearthDisplay

private val StudySage = Color(0xFF6F8F6A)
private val StudyWine = Color(0xFFA05252)

@Composable
fun VocabStudyScreen(
    onBack: () -> Unit,
    viewModel: VocabViewModel = hiltViewModel(),
) {
    val s by viewModel.session.collectAsStateWithLifecycle()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    LaunchedEffect(Unit) { viewModel.startSession() }

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ScreenBackButton(onClick = onBack)
            Text(
                text = "Study",
                color = colors.primaryText,
                style = hearthDisplay(22.sp),
                modifier = Modifier
                    .weight(1f)
                    .padding(start = DS.Spacing.MD.scaled(metrics)),
            )
        }

        Box(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .padding(20.dp),
            contentAlignment = Alignment.Center,
        ) {
            when {
                s.isEmpty -> Text(
                    "Nothing to study right now.\nSave words while reading, or come back when cards are due.",
                    textAlign = TextAlign.Center,
                    color = colors.secondaryText,
                )
                s.finished -> SessionSummary(s.gotIt, s.again, s.mastered, onBack)
                else -> s.current?.let { card ->
                    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
                        LinearProgressIndicator(
                            progress = { (s.index.toFloat() / s.queue.size).coerceIn(0f, 1f) },
                            modifier = Modifier.fillMaxWidth(),
                            color = colors.accent,
                            trackColor = colors.cardBackground,
                        )
                        Text(
                            "${s.index + 1} / ${s.queue.size}",
                            fontSize = 12.sp,
                            color = colors.secondaryText,
                            modifier = Modifier.padding(top = 8.dp),
                        )

                        Box(
                            modifier = Modifier.weight(1f).fillMaxWidth().padding(vertical = 16.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            FlipCard(
                                revealed = s.revealed,
                                word = card.word,
                                sentence = card.sentence,
                                definition = card.definitionSnapshot,
                                note = card.userNote,
                                onTap = { if (!s.revealed) viewModel.reveal() },
                            )
                        }

                        if (s.revealed) {
                            Row(
                                Modifier.fillMaxWidth().padding(bottom = 8.dp),
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                GradeButton("Again", "1d", Icons.Default.Refresh, StudyWine, Modifier.weight(1f)) {
                                    viewModel.grade(LeitnerScheduler.Action.AGAIN)
                                }
                                GradeButton(
                                    "Got it",
                                    LeitnerScheduler.intervalLabel(minOf(card.studyBox + 1, 4))
                                        .let { if (card.reviewStreak >= 3 && card.studyBox >= 4) "Done" else it },
                                    Icons.Default.Check, colors.accent, Modifier.weight(1f), filled = true,
                                ) { viewModel.grade(LeitnerScheduler.Action.GOT_IT) }
                                GradeButton("Mastered", "Done", Icons.Default.Star, StudySage, Modifier.weight(1f)) {
                                    viewModel.grade(LeitnerScheduler.Action.MASTERED)
                                }
                            }
                        } else {
                            Text(
                                "Tap the card to reveal",
                                fontSize = 13.sp,
                                color = colors.secondaryText,
                                modifier = Modifier.padding(bottom = 24.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun FlipCard(
    revealed: Boolean,
    word: String,
    sentence: String,
    definition: String?,
    note: String?,
    onTap: () -> Unit,
) {
    val colors = EnveTheme.colors
    val rotation by animateFloatAsState(if (revealed) 180f else 0f, tween(420), label = "flip")
    Box(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { rotationY = rotation; cameraDistance = 12f * density }
            .clip(RoundedCornerShape(20.dp))
            .background(colors.cardBackground)
            .border(0.5.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(20.dp))
            .clickable(onClick = onTap)
            .padding(24.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (rotation <= 90f) {

            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    word,
                    style = hearthDisplay(34.sp),
                    color = colors.primaryText,
                    textAlign = TextAlign.Center,
                )
                if (sentence.isNotBlank()) {
                    Spacer(Modifier.height(20.dp))
                    Text(
                        "“$sentence”",
                        fontSize = 14.sp,
                        fontFamily = FontFamily.Serif,
                        textAlign = TextAlign.Center,
                        color = colors.secondaryText,
                        modifier = Modifier.verticalScroll(rememberScrollState()),
                    )
                }
            }
        } else {

            Box(modifier = Modifier.graphicsLayer { rotationY = 180f }) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.verticalScroll(rememberScrollState()),
                ) {
                    Text(word, style = hearthDisplay(22.sp), color = colors.primaryText)
                    Spacer(Modifier.height(16.dp))
                    Text(
                        definition?.takeIf { it.isNotBlank() } ?: "No definition saved.",
                        fontSize = 16.sp,
                        textAlign = TextAlign.Center,
                        color = if (definition.isNullOrBlank()) colors.secondaryText else colors.primaryText,
                    )
                    if (!note.isNullOrBlank()) {
                        Spacer(Modifier.height(16.dp))
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(10.dp))
                                .background(colors.background)
                                .padding(12.dp),
                        ) {
                            Text(note, fontSize = 13.sp, color = colors.secondaryText)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun GradeButton(
    label: String,
    caption: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    color: Color,
    modifier: Modifier = Modifier,
    filled: Boolean = false,
    onClick: () -> Unit,
) {
    val colors = EnveTheme.colors
    Button(
        onClick = onClick,
        modifier = modifier.height(56.dp),
        colors = if (filled) {
            ButtonDefaults.buttonColors(containerColor = color, contentColor = colors.onAccent)
        } else {
            ButtonDefaults.buttonColors(containerColor = Color.Transparent, contentColor = color)
        },
        border = if (filled) null else BorderStroke(1.dp, color),
        shape = RoundedCornerShape(999.dp),
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(icon, label, modifier = Modifier.height(18.dp))
            Text(label, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Text(caption, fontSize = 10.sp)
        }
    }
}

@Composable
private fun SessionSummary(gotIt: Int, again: Int, mastered: Int, onBack: () -> Unit) {
    val colors = EnveTheme.colors
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Session complete", style = hearthDisplay(22.sp), color = colors.primaryText)
        Text(
            "Got it: $gotIt   ·   Again: $again   ·   Mastered: $mastered",
            color = colors.secondaryText,
        )
        Spacer(Modifier.height(8.dp))
        Button(
            onClick = onBack,
            shape = RoundedCornerShape(999.dp),
            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = colors.onAccent),
        ) { Text("Done") }
    }
}
