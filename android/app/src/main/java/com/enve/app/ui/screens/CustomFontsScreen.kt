package com.enve.app.ui.screens

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Typeface
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FileUpload
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Snackbar
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.hearth.shell.profileViewModel
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.reader.fonts.ReaderFontCategory
import com.enve.app.data.reader.fonts.ReaderFontFamily
import com.enve.app.data.repository.CustomFontRepository
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.CustomFontsViewModel
import com.enve.hearth.design.hearthDisplay

@Composable
fun CustomFontsScreen(
    onBack: () -> Unit,
    viewModel: CustomFontsViewModel = profileViewModel(),
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val fonts by viewModel.fonts.collectAsState()
    val message by viewModel.message.collectAsState()
    val selectedFontName by viewModel.selectedFontName.collectAsState()
    val query by viewModel.query.collectAsState()
    val catalog by viewModel.catalog.collectAsState()
    val previews by viewModel.previews.collectAsState()
    val busy by viewModel.busy.collectAsState()
    val context = LocalContext.current

    var pendingAdd: PendingAdd? by remember { mutableStateOf(null) }
    var renameTarget: CustomFont? by remember { mutableStateOf(null) }
    var deleteTarget: CustomFont? by remember { mutableStateOf(null) }
    var addToFamily: CustomFont? by remember { mutableStateOf(null) }
    val snackbarState = remember { SnackbarHostState() }

    LaunchedEffect(message) {
        val text = message ?: return@LaunchedEffect
        snackbarState.showSnackbar(text)
        viewModel.consumeMessage()
    }

    val pickFontLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument(),
    ) { uri: Uri? ->
        val target = pendingAdd ?: return@rememberLauncherForActivityResult
        pendingAdd = null
        if (uri != null) {
            viewModel.addVariant(target.familyId, target.displayName, target.variant, uri)
        }
    }

    SettingsScreenLayout(animatedBackground = true) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(bottom = 24.dp),
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
                    text = "Custom Fonts",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
            }

            SettingsHeroHeader(
                title = "Custom Fonts",
                subtitle = "Download free typefaces from Google Fonts or upload your own TTF or OTF files. Installed fonts work offline.",
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(999.dp))
                            .background(colors.accent)
                            .clickable {
                                addToFamily = null
                                pendingAdd = PendingAdd(null, "", CustomFontRepository.Variant.REGULAR)
                            }
                            .padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center,
                    ) {
                        Icon(
                            Icons.Default.Add,
                            contentDescription = null,
                            tint = colors.onAccent,
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(10.dp))
                        Text(
                            "Upload a font",
                            color = colors.onAccent,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.SemiBold,
                        )
                    }

                    if (fonts.isEmpty()) {
                        Text(
                            "No custom fonts yet. Upload a .ttf or .otf file and it'll appear in the reader's appearance panel.",
                            color = colors.secondaryText,
                            fontSize = 13.sp,
                        )
                    } else {
                        fonts.forEach { font ->
                            FontFamilyRow(
                                font = font,
                                inUse = font.displayName == selectedFontName,
                                onUse = { viewModel.use(font) },
                                onAddVariant = { variant ->
                                    addToFamily = font
                                    pendingAdd = PendingAdd(font.id, font.displayName, variant)
                                },
                                onRename = { renameTarget = font },
                                onDelete = { deleteTarget = font },
                                onDeleteVariant = { variant -> viewModel.deleteVariant(font.id, variant) },
                            )
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                Column(
                    modifier = Modifier.fillMaxWidth().padding(DS.Spacing.LG.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    Text(
                        "Google Fonts",
                        color = colors.primaryText,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.semantics { heading() },
                    )
                    Text(
                        "Openly licensed typefaces chosen for long reading. Nothing is downloaded until you tap Preview or Download.",
                        color = colors.secondaryText,
                        fontSize = 13.sp,
                    )
                    OutlinedTextField(
                        value = query,
                        onValueChange = viewModel::search,
                        singleLine = true,
                        placeholder = { Text("Search fonts") },
                        leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    if (catalog.isEmpty()) {
                        Text("No fonts match “${query.trim()}”.", color = colors.secondaryText, fontSize = 13.sp)
                    }
                    catalog.forEach { family ->
                        CatalogFontRow(
                            family = family,
                            preview = previews[family.name],
                            installed = fonts.any { it.displayName.equals(family.name, ignoreCase = true) },
                            busy = family.name in busy,
                            onPreview = { viewModel.preview(family) },
                            onInstall = { viewModel.install(family) },
                            onLicense = {
                                try {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(family.licenseUrl)))
                                } catch (_: ActivityNotFoundException) {
                                    viewModel.showMessage("No browser is available to open the license")
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    SnackbarHost(hostState = snackbarState) { data ->
        Snackbar(snackbarData = data)
    }

    val currentPending = pendingAdd
    if (currentPending != null && addToFamily == null && currentPending.displayName.isBlank()) {

        var nameDraft by remember(currentPending) { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { pendingAdd = null },
            title = { Text("New font") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("What should this typeface be called?", fontSize = 13.sp)
                    OutlinedTextField(
                        value = nameDraft,
                        onValueChange = { nameDraft = it },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = nameDraft.trim().isNotBlank(),
                    onClick = {
                        pendingAdd = currentPending.copy(displayName = nameDraft.trim())
                        pickFontLauncher.launch(FONT_MIME_TYPES)
                    },
                ) { Text("Choose file") }
            },
            dismissButton = {
                TextButton(onClick = { pendingAdd = null }) { Text("Cancel") }
            },
        )
    } else if (currentPending != null && addToFamily != null) {

        LaunchedEffect(currentPending) {
            pickFontLauncher.launch(FONT_MIME_TYPES)
        }
    }

    val rename = renameTarget
    if (rename != null) {
        var draft by remember(rename) { mutableStateOf(rename.displayName) }
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename font") },
            text = {
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    enabled = draft.trim().isNotBlank() && draft.trim() != rename.displayName,
                    onClick = {
                        viewModel.rename(rename.id, draft.trim())
                        renameTarget = null
                    },
                ) { Text("Rename") }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) { Text("Cancel") }
            },
        )
    }

    val del = deleteTarget
    if (del != null) {
        AlertDialog(
            onDismissRequest = { deleteTarget = null },
            title = { Text("Delete ${del.displayName}?") },
            text = { Text("Removes the font file from this device. Books currently using it will fall back to the default typeface.") },
            confirmButton = {
                TextButton(onClick = {
                    viewModel.deleteFamily(del.id)
                    deleteTarget = null
                }) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { deleteTarget = null }) { Text("Cancel") }
            },
        )
    }
}

private data class PendingAdd(
    val familyId: String?,
    val displayName: String,
    val variant: CustomFontRepository.Variant,
)

private val FONT_MIME_TYPES = arrayOf(
    "font/ttf",
    "font/otf",
    "application/x-font-ttf",
    "application/x-font-otf",
    "application/octet-stream",
)

@Composable
private fun CatalogFontRow(
    family: ReaderFontFamily,
    preview: Typeface?,
    installed: Boolean,
    busy: Boolean,
    onPreview: () -> Unit,
    onInstall: () -> Unit,
    onLicense: () -> Unit,
) {
    val colors = EnveTheme.colors
    val shape = RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 2.dp else 14.dp)
    val previewFamily = remember(preview) { preview?.let { FontFamily(it) } }
    val nameFamily = previewFamily ?: when (family.category) {
        ReaderFontCategory.SERIF -> FontFamily.Serif
        ReaderFontCategory.SANS_SERIF -> FontFamily.SansSerif
        ReaderFontCategory.MONOSPACE -> FontFamily.Monospace
    }
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.secondaryBackground)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    family.name,
                    color = colors.primaryText,
                    fontSize = 17.sp,
                    fontFamily = nameFamily,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(family.category.label, color = colors.tertiaryText, fontSize = 12.sp)
            }
            when {
                busy -> Text("Downloading…", color = colors.secondaryText, fontSize = 12.sp)
                installed -> Text("Installed", color = colors.accent, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            }
        }
        if (previewFamily != null) {
            Text(
                FONT_PREVIEW_SAMPLE,
                color = colors.primaryText,
                fontSize = 16.sp,
                fontFamily = previewFamily,
                lineHeight = 22.sp,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
            if (previewFamily == null) {
                TextButton(enabled = !busy, onClick = onPreview, modifier = Modifier.semantics {
                    contentDescription = "Preview ${family.name}"
                }) { Text("Preview", color = colors.accent, fontSize = 13.sp) }
            }
            if (!installed) {
                TextButton(enabled = !busy, onClick = onInstall, modifier = Modifier.semantics {
                    contentDescription = "Download ${family.name}"
                }) {
                    Icon(Icons.Default.Download, null, tint = colors.accent, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Download", color = colors.accent, fontSize = 13.sp)
                }
            }
            TextButton(onClick = onLicense, modifier = Modifier.semantics {
                contentDescription = "Open the ${family.name} license"
            }) { Text("License", color = colors.secondaryText, fontSize = 13.sp) }
        }
    }
}

