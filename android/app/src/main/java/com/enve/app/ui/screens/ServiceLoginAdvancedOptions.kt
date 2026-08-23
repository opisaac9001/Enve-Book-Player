// AGENT-LOCKED
package com.enve.app.ui.screens

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Error
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Shield
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VpnKey
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.ConnectionCapability
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.auth.AuthState
import com.enve.app.ui.theme.AdaptiveMetrics
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.scaled

@Composable
internal fun AdvancedOptionsSection(
    capability: ConnectionCapability,
    authState: AuthState,
    expanded: Boolean,
    onToggle: () -> Unit,
    metrics: AdaptiveMetrics,
    onServiceClientIdChange: (String) -> Unit,
    onServiceClientSecretChange: (String) -> Unit,
    onCustomHeaderAdd: (String, String) -> Unit,
    onCustomHeaderRemove: (String) -> Unit,
    onMtlsEnabledChange: (Boolean) -> Unit,
    onMtlsCertSelected: (ByteArray) -> Unit,
    onMtlsCertPasswordChange: (String) -> Unit,
    onMtlsCertClear: () -> Unit,
    onAuthenticateInBrowser: () -> Unit,
    browserSignInEnabled: Boolean,
) {
    val colors = EnveTheme.colors
    val activeCount = listOfNotNull(
        "svc".takeIf { authState.serviceClientId.isNotBlank() || authState.serviceClientSecret.isNotBlank() },
        "hdr".takeIf { authState.customHeaders.isNotEmpty() },
        "tls".takeIf { authState.mtlsEnabled },
    ).size

    SettingsCard {
        Column(Modifier.fillMaxWidth()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onToggle)
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
            ) {
                Icon(Icons.Default.Tune, null, tint = colors.secondaryText, modifier = Modifier.size(18.dp))
                Text("Advanced Options", color = colors.primaryText, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                if (activeCount > 0 && !expanded) {
                    Surface(shape = CircleShape, color = colors.accent.copy(alpha = 0.15f)) {
                        Text("$activeCount", color = colors.accent, fontSize = 11.sp, fontWeight = FontWeight.Bold, modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp))
                    }
                }
                Icon(
                    if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    if (expanded) "Collapse" else "Expand",
                    tint = colors.tertiaryText, modifier = Modifier.size(20.dp),
                )
            }

            AnimatedVisibility(visible = expanded, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(start = DS.Spacing.LG.scaled(metrics), end = DS.Spacing.LG.scaled(metrics), bottom = DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
                ) {
                    HorizontalDivider(color = colors.separator, thickness = 0.5.dp)

                    if (capability.supportsBrowserSignIn) BrowserSignInSection(
                        metrics = metrics,
                        enabled = browserSignInEnabled,
                        onAuthenticate = onAuthenticateInBrowser,
                    )
                    if (capability.supportsServiceTokens) ServiceTokensSection(
                        clientId = authState.serviceClientId,
                        clientSecret = authState.serviceClientSecret,
                        metrics = metrics,
                        onClientIdChange = onServiceClientIdChange,
                        onClientSecretChange = onServiceClientSecretChange,
                    )
                    if (capability.supportsCustomHeaders) CustomHeadersSection(
                        headers = authState.customHeaders, metrics = metrics, onAdd = onCustomHeaderAdd, onRemove = onCustomHeaderRemove,
                    )
                    if (capability.supportsMtls) MtlsSection(
                        authState = authState, metrics = metrics,
                        onEnabledChange = onMtlsEnabledChange,
                        onCertSelected = onMtlsCertSelected,
                        onPasswordChange = onMtlsCertPasswordChange,
                        onCertClear = onMtlsCertClear,
                    )
                }
            }
        }
    }
}

@Composable
private fun BrowserSignInSection(
    metrics: AdaptiveMetrics,
    enabled: Boolean,
    onAuthenticate: () -> Unit,
) {
    val colors = EnveTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
        SectionHeader("Zero Trust / Browser Sign-In", Icons.Default.Security, metrics)
        Text(
            if (enabled) {
                "If your server is behind Cloudflare Access or a similar zero-trust proxy, authenticate in a browser first. " +
                    "Session cookies will be attached to subsequent requests automatically."
            } else {
                "Enter your server URL above to enable browser sign-in for Cloudflare Access or similar zero-trust proxies."
            },
            color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics),
        )
        OutlinedButton(
            onClick = onAuthenticate,
            enabled = enabled,
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            border = ButtonDefaults.outlinedButtonBorder(enabled).copy(
                brush = SolidColor(if (enabled) colors.accent else colors.tertiaryText),
            ),
        ) {
            Icon(
                Icons.Default.OpenInBrowser, null,
                modifier = Modifier.size(18.dp),
                tint = if (enabled) colors.accent else colors.tertiaryText,
            )
            Spacer(Modifier.width(8.dp))
            Text(
                "Authenticate in Browser",
                color = if (enabled) colors.accent else colors.tertiaryText,
            )
        }
    }
}

@Composable
private fun ServiceTokensSection(
    clientId: String,
    clientSecret: String,
    metrics: AdaptiveMetrics,
    onClientIdChange: (String) -> Unit,
    onClientSecretChange: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
        SectionHeader("Service Tokens", Icons.Default.VpnKey, metrics)
        Text(
            "Cloudflare Access service tokens. These are added as CF-Access-Client-Id and CF-Access-Client-Secret headers to every request.",
            color = EnveTheme.colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics),
        )
        EnveTextField(value = clientId, onValueChange = onClientIdChange, label = "CF-Access-Client-Id", placeholder = "xxxxxxxx.access", icon = Icons.Default.Badge)
        EnveSecureTextField(value = clientSecret, onValueChange = onClientSecretChange, label = "CF-Access-Client-Secret", placeholder = "Client secret", icon = Icons.Default.Key)
    }
}

