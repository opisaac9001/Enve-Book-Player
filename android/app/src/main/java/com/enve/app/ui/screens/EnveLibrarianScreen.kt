package com.enve.app.ui.screens

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowCircleUp
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.data.librarian.BookIntelligenceScope
import com.enve.app.data.librarian.LibrarianEngineAvailability
import com.enve.app.data.librarian.LibrarianEnginePreference
import com.enve.app.data.librarian.LibrarianEngineStatus
import com.enve.app.data.librarian.LibrarianMessage
import com.enve.app.data.librarian.LibrarianMessageRole
import com.enve.app.data.librarian.RecommendedLibrarianModel
import com.enve.app.viewmodel.EnveLibrarianUiState
import com.enve.app.viewmodel.PreviousBookSummaryChoice
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI
import kotlinx.coroutines.delay

@Composable
fun EnveLibrarianScreen(
    state: EnveLibrarianUiState,
    onBack: () -> Unit,
    onScopeChange: (BookIntelligenceScope) -> Unit,
    onPrepareContext: () -> Unit,
    onRefreshContextStatus: () -> Unit,
    onRefreshEngineStatus: () -> Unit,
    onEngineChange: (LibrarianEnginePreference) -> Unit,
    onDownloadGeminiNano: () -> Unit,
    onDownloadRecommendedModel: () -> Unit,
    onCancelModelDownload: () -> Unit,
    onImportLocalModel: (Uri) -> Unit,
    onRemoveLocalModel: () -> Unit,
    onRemoteServerUrlChange: (String) -> Unit,
    onRemoteServerModelChange: (String) -> Unit,
    onRemoteServerApiKeyChange: (String) -> Unit,
    onTestRemoteServer: () -> Unit,
    onSaveRemoteServerSettings: () -> Unit,
    onSend: (String) -> Unit,
    onCatchUp: () -> Unit,
    onChoosePreviousBookSummary: () -> Unit,
    onSelectPreviousBookSummary: (PreviousBookSummaryChoice) -> Unit,
    onDismissPreviousBookChoices: () -> Unit,
    onClearConversation: () -> Unit,
    onDismissAlert: () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val listState = rememberLazyListState()
    var draft by remember { mutableStateOf("") }
    var menuExpanded by remember { mutableStateOf(false) }
    var showModelSettings by remember { mutableStateOf(false) }
    var showGeminiTerms by remember { mutableStateOf(false) }
    var showRecommendedModelTerms by remember { mutableStateOf(false) }
    val modelPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) onImportLocalModel(uri)
    }

    val canAsk = !state.isSending && !state.isPreparingContext && !state.isLoadingPreviousBookChoices
    val canSend = draft.isNotBlank() && !state.isSending && !state.isPreparingContext
    val suppressAnimations = eink.suppressAnimations

    LaunchedEffect(Unit) { onRefreshEngineStatus() }
    LaunchedEffect(state.isPreparingContext) {
        while (state.isPreparingContext) {
            onRefreshContextStatus()
            delay(500)
        }
    }
    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) {
            if (suppressAnimations) {
                listState.scrollToItem(state.messages.lastIndex)
            } else {
                listState.animateScrollToItem(state.messages.lastIndex)
            }
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(palette.bgElevated)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        LibrarianHeader(
            title = state.book?.title.orEmpty(),
            onOpenModelSettings = { showModelSettings = true },
            onAskPreviousBook = onChoosePreviousBookSummary,
            onClearConversation = onClearConversation,
            onBack = onBack,
            menuExpanded = menuExpanded,
            onMenuExpandedChange = { menuExpanded = it },
        )

        LibrarianStatusPanel(state, onPrepareContext)

        Column(
            Modifier.padding(bottom = 10.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                BookIntelligenceScope.entries.forEach { scope ->
                    LibrarianChip(
                        label = scope.title,
                        selected = state.selectedScope == scope,
                        onClick = { onScopeChange(scope) },
                    )
                }
            }
            Text(
                "The Librarian reads only up to where you are.",
                style = hearthUI(11.sp),
                color = palette.textTertiary,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
        }

        Row(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 24.dp)
                .padding(bottom = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LibrarianChip("Catch me up", selected = false, onClick = onCatchUp, enabled = canAsk)
            listOf("Who was involved?", "Important details", "Open threads").forEach { prompt ->
                LibrarianChip(prompt, selected = false, onClick = { onSend(prompt) }, enabled = canAsk)
            }
        }

        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(start = 24.dp, end = 24.dp, bottom = 16.dp),
        ) {
            if (state.messages.isEmpty()) {
                item { LibrarianEmptyState() }
            }
            items(state.messages, key = { it.id }) { message ->
                LibrarianMessageRow(message)
            }
            if (state.isSending) {
                item {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        if (!eink.active) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                                color = palette.ember,
                            )
                        }
                        Text(
                            state.sendStatusText ?: "Thinking",
                            style = hearthUI(12.sp),
                            color = palette.textTertiary,
                        )
                    }
                }
            }
        }

        LibrarianComposer(
            draft = draft,
            fieldEnabled = !state.isSending && !state.isPreparingContext,
            canSend = canSend,
            onDraftChange = { draft = it },
            onSend = {
                val text = draft
                draft = ""
                onSend(text)
            },
        )
    }

    val alert = state.alertMessage
    if (alert != null) {
        AlertDialog(
            onDismissRequest = onDismissAlert,
            confirmButton = {
                TextButton(onClick = onDismissAlert) { Text("All right", color = palette.ember) }
            },
            title = { Text("The Librarian", style = hearthDisplay(18.sp, FontWeight.SemiBold), color = palette.text) },
            text = { Text(alert, style = hearthUI(14.sp), color = palette.textSecondary) },
            containerColor = palette.bgElevated,
            shape = librarianDialogShape(),
        )
    }

    if (showModelSettings) {
        val dismissModelSettings = {
            onSaveRemoteServerSettings()
            showModelSettings = false
        }
        AlertDialog(
            onDismissRequest = dismissModelSettings,
            confirmButton = {
                TextButton(onClick = dismissModelSettings) { Text("Done", color = palette.ember) }
            },
            title = { Text("Model settings", style = hearthDisplay(18.sp, FontWeight.SemiBold), color = palette.text) },
            text = {
                LibrarianEnginePanel(
                    selected = state.selectedEngine,
                    statuses = state.engineStatuses,
                    recommendedModel = state.recommendedModel,
                    busy = state.isDownloadingGemini || state.isDownloadingRecommendedModel || state.isImportingModel || state.isRemovingModel,
                    modelDownloadProgress = state.recommendedModelDownloadProgress,
                    remoteServerUrl = state.remoteServerUrl,
                    remoteServerModel = state.remoteServerModel,
                    remoteServerApiKey = state.remoteServerApiKey,
                    remoteServerHasStoredKey = state.remoteServerHasStoredKey,
                    remoteServerModels = state.remoteServerModels,
                    isTestingRemoteServer = state.isTestingRemoteServer,
                    onRemoteServerUrlChange = onRemoteServerUrlChange,
                    onRemoteServerModelChange = onRemoteServerModelChange,
                    onRemoteServerApiKeyChange = onRemoteServerApiKeyChange,
                    onTestRemoteServer = onTestRemoteServer,
                    onEngineChange = onEngineChange,
                    onDownloadGeminiNano = { showGeminiTerms = true },
                    onDownloadRecommendedModel = { showRecommendedModelTerms = true },
                    onCancelModelDownload = onCancelModelDownload,
                    onImportLocalModel = {
                        modelPicker.launch(arrayOf("application/octet-stream", "application/x-litertlm", "*/*"))
                    },
                    onRemoveLocalModel = onRemoveLocalModel,
                )
            },
            containerColor = palette.bgElevated,
            shape = librarianDialogShape(),
        )
    }

    if (showGeminiTerms) {
        AlertDialog(
            onDismissRequest = { showGeminiTerms = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        showGeminiTerms = false
                        onDownloadGeminiNano()
                    },
                ) {
                    Text("Download", color = palette.ember)
                }
            },
            dismissButton = {
                TextButton(onClick = { showGeminiTerms = false }) {
                    Text("Cancel", color = palette.textSecondary)
                }
            },
            title = { Text("Download Gemini Nano?", style = hearthDisplay(18.sp, FontWeight.SemiBold), color = palette.text) },
            text = {
                Text(
                    "Gemini Nano is downloaded and managed on-device by Google ML Kit. Google Play services may check for model updates and send performance or utilization information under Google's terms. Enve does not receive that telemetry. See the Privacy Policy and About → Open-source licenses for details.",
                    style = hearthUI(14.sp),
                    color = palette.textSecondary,
                )
            },
            containerColor = palette.bgElevated,
            shape = librarianDialogShape(),
        )
    }

    if (showRecommendedModelTerms) {
        AlertDialog(
            onDismissRequest = { showRecommendedModelTerms = false },
            confirmButton = {
                TextButton(
                    onClick = {
                        showRecommendedModelTerms = false
                        onDownloadRecommendedModel()
                    },
                ) {
                    Text("Download", color = palette.ember)
                }
            },
            dismissButton = {
                TextButton(onClick = { showRecommendedModelTerms = false }) {
                    Text("Cancel", color = palette.textSecondary)
                }
            },
            title = { Text("Download Qwen3 0.6B?", style = hearthDisplay(18.sp, FontWeight.SemiBold), color = palette.text) },
            text = {
                Text(
                    "This 586 MB on-device model is provided by the LiteRT community and Qwen under the Apache 2.0 license. " +
                        "Enve verifies its exact revision and SHA-256 digest before installing it. The full license is available in About → Open-source licenses.",
                    style = hearthUI(14.sp),
                    color = palette.textSecondary,
                )
            },
            containerColor = palette.bgElevated,
            shape = librarianDialogShape(),
        )
    }

    if (state.previousBookChoices.isNotEmpty()) {
        AlertDialog(
            onDismissRequest = onDismissPreviousBookChoices,
            confirmButton = {
                TextButton(onClick = onDismissPreviousBookChoices) { Text("Cancel", color = palette.ember) }
            },
            title = { Text("A previous book", style = hearthDisplay(18.sp, FontWeight.SemiBold), color = palette.text) },
            text = {
                PreviousBookPicker(
                    choices = state.previousBookChoices,
                    onSelect = onSelectPreviousBookSummary,
                )
            },
            containerColor = palette.bgElevated,
            shape = librarianDialogShape(),
        )
    }
}

