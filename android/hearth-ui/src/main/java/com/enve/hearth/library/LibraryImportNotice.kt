package com.enve.hearth.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.enve.hearth.design.*

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun LibraryImportNotice(details: List<Pair<String, String>>, refreshing: Boolean, onRetry: () -> Unit, onDismiss: () -> Unit) {
    var expanded by rememberSaveable(details) { mutableStateOf(false) }
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S)
        .background(palette.bgElevated, RoundedCornerShape(Hearth.Radius.Inner)).padding(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Text("Library import incomplete", style = HearthText.Label, color = palette.text)
        Text("${details.size} ${if (details.size == 1) "import needs" else "imports need"} attention. Existing books have been kept.", style = HearthText.Caption, color = palette.textSecondary)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            QuietButton(if (expanded) "Hide details" else "Show details", { expanded = !expanded })
            if (refreshing) Text("Retrying…", style = HearthText.Caption, color = palette.textSecondary)
            else QuietButton("Retry", onRetry)
            QuietButton("Dismiss", onDismiss)
        }
        if (expanded) {
            Column(Modifier.fillMaxWidth().heightIn(max = 240.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                details.forEach { (label, message) ->
                    Column {
                        Text(label, style = HearthText.Label, color = palette.text)
                        Text(message, style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
            }
        }
    }
}