@Composable
private fun CustomHeadersSection(
    headers: Map<String, String>,
    metrics: AdaptiveMetrics,
    onAdd: (String, String) -> Unit,
    onRemove: (String) -> Unit,
) {
    val colors = EnveTheme.colors
    var newKey by remember { mutableStateOf("") }
    var newValue by remember { mutableStateOf("") }

    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
        SectionHeader("Custom Headers", Icons.Default.Code, metrics)
        Text("Added to every request to this server.", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))

        headers.forEach { (key, value) ->
            Row(
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(colors.background.copy(alpha = 0.4f)).padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(key, color = colors.primaryText, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                    Text(value, color = colors.secondaryText, fontSize = 12.sp, maxLines = 1)
                }
                IconButton(onClick = { onRemove(key) }, modifier = Modifier.size(32.dp)) {
                    Icon(Icons.Default.Close, "Remove", tint = colors.tertiaryText, modifier = Modifier.size(16.dp))
                }
            }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = newKey, onValueChange = { newKey = it },
                placeholder = { Text("Header name", color = colors.tertiaryText) },
                singleLine = true, modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(DS.Radius.Section), colors = enveTextFieldColors(),
                textStyle = LocalTextStyle.current.copy(fontSize = 13.sp),
            )
            OutlinedTextField(
                value = newValue, onValueChange = { newValue = it },
                placeholder = { Text("Value", color = colors.tertiaryText) },
                singleLine = true, modifier = Modifier.weight(1f),
                shape = RoundedCornerShape(DS.Radius.Section), colors = enveTextFieldColors(),
                textStyle = LocalTextStyle.current.copy(fontSize = 13.sp),
            )
            IconButton(
                onClick = {
                    if (newKey.isNotBlank()) { onAdd(newKey.trim(), newValue.trim()); newKey = ""; newValue = "" }
                },
                modifier = Modifier.size(40.dp).clip(RoundedCornerShape(10.dp)).background(if (newKey.isNotBlank()) colors.accent else colors.cardBackground),
            ) {
                Icon(Icons.Default.Add, "Add", tint = if (newKey.isNotBlank()) colors.onAccent else colors.tertiaryText)
            }
        }
    }
}

@Composable
private fun MtlsSection(
    authState: AuthState,
    metrics: AdaptiveMetrics,
    onEnabledChange: (Boolean) -> Unit,
    onCertSelected: (ByteArray) -> Unit,
    onPasswordChange: (String) -> Unit,
    onCertClear: () -> Unit,
) {
    val colors = EnveTheme.colors
    val context = LocalContext.current

    val certLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        runCatching {
            context.contentResolver.openInputStream(uri)?.use { onCertSelected(it.readBytes()) }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                SectionHeader("Client Certificate (mTLS)", Icons.Default.Shield, metrics)
                Text("Present a client certificate to authenticate with the server.", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
            }
            Switch(
                checked = authState.mtlsEnabled, onCheckedChange = onEnabledChange,
                colors = SwitchDefaults.colors(checkedTrackColor = colors.accent, checkedThumbColor = Color.White),
            )
        }

        AnimatedVisibility(visible = authState.mtlsEnabled, enter = expandVertically() + fadeIn(), exit = shrinkVertically() + fadeOut()) {
            Column(verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                OutlinedButton(
                    onClick = { certLauncher.launch(arrayOf("application/x-pkcs12", "application/pkcs12", "*/*")) },
                    modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp),
                ) {
                    Icon(Icons.Default.FileOpen, null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(if (authState.mtlsCertSubject != null || authState.mtlsCertBytes != null) "Replace Certificate (.p12 / .pfx)" else "Import Certificate (.p12 / .pfx)")
                }

                when {
                    authState.mtlsCertSubject != null -> {
                        Row(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Color(0xFF34C759).copy(alpha = 0.1f)).padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Default.CheckCircle, null, tint = Color(0xFF34C759), modifier = Modifier.size(18.dp))
                            Column(Modifier.weight(1f)) {
                                Text("Certificate loaded", color = Color(0xFF34C759), fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                                Text(authState.mtlsCertSubject, color = colors.secondaryText, fontSize = 11.sp, maxLines = 2)
                            }
                            IconButton(onClick = onCertClear, modifier = Modifier.size(32.dp)) {
                                Icon(Icons.Default.Close, "Remove", tint = colors.tertiaryText, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    authState.mtlsCertError != null -> {
                        Row(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Color(0xFFFF453A).copy(alpha = 0.1f)).padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            Icon(Icons.Default.Error, null, tint = Color(0xFFFF453A), modifier = Modifier.size(18.dp))
                            Text(authState.mtlsCertError, color = Color(0xFFFF453A), fontSize = 12.sp, modifier = Modifier.weight(1f))
                        }
                    }
                }

                EnvePasswordField(
                    value = authState.mtlsCertPassword, onValueChange = onPasswordChange,
                    label = "Certificate Password (if required)", visible = false, onToggle = {},
                )
            }
        }
    }
}