@Composable
private fun librarianDialogShape(): Shape =
    if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Card)

@Composable
private fun LibrarianHeader(
    title: String,
    onOpenModelSettings: () -> Unit,
    onAskPreviousBook: () -> Unit,
    onClearConversation: () -> Unit,
    onBack: () -> Unit,
    menuExpanded: Boolean,
    onMenuExpandedChange: (Boolean) -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .padding(top = 24.dp, bottom = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        CoverTile(model = null, modifier = Modifier.width(46.dp))
        Column(
            Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Overline("The Librarian", color = palette.ember)
            Text(
                title,
                style = hearthDisplay(17.sp, FontWeight.SemiBold),
                color = palette.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Box {
            val shape = if (eink.sharpCorners) RectangleShape else CircleShape
            Box(
                Modifier
                    .size(44.dp)
                    .clip(shape)
                    .background(palette.bg)
                    .border(1.dp, palette.hairline, shape)
                    .clickable { onMenuExpandedChange(true) },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.MoreHoriz,
                    contentDescription = "Conversation options",
                    tint = palette.text,
                    modifier = Modifier.size(20.dp),
                )
            }
            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { onMenuExpandedChange(false) },
                containerColor = palette.bgElevated,
            ) {
                DropdownMenuItem(
                    text = { Text("Model settings", style = HearthText.Label, color = palette.text) },
                    onClick = {
                        onMenuExpandedChange(false)
                        onOpenModelSettings()
                    },
                )
                DropdownMenuItem(
                    text = { Text("Ask about a previous book", style = HearthText.Label, color = palette.text) },
                    onClick = {
                        onMenuExpandedChange(false)
                        onAskPreviousBook()
                    },
                )
                DropdownMenuItem(
                    text = { Text("Clear the conversation", style = HearthText.Label, color = palette.statusError) },
                    onClick = {
                        onMenuExpandedChange(false)
                        onClearConversation()
                    },
                )
            }
        }
        Icon(
            Icons.Default.Close,
            contentDescription = "Close the Librarian",
            tint = palette.textSecondary,
            modifier = Modifier
                .clip(if (eink.sharpCorners) RectangleShape else CircleShape)
                .clickable(onClick = onBack)
                .padding(8.dp)
                .size(24.dp),
        )
    }
}

