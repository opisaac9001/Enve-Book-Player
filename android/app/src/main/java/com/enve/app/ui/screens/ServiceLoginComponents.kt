package com.enve.app.ui.screens

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusEvent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.AdaptiveMetrics
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.scaled
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
internal fun SectionHeader(title: String, icon: ImageVector, metrics: AdaptiveMetrics) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Icon(icon, null, tint = EnveTheme.colors.accent, modifier = Modifier.size(16.dp))
        Text(title, color = EnveTheme.colors.primaryText, fontWeight = FontWeight.SemiBold, fontSize = DS.FontSize.Body.scaled(metrics))
    }
}

@Composable
internal fun EnveTextField(
    value: String, onValueChange: (String) -> Unit,
    label: String, placeholder: String = "", icon: ImageVector,
    keyboardType: KeyboardType = KeyboardType.Text,
    imeAction: ImeAction = ImeAction.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    OutlinedTextField(
        value = value, onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = { Text(placeholder, color = EnveTheme.colors.tertiaryText) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, imeAction = imeAction),
        keyboardActions = keyboardActions,
        modifier = Modifier.fillMaxWidth().bringFocusedFieldIntoView(),
        shape = RoundedCornerShape(DS.Radius.Section),
        colors = enveTextFieldColors(),
        leadingIcon = { Icon(icon, null, tint = EnveTheme.colors.tertiaryText) },
    )
}

@Composable
internal fun EnveSecureTextField(
    value: String, onValueChange: (String) -> Unit,
    label: String, placeholder: String = "", icon: ImageVector,
    imeAction: ImeAction = ImeAction.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    var visible by remember { mutableStateOf(false) }
    OutlinedTextField(
        value = value, onValueChange = onValueChange,
        label = { Text(label) },
        placeholder = { Text(placeholder, color = EnveTheme.colors.tertiaryText) },
        singleLine = true,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(imeAction = imeAction),
        keyboardActions = keyboardActions,
        modifier = Modifier.fillMaxWidth().bringFocusedFieldIntoView(),
        shape = RoundedCornerShape(DS.Radius.Section),
        colors = enveTextFieldColors(),
        leadingIcon = { Icon(icon, null, tint = EnveTheme.colors.tertiaryText) },
        trailingIcon = {
            IconButton(onClick = { visible = !visible }) {
                Icon(if (visible) Icons.Default.Visibility else Icons.Default.VisibilityOff, "Toggle", tint = EnveTheme.colors.tertiaryText)
            }
        },
    )
}

@Composable
internal fun EnvePasswordField(
    value: String, onValueChange: (String) -> Unit,
    label: String = "Password", visible: Boolean, onToggle: () -> Unit,
    imeAction: ImeAction = ImeAction.Default,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    OutlinedTextField(
        value = value, onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (visible) VisualTransformation.None else PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = imeAction),
        keyboardActions = keyboardActions,
        modifier = Modifier.fillMaxWidth().bringFocusedFieldIntoView(),
        shape = RoundedCornerShape(DS.Radius.Section),
        colors = enveTextFieldColors(),
        leadingIcon = { Icon(Icons.Default.Lock, null, tint = EnveTheme.colors.tertiaryText) },
        trailingIcon = {
            IconButton(onClick = onToggle) {
                Icon(if (visible) Icons.Default.Visibility else Icons.Default.VisibilityOff, "Toggle", tint = EnveTheme.colors.tertiaryText)
            }
        },
    )
}

@Composable
internal fun ConnectButton(label: String, isLoading: Boolean, onClick: () -> Unit, enabled: Boolean = true) {
    val colors = EnveTheme.colors
    Button(
        onClick = onClick,
        enabled = enabled && !isLoading,
        modifier = Modifier.fillMaxWidth().height(54.dp),
        shape = RoundedCornerShape(18.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = colors.accent,
            contentColor = colors.onAccent,
            disabledContainerColor = colors.accent.copy(alpha = 0.45f),
            disabledContentColor = Color.Black.copy(alpha = 0.45f),
        ),
    ) {
        if (isLoading) CircularProgressIndicator(modifier = Modifier.size(20.dp), color = colors.onAccent, strokeWidth = 2.dp)
        else Text(label, fontWeight = FontWeight.SemiBold, fontSize = DS.FontSize.Headline)
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun Modifier.bringFocusedFieldIntoView(): Modifier {
    val requester = remember { BringIntoViewRequester() }
    val scope = rememberCoroutineScope()
    return bringIntoViewRequester(requester).onFocusEvent { event ->
        if (event.isFocused) {
            scope.launch {
                delay(120)
                requester.bringIntoView()
            }
        }
    }
}

@Composable
internal fun enveTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedBorderColor = EnveTheme.colors.accent,
    unfocusedBorderColor = EnveTheme.colors.separator,
    focusedContainerColor = EnveTheme.colors.cardBackground.copy(alpha = 0.4f),
    unfocusedContainerColor = EnveTheme.colors.cardBackground.copy(alpha = 0.32f),
    focusedTextColor = EnveTheme.colors.primaryText,
    unfocusedTextColor = EnveTheme.colors.primaryText,
    focusedLabelColor = EnveTheme.colors.accent,
    unfocusedLabelColor = EnveTheme.colors.tertiaryText,
    cursorColor = EnveTheme.colors.accent,
)
