package com.enve.app.ui.screens

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.enve.app.diagnostics.CrashLogger
import com.enve.app.ui.theme.EnveTheme
import com.enve.hearth.design.hearthDisplay
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@Composable
fun CrashLogsScreen(onBack: () -> Unit = {}) {
    val context = LocalContext.current
    var files by remember { mutableStateOf(CrashLogger.listCrashes(context)) }
    var selected by remember { mutableStateOf<File?>(null) }
    val colors = EnveTheme.colors

    LaunchedEffect(Unit) { files = CrashLogger.listCrashes(context) }

    Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = colors.primaryText)
            }
            Spacer(Modifier.width(4.dp))
            Text(
                text = "Crash Logs",
                color = colors.primaryText,
                style = hearthDisplay(22.sp),
                modifier = Modifier.weight(1f),
            )
            if (files.isNotEmpty()) {
                IconButton(onClick = {
                    CrashLogger.clearAll(context)
                    files = emptyList()
                    selected = null
                }) {
                    Icon(Icons.Default.DeleteSweep, contentDescription = "Clear all", tint = colors.accent)
                }
            }
        }

        val current = selected
        if (current != null) {
            CrashDetail(
                file = current,
                colors = colors,
                onShare = { shareFile(context, current) },
                onClose = { selected = null },
            )
        } else if (files.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    text = "No crashes recorded.",
                    color = colors.secondaryText,
                    fontSize = 14.sp,
                )
            }
        } else {
            LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(files, key = { it.absolutePath }) { file ->
                    CrashRow(file = file, colors = colors, onClick = { selected = file })
                }
            }
        }
    }
}

@Composable
private fun CrashRow(file: File, colors: com.enve.app.ui.theme.EnveColorScheme, onClick: () -> Unit) {
    val timestamp = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date(file.lastModified()))
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(colors.cardBackground)
            .clickable(onClick = onClick)
            .padding(16.dp),
    ) {
        Text(text = file.nameWithoutExtension, color = colors.primaryText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(2.dp))
        Text(text = timestamp, color = colors.secondaryText, fontSize = 12.sp)
        Text(text = "${file.length() / 1024} KB", color = colors.tertiaryText, fontSize = 11.sp)
    }
}

@Composable
private fun CrashDetail(file: File, colors: com.enve.app.ui.theme.EnveColorScheme, onShare: () -> Unit, onClose: () -> Unit) {
    val text = remember(file) { runCatching { file.readText() }.getOrDefault("(failed to read crash file)") }
    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = file.nameWithoutExtension,
                color = colors.primaryText,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onShare) {
                Icon(Icons.Default.Share, contentDescription = "Share", tint = colors.accent)
            }
            Text(
                text = "Close",
                color = colors.accent,
                fontSize = 14.sp,
                modifier = Modifier.clickable(onClick = onClose).padding(8.dp),
            )
        }
        Spacer(Modifier.height(8.dp))
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(RoundedCornerShape(8.dp))
                .background(colors.cardBackground)
                .padding(12.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            Text(
                text = text,
                color = colors.primaryText,
                fontSize = 11.sp,
                fontFamily = FontFamily.Monospace,
            )
        }
    }
}

private fun shareFile(context: Context, file: File) {
    val authority = "${context.packageName}.fileprovider"
    val uri = runCatching { FileProvider.getUriForFile(context, authority, file) }.getOrNull() ?: return
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_STREAM, uri)
        putExtra(Intent.EXTRA_SUBJECT, "Enve crash log: ${file.name}")
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }
    context.startActivity(Intent.createChooser(intent, "Share crash log"))
}