@Composable
private fun LibrarianStatusPanel(
    state: EnveLibrarianUiState,
    onPrepareContext: () -> Unit,
) {
    val palette = Hearth.palette
    if (state.isPreparingContext) {
        LibrarianCard(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 12.dp)) {
            Text(
                state.contextStatusText ?: "Reading the book's text",
                style = hearthUI(13.sp, FontWeight.Medium),
                color = palette.textSecondary,
            )
            Spacer(Modifier.height(10.dp))
            LinearProgressIndicator(
                progress = { state.contextProgress.toFloat().coerceIn(0f, 1f) },
                color = palette.ember,
                trackColor = palette.hairline,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    } else if (state.contextStatusText != null) {
        LibrarianCard(Modifier.padding(start = 24.dp, end = 24.dp, bottom = 12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Icon(
                    Icons.Default.AutoStories,
                    contentDescription = null,
                    tint = palette.ember,
                    modifier = Modifier.size(18.dp),
                )
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        "The book's text is needed first",
                        style = hearthUI(14.sp, FontWeight.SemiBold),
                        color = palette.text,
                    )
                    Text(
                        state.contextStatusText,
                        style = hearthUI(12.sp),
                        color = palette.textSecondary,
                    )
                }
            }
            Spacer(Modifier.height(12.dp))
            QuietButton("Prepare the book's text", onClick = onPrepareContext)
        }
    }
}

