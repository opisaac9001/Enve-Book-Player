package com.enve.wear

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Forward30
import androidx.compose.material.icons.rounded.Pause
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Replay30
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.LinearProgressIndicator
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import com.enve.wear.protocol.WearBook
import com.enve.wear.protocol.WearState
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.delay

private val Ember = Color(0xFFF5921A)

class MainActivity : ComponentActivity() {
    private val viewModel by viewModels<WearViewModel>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val state by viewModel.state.collectAsStateWithLifecycle()
            EnveWearTheme {
                CompanionScreen(state, viewModel)
            }
        }
    }

    override fun onStart() {
        super.onStart()
        viewModel.start()
    }

    override fun onStop() {
        viewModel.stop()
        super.onStop()
    }
}

@Composable
private fun EnveWearTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = MaterialTheme.colorScheme.copy(
            primary = Ember,
            background = Color.Black,
            surfaceContainer = Color(0xFF1A1714),
            onBackground = Color.White,
        ),
        content = content,
    )
}

@Composable
private fun CompanionScreen(state: WearUiState, actions: WearViewModel) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 18.dp, vertical = 26.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text("ENVE", color = Ember, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(10.dp))
        when (state.phoneAvailable) {
            false -> {
                if (state.content.updatedAtMs > 0L) {
                    Text("Phone disconnected", color = Color(0xFFB8B2AC))
                    CompanionContent(state.content, false, actions)
                    Spacer(Modifier.height(10.dp))
                    TextButton("Reconnect", onClick = actions::retry)
                } else {
                    PhoneUnavailable(actions::retry)
                }
            }
            else -> CompanionContent(state.content, state.phoneAvailable == null, actions)
        }
        Spacer(Modifier.height(16.dp))
    }
}

@Composable
private fun CompanionContent(state: WearState, loading: Boolean, actions: WearViewModel) {
    var nowMs by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(state.updatedAtMs, state.isPlaying, state.sleepRemainingSec) {
        while (state.isPlaying || state.sleepRemainingSec != null) {
            nowMs = System.currentTimeMillis()
            delay(1_000)
        }
    }
    val elapsedSinceSync = (nowMs - state.updatedAtMs).coerceAtLeast(0L)
    val displayedPosition = if (state.isPlaying) {
        (state.positionMs + elapsedSinceSync).coerceAtMost(state.durationMs)
    } else {
        state.positionMs
    }
    val displayedSleepRemaining = state.sleepRemainingSec?.let {
        (it - TimeUnit.MILLISECONDS.toSeconds(elapsedSinceSync)).coerceAtLeast(0L)
    }
    if (state.hasMedia) {
        Text(
            state.title ?: "Now playing",
            textAlign = TextAlign.Center,
            fontWeight = FontWeight.SemiBold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        state.author?.let { Text(it, color = Color(0xFFB8B2AC), maxLines = 1, overflow = TextOverflow.Ellipsis) }
        Spacer(Modifier.height(8.dp))
        LinearProgressIndicator(
            progress = { if (state.durationMs > 0) (displayedPosition.toFloat() / state.durationMs).coerceIn(0f, 1f) else 0f },
            modifier = Modifier.fillMaxWidth(),
        )
        Text(
            "${formatDuration(displayedPosition)}  ·  −${formatDuration((state.durationMs - displayedPosition).coerceAtLeast(0))}",
            color = Color(0xFFB8B2AC),
        )
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            RoundAction(Icons.Rounded.Replay30, "Back 30 seconds", actions::skipBack)
            RoundAction(if (state.isPlaying) Icons.Rounded.Pause else Icons.Rounded.PlayArrow, if (state.isPlaying) "Pause" else "Play", actions::toggle)
            RoundAction(Icons.Rounded.Forward30, "Forward 30 seconds", actions::skipForward)
        }
    } else {
        Text(if (loading) "Connecting to phone…" else "Nothing playing", textAlign = TextAlign.Center)
    }

    SectionTitle("CONTINUE LISTENING")
    if (state.recentBooks.isEmpty()) {
        Text("Open an audiobook on your phone", color = Color(0xFFB8B2AC), textAlign = TextAlign.Center)
    } else {
        state.recentBooks.take(4).forEach { book -> RecentBookButton(book) { actions.openBook(book.key) } }
    }

    SectionTitle("SLEEP")
    displayedSleepRemaining?.let { remaining ->
        Text("Timer · ${formatSeconds(remaining)} left", color = Ember, fontWeight = FontWeight.SemiBold)
    }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (displayedSleepRemaining == null || displayedSleepRemaining == 0L) {
            TextButton("Start 30 min", Modifier.weight(1f), actions::startSleep)
        } else {
            TextButton("Cancel timer", Modifier.weight(1f), actions::cancelSleep)
        }
    }
    if (state.sleepNights > 0) {
        Spacer(Modifier.height(6.dp))
        Text("Last night ${formatHours(state.lastSleepMs)}", textAlign = TextAlign.Center)
        Text("7-night avg ${formatHours(state.averageSleepMs)}", color = Color(0xFFB8B2AC), textAlign = TextAlign.Center)
    } else {
        Text("Sleep insights appear after phone sync", color = Color(0xFFB8B2AC), textAlign = TextAlign.Center)
    }
}

@Composable
private fun RoundAction(icon: ImageVector, description: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF27211C), contentColor = Color.White),
    ) {
        Icon(icon, contentDescription = description)
    }
}

@Composable
private fun RecentBookButton(book: WearBook, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF1A1714), contentColor = Color.White),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(book.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${(book.progress * 100).toInt()}% · ${book.author.orEmpty()}", color = Color(0xFFB8B2AC), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun TextButton(label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = modifier,
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF27211C), contentColor = Color.White),
    ) {
        Text(label, textAlign = TextAlign.Center)
    }
}

@Composable
private fun SectionTitle(text: String) {
    Spacer(Modifier.height(18.dp))
    Text(text, color = Ember, fontWeight = FontWeight.Bold)
    Spacer(Modifier.height(6.dp))
}

@Composable
private fun PhoneUnavailable(onRetry: () -> Unit) {
    Text("Phone unavailable", fontWeight = FontWeight.SemiBold)
    Text("Keep your phone nearby and open Enve.", color = Color(0xFFB8B2AC), textAlign = TextAlign.Center)
    Spacer(Modifier.height(10.dp))
    TextButton("Retry", onClick = onRetry)
}

private fun formatDuration(milliseconds: Long): String {
    val totalMinutes = TimeUnit.MILLISECONDS.toMinutes(milliseconds.coerceAtLeast(0))
    return "%d:%02d".format(totalMinutes / 60, totalMinutes % 60)
}

private fun formatSeconds(seconds: Long): String = "%d:%02d".format(seconds / 60, seconds % 60)

private fun formatHours(milliseconds: Long?): String {
    if (milliseconds == null) return "—"
    val totalMinutes = TimeUnit.MILLISECONDS.toMinutes(milliseconds)
    return "${totalMinutes / 60}h ${totalMinutes % 60}m"
}