private const val FONT_PREVIEW_SAMPLE = "The quick brown fox jumps over the lazy dog. 0123456789"

@Composable
private fun FontFamilyRow(
    font: CustomFont,
    inUse: Boolean,
    onUse: () -> Unit,
    onAddVariant: (CustomFontRepository.Variant) -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
    onDeleteVariant: (CustomFontRepository.Variant) -> Unit,
) {
    val colors = EnveTheme.colors
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(colors.secondaryBackground)
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                Icons.Default.TextFields,
                contentDescription = null,
                tint = colors.accent,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                font.displayName,
                color = colors.primaryText,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
            )
            if (inUse) {
                Text("In use", color = colors.accent, fontSize = 12.sp, fontWeight = FontWeight.Medium)
            } else {
                TextButton(onClick = onUse, modifier = Modifier.semantics {
                    contentDescription = "Use ${font.displayName} in the reader"
                }) { Text("Use", color = colors.accent, fontSize = 13.sp) }
            }
            IconButton(onClick = onRename) {
                Icon(Icons.Default.Edit, "Rename", tint = colors.secondaryText)
            }
            IconButton(onClick = onDelete) {
                Icon(Icons.Default.Delete, "Delete", tint = colors.secondaryText)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            VariantRow("Regular", font.regularPath != null, CustomFontRepository.Variant.REGULAR, onAddVariant, onDeleteVariant)
            VariantRow("Bold", font.boldPath != null, CustomFontRepository.Variant.BOLD, onAddVariant, onDeleteVariant)
            VariantRow("Italic", font.italicPath != null, CustomFontRepository.Variant.ITALIC, onAddVariant, onDeleteVariant)
            VariantRow("Bold Italic", font.boldItalicPath != null, CustomFontRepository.Variant.BOLD_ITALIC, onAddVariant, onDeleteVariant)
        }
    }
}

@Composable
private fun VariantRow(
    label: String,
    present: Boolean,
    variant: CustomFontRepository.Variant,
    onAddVariant: (CustomFontRepository.Variant) -> Unit,
    onDeleteVariant: (CustomFontRepository.Variant) -> Unit,
) {
    val colors = EnveTheme.colors
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            label,
            color = if (present) colors.primaryText else colors.tertiaryText,
            fontSize = 13.sp,
            modifier = Modifier.weight(1f),
        )
        if (present) {
            Text(
                "Installed",
                color = colors.accent,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
            )
            IconButton(onClick = { onDeleteVariant(variant) }) {
                Icon(Icons.Default.Delete, "Remove $label", tint = colors.secondaryText, modifier = Modifier.size(16.dp))
            }
        } else {
            TextButton(onClick = { onAddVariant(variant) }) {
                Icon(Icons.Default.FileUpload, null, tint = colors.accent, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Add", color = colors.accent, fontSize = 12.sp)
            }
        }
    }
}