@Composable
private fun LibrarianCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(14.dp)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bg)
            .border(1.dp, palette.hairline, shape)
            .padding(16.dp),
        content = content,
    )
}

@Composable
private fun LibrarianChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    enabled: Boolean = true,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(50)
    val bg = if (selected && !eink.active) palette.ember else palette.bg
    val border = when {
        selected && eink.active -> BorderStroke(2.dp, palette.ember)
        selected -> null
        else -> BorderStroke(1.dp, palette.hairline)
    }
    val fg = when {
        selected && eink.active -> palette.ember
        selected -> palette.readableOnEmber
        else -> palette.textSecondary
    }
    Row(
        Modifier
            .alpha(if (enabled || eink.active) 1f else 0.4f)
            .clip(shape)
            .background(bg)
            .then(if (border != null) Modifier.border(border, shape) else Modifier)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = HearthText.Caption.copy(fontWeight = FontWeight.Medium), color = fg)
    }
}

@Composable
private fun LibrarianEmptyState() {
    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxWidth()
            .padding(top = 40.dp, start = 12.dp, end = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            Icons.Default.AutoStories,
            contentDescription = null,
            tint = palette.textTertiary,
            modifier = Modifier.size(28.dp),
        )
        Text(
            "Ask about the story so far.",
            style = hearthDisplay(19.sp),
            color = palette.textSecondary,
            textAlign = TextAlign.Center,
        )
        Text(
            "Answers come from this book's local text, kept short of anywhere you haven't read.",
            style = hearthUI(12.sp),
            color = palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun LibrarianMessageRow(message: LibrarianMessage) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val isUser = message.role == LibrarianMessageRole.USER
    val shape = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(16.dp)

    Box(
        Modifier
            .fillMaxWidth()
            .padding(start = if (isUser) 48.dp else 0.dp, end = if (isUser) 0.dp else 48.dp),
        contentAlignment = if (isUser) Alignment.CenterEnd else Alignment.CenterStart,
    ) {
        val bubble = when {
            isUser && eink.active -> Modifier
                .clip(shape)
                .background(palette.bg)
                .border(1.5.dp, palette.text, shape)
            isUser -> Modifier
                .clip(shape)
                .background(palette.ember)
            else -> Modifier
                .clip(shape)
                .background(palette.bg)
                .border(1.dp, palette.hairline, shape)
        }
        Column(
            bubble.padding(horizontal = 14.dp, vertical = 11.dp),
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            if (!isUser) {
                val meta = listOfNotNull(message.scope?.title, message.engineTitle).joinToString(" · ")
                if (meta.isNotBlank()) Overline(meta)
            }
            Text(
                message.text,
                style = if (isUser) hearthUI(15.sp) else hearthDisplay(15.sp, FontWeight.Normal),
                color = when {
                    isUser && eink.active -> palette.text
                    isUser -> palette.readableOnEmber
                    else -> palette.text
                },
                lineHeight = if (isUser) 20.sp else 21.sp,
            )
        }
    }
}

@Composable
private fun LibrarianComposer(
    draft: String,
    fieldEnabled: Boolean,
    canSend: Boolean,
    onDraftChange: (String) -> Unit,
    onSend: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(14.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp)
            .padding(top = 8.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                Modifier
                    .weight(1f)
                    .clip(shape)
                    .background(palette.bg)
                    .border(1.dp, palette.hairline, shape)
                    .padding(horizontal = 14.dp, vertical = 11.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                if (draft.isEmpty()) {
                    Text("Ask the Librarian", style = hearthUI(15.sp), color = palette.textTertiary)
                }
                BasicTextField(
                    value = draft,
                    onValueChange = onDraftChange,
                    enabled = fieldEnabled,
                    maxLines = 4,
                    textStyle = hearthUI(15.sp).copy(color = palette.text),
                    cursorBrush = SolidColor(palette.ember),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Box(
                Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(enabled = canSend, onClick = onSend),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.ArrowCircleUp,
                    contentDescription = "Send question",
                    tint = if (canSend) palette.ember else palette.textTertiary,
                    modifier = Modifier.size(30.dp),
                )
            }
        }
        Text(
            "The book's text and this conversation stay on this device.",
            style = hearthUI(11.sp),
            color = palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun LibrarianEnginePanel(
    selected: LibrarianEnginePreference,
    statuses: List<LibrarianEngineStatus>,
    recommendedModel: RecommendedLibrarianModel?,
    busy: Boolean,
    modelDownloadProgress: Double?,
    remoteServerUrl: String,
    remoteServerModel: String,
    remoteServerApiKey: String,
    remoteServerHasStoredKey: Boolean,
    remoteServerModels: List<String>,
    isTestingRemoteServer: Boolean,
    onRemoteServerUrlChange: (String) -> Unit,
    onRemoteServerModelChange: (String) -> Unit,
    onRemoteServerApiKeyChange: (String) -> Unit,
    onTestRemoteServer: () -> Unit,
    onEngineChange: (LibrarianEnginePreference) -> Unit,
    onDownloadGeminiNano: () -> Unit,
    onDownloadRecommendedModel: () -> Unit,
    onCancelModelDownload: () -> Unit,
    onImportLocalModel: () -> Unit,
    onRemoveLocalModel: () -> Unit,
) {
    val palette = Hearth.palette
    val statusByPreference = statuses.associateBy { it.preference }
    val selectedStatus = statusByPreference[selected]
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("On-device engine", style = hearthUI(14.sp, FontWeight.SemiBold), color = palette.text)
                Text(
                    selectedStatus?.detail ?: "Checking availability",
                    style = hearthUI(12.sp),
                    color = palette.textSecondary,
                )
            }
            if (busy && !Hearth.eink.active) {
                CircularProgressIndicator(
                    modifier = Modifier.size(16.dp),
                    strokeWidth = 2.dp,
                    color = palette.ember,
                )
            }
        }
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LibrarianEnginePreference.entries.forEach { preference ->
                val status = statusByPreference[preference]
                LibrarianChip(
                    label = status?.title ?: preference.title,
                    selected = selected == preference,
                    onClick = { onEngineChange(preference) },
                    enabled = !busy,
                )
            }
        }
        val geminiStatus = statusByPreference[LibrarianEnginePreference.GEMINI_NANO]
        val liteRtStatus = statusByPreference[LibrarianEnginePreference.LITERT_LM]
        if (selected == LibrarianEnginePreference.REMOTE_SERVER) {
            LibrarianSettingsField(
                value = remoteServerUrl,
                onValueChange = onRemoteServerUrlChange,
                placeholder = "Server URL, e.g. 192.168.1.10:11434",
            )
            LibrarianSettingsField(
                value = remoteServerModel,
                onValueChange = onRemoteServerModelChange,
                placeholder = "Model id (use Test connection to list)",
            )
            LibrarianSettingsField(
                value = remoteServerApiKey,
                onValueChange = onRemoteServerApiKeyChange,
                placeholder = if (remoteServerHasStoredKey) "API key saved. Type to replace" else "API key (optional)",
                masked = true,
            )
            if (remoteServerModels.isNotEmpty()) {
                FlowRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    remoteServerModels.forEach { model ->
                        LibrarianChip(
                            label = model,
                            selected = model == remoteServerModel,
                            onClick = { onRemoteServerModelChange(model) },
                            enabled = !busy,
                        )
                    }
                }
            }
            LibrarianDialogButton(
                if (isTestingRemoteServer) "Testing connection…" else "Test connection",
                enabled = !isTestingRemoteServer,
                onClick = onTestRemoteServer,
            )
            Text(
                "Works with Ollama, LM Studio, llama.cpp, and any OpenAI-compatible server on your network.",
                style = hearthUI(11.sp),
                color = palette.textSecondary,
            )
        }
        if (modelDownloadProgress != null) {
            LinearProgressIndicator(
                progress = { modelDownloadProgress.toFloat().coerceIn(0f, 1f) },
                color = palette.ember,
                trackColor = palette.hairline,
                modifier = Modifier.fillMaxWidth(),
            )
            LibrarianDialogButton("Cancel download", enabled = true, onClick = onCancelModelDownload)
        }
        if (geminiStatus?.availability == LibrarianEngineAvailability.DOWNLOADABLE) {
            LibrarianDialogButton("Download Gemini Nano", enabled = !busy, onClick = onDownloadGeminiNano)
        }
        if (selected == LibrarianEnginePreference.LITERT_LM ||
            liteRtStatus?.availability == LibrarianEngineAvailability.MODEL_MISSING
        ) {
            if (liteRtStatus?.availability == LibrarianEngineAvailability.MODEL_MISSING && recommendedModel != null) {
                LibrarianDialogButton("Download ${recommendedModel.title}", enabled = !busy, onClick = onDownloadRecommendedModel)
                Text(recommendedModel.detail, style = hearthUI(11.sp), color = palette.textSecondary)
            }
            if (liteRtStatus?.availability == LibrarianEngineAvailability.AVAILABLE) {
                LibrarianDialogButton("Remove the local model", enabled = !busy, onClick = onRemoveLocalModel)
            }
            LibrarianDialogButton(
                if (liteRtStatus?.availability == LibrarianEngineAvailability.AVAILABLE) "Replace the local model" else "Import a local model",
                enabled = !busy,
                onClick = onImportLocalModel,
            )
        }
    }
}

