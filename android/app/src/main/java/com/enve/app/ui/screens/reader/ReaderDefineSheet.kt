package com.enve.app.ui.screens.reader

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.viewmodel.ReaderDefinition
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay

@Composable
internal fun ReaderDefineSheet(definition: ReaderDefinition, onSaveWord: () -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(bottom = Hearth.Spacing.XXL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        Text(definition.term, style = hearthDisplay(26.sp, FontWeight.SemiBold), color = palette.text)
        when {
            definition.loading -> Box(Modifier.fillMaxWidth().heightIn(min = 96.dp), contentAlignment = Alignment.Center) {
                if (Hearth.eink.suppressAnimations) {
                    Text("Looking up…", style = HearthText.Body, color = palette.textSecondary)
                } else {
                    CircularProgressIndicator(color = palette.ember)
                }
            }
            definition.text.isNullOrBlank() -> Text(
                "No definition to be found for “${definition.term}”.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            else -> Text(
                definition.text,
                style = hearthDisplay(16.sp, FontWeight.Normal),
                color = palette.text,
                modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState()),
            )
        }
        if (!definition.loading) {
            if (definition.saved) {
                Text("Kept in your vocabulary.", style = HearthText.Caption, color = palette.textSecondary)
            } else {
                QuietButton("Save word", onSaveWord)
            }
        }
    }
}
