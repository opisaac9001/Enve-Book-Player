package com.enve.app.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.auth.QuickConnectUiState
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ConnectionAuthMode

@Composable
fun QuickConnectScreen(
    quickConnect: QuickConnectUiState,
    onBack: () -> Unit,
    onProbe: (String) -> Unit,
    onConsumeResult: () -> Unit,
    onNavigateToManual: () -> Unit,
    onNavigateToServiceLogin: (BookSource, String, Boolean) -> Unit,
) {
    val focusManager = LocalFocusManager.current
    var address by rememberSaveable { mutableStateOf("") }
    val colors = EnveTheme.colors
    val mono = EnveTheme.eink.monochrome
    val bg = if (mono) colors.background else Color.Black
    val card = if (mono) colors.cardBackground else Color(0xFF111113)
    val border = if (mono) colors.primaryText else Color.White.copy(alpha = 0.12f)
    val primary = if (mono) colors.primaryText else Color(0xFFF3EDE4)
    val secondary = if (mono) colors.secondaryText else Color(0xFF8F8780)
    val ember = if (mono) colors.primaryText else Color(0xFF965A0A)

    LaunchedEffect(quickConnect.result) {
        val result = quickConnect.result ?: return@LaunchedEffect
        onConsumeResult()
        onNavigateToServiceLogin(
            result.source,
            result.normalizedUrl,
            result.recommendedAuth == ConnectionAuthMode.SSO,
        )
    }

    val submit = {
        focusManager.clearFocus()
        onProbe(address)
    }

    Box(Modifier.fillMaxSize().background(bg)) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 48.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .background(card)
                        .border(1.dp, border, CircleShape)
                        .clickable(onClick = onBack),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = primary, modifier = Modifier.size(22.dp))
                }
                Column(Modifier.padding(start = 16.dp)) {
                    Text("BRING YOUR BOOKS", color = secondary, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 4.sp)
                    Text(
                        "Sign in to\nyour server",
                        color = primary,
                        fontSize = 31.sp,
                        lineHeight = 35.sp,
                        fontFamily = FontFamily.Serif,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }

            Spacer(Modifier.height(30.dp))

            Column(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(20.dp))
                    .background(card)
                    .border(1.dp, border, RoundedCornerShape(20.dp))
                    .padding(18.dp),
            ) {
                Text(
                    "Enter your library's web address and Enve figures out the rest.",
                    color = secondary,
                    fontSize = 14.sp,
                    lineHeight = 18.sp,
                )
                Spacer(Modifier.height(18.dp))
                Text("SERVER ADDRESS", color = secondary, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 4.sp)
                Spacer(Modifier.height(10.dp))
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(bg)
                        .border(1.dp, border, RoundedCornerShape(10.dp))
                        .padding(horizontal = 14.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f)) {
                        if (address.isEmpty()) {
                            Text("books.example.com", color = secondary.copy(alpha = 0.45f), fontSize = 18.sp)
                        }
                        BasicTextField(
                            value = address,
                            onValueChange = { address = it },
                            singleLine = true,
                            textStyle = TextStyle(color = primary, fontSize = 18.sp),
                            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                                keyboardType = KeyboardType.Uri,
                                imeAction = ImeAction.Go,
                            ),
                            keyboardActions = KeyboardActions(onGo = { submit() }),
                            cursorBrush = SolidColor(ember),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            quickConnect.error?.let {
                Spacer(Modifier.height(12.dp))
                Text(if (mono) "⚠ $it" else it, color = if (mono) primary else Color(0xFFFF453A), fontSize = 12.sp)
            }

            Spacer(Modifier.height(28.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(56.dp)
                    .clip(RoundedCornerShape(28.dp))
                    .then(
                        if (mono) {
                            Modifier
                                .background(colors.background)
                                .border(2.dp, colors.primaryText, RoundedCornerShape(28.dp))
                        } else {
                            Modifier.background(ember.copy(alpha = if (address.isNotBlank()) 1f else 0.95f))
                        }
                    )
                    .clickable(enabled = address.isNotBlank() && !quickConnect.isProbing) { submit() },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Icon(Icons.Default.Search, contentDescription = null, tint = if (mono) colors.primaryText else Color.Black.copy(alpha = 0.45f), modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(12.dp))
                Text("Connect", color = if (mono) colors.primaryText else Color.Black.copy(alpha = 0.55f), fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
            }

            Spacer(Modifier.height(34.dp))
            Text(
                "Services like Plex and Real-Debrid have their own sign-in. Set those up here.",
                color = secondary,
                fontSize = 14.sp,
                lineHeight = 18.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp),
            )
            Spacer(Modifier.height(16.dp))
            Row(
                Modifier
                    .align(Alignment.CenterHorizontally)
                    .clip(RoundedCornerShape(32.dp))
                    .background(card)
                    .border(1.dp, border, RoundedCornerShape(32.dp))
                    .clickable(onClick = onNavigateToManual)
                    .padding(horizontal = 20.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Tune, null, tint = primary, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(12.dp))
                Text("Set up manually", color = primary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}