@Composable
private fun LibrarianSettingsField(
    value: String,
    onValueChange: (String) -> Unit,
    placeholder: String,
    masked: Boolean = false,
) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Inner)
    Box(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bg)
            .border(1.dp, palette.hairline, shape)
            .padding(horizontal = 14.dp, vertical = 11.dp),
        contentAlignment = Alignment.CenterStart,
    ) {
        if (value.isEmpty()) {
            Text(placeholder, style = hearthUI(13.sp), color = palette.textTertiary)
        }
        BasicTextField(
            value = value,
            onValueChange = onValueChange,
            singleLine = true,
            textStyle = hearthUI(13.sp).copy(color = palette.text),
            cursorBrush = SolidColor(palette.ember),
            visualTransformation = if (masked) PasswordVisualTransformation() else VisualTransformation.None,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun LibrarianDialogButton(text: String, enabled: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        Modifier
            .fillMaxWidth()
            .alpha(if (enabled || eink.active) 1f else 0.4f)
            .clip(shape)
            .background(palette.bg)
            .border(1.dp, palette.hairline, shape)
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = HearthText.Label, color = palette.text)
    }
}

@Composable
private fun PreviousBookPicker(
    choices: List<PreviousBookSummaryChoice>,
    onSelect: (PreviousBookSummaryChoice) -> Unit,
) {
    val palette = Hearth.palette
    val shape = if (Hearth.eink.sharpCorners) RectangleShape else RoundedCornerShape(14.dp)
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            "Choose the earlier book the Librarian should summarize from its local text.",
            style = hearthUI(12.sp),
            color = palette.textSecondary,
        )
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(max = 320.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(choices, key = { it.book.stableId }) { choice ->
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(shape)
                        .background(palette.bg)
                        .border(1.dp, palette.hairline, shape)
                        .clickable { onSelect(choice) }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            choice.title,
                            modifier = Modifier.weight(1f),
                            style = hearthUI(14.sp, FontWeight.SemiBold),
                            color = palette.text,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (choice.isSuggested) {
                            Overline("Suggested", color = palette.ember)
                        }
                    }
                    val detail = listOfNotNull(
                        choice.seriesNumber?.takeIf { it.isNotBlank() }?.let { "#$it" },
                        choice.author?.takeIf { it.isNotBlank() },
                    ).joinToString(" · ")
                    if (detail.isNotBlank()) {
                        Text(
                            detail,
                            style = hearthUI(12.sp),
                            color = palette.textSecondary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}
