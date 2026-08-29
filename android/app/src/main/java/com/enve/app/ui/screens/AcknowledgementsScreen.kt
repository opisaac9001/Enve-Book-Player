package com.enve.app.ui.screens

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Description
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.enve.app.R
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import org.json.JSONObject

private data class LegalDocument(
    val title: String,
    val subtitle: String,
    val assetPath: String,
)

private data class DependencyNotice(
    val id: String,
    val name: String,
    val version: String,
    val licenses: String,
    val website: String?,
)

private val legalDocuments = listOf(
    LegalDocument("Third-party notices", "Bundled components, SDKs, models, and trademarks", "licenses/THIRD_PARTY_NOTICES.txt"),
    LegalDocument("Enve license", "License for Enve-owned source", "licenses/enve-LICENSE.txt"),
    LegalDocument("Enve notice", "Copyright and source provenance", "licenses/enve-NOTICE.txt"),
    LegalDocument("libmobi", "LGPL-3.0-or-later and exact source provenance", "licenses/libmobi-LGPL-3.0.txt"),
    LegalDocument("libmobi source provenance", "Exact upstream revision and Android integration changes", "licenses/libmobi-PROVENANCE.txt"),
    LegalDocument("jcifs-ng", "LGPL-2.1-or-later and corresponding source", "licenses/jcifs-ng-LGPL-2.1.txt"),
    LegalDocument("jcifs-ng source provenance", "Exact release, source archive, and artifact digests", "licenses/jcifs-ng-UPSTREAM.txt"),
    LegalDocument("whisper.cpp", "MIT license and exact source provenance", "licenses/whisper-MIT.txt"),
    LegalDocument("whisper.cpp source provenance", "Exact upstream tag and verified vendored file set", "licenses/whisper-PROVENANCE.txt"),
    LegalDocument("Downloadable models", "Pinned revisions, digests, sizes, and licenses", "licenses/downloadable-models-UPSTREAM.txt"),
    LegalDocument("Qwen3 0.6B", "Apache-2.0 model license", "licenses/Qwen3-0.6B-LICENSE.txt"),
    LegalDocument("Provider logos", "Reviewed asset provenance and digests", "licenses/provider-logos-PROVENANCE.txt"),
    LegalDocument("Foliate JS", "MIT license", "licenses/foliate-LICENSE.txt"),
    LegalDocument("zip.js", "BSD-3-Clause license", "licenses/zip.js-LICENSE.txt"),
    LegalDocument("PDF.js", "Apache-2.0 license", "licenses/pdf.js-Apache-2.0.txt"),
    LegalDocument("PDF.js CMaps", "Adobe BSD-style license", "licenses/pdf.js-CMaps-BSD.txt"),
    LegalDocument("PDF.js Foxit fonts", "PDFium BSD-style license", "licenses/pdf.js-Foxit-fonts-BSD.txt"),
    LegalDocument("PDF.js Liberation fonts", "SIL Open Font License 1.1", "licenses/pdf.js-Liberation-fonts-OFL-1.1.txt"),
    LegalDocument("Grimmory assets", "Asset and trademark terms", "licenses/grimmory-ASSET-LICENSE.txt"),
    LegalDocument("Grimmory trademarks", "Brand usage terms", "licenses/grimmory-TRADEMARKS.txt"),
)

@Composable
fun AcknowledgementsScreen(
    dynamicBackgroundEnabled: Boolean,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dependencies = remember(resources) {
        runCatching {
            resources.openRawResource(R.raw.aboutlibraries)
                .bufferedReader()
                .use { parseDependencies(it.readText()) }
        }.getOrDefault(emptyList())
    }
    var selectedDocument by remember { mutableStateOf<LegalDocument?>(null) }

    selectedDocument?.let { document ->
        val content = remember(document.assetPath) {
            runCatching {
                context.assets.open(document.assetPath).bufferedReader().use { it.readText() }
            }.getOrElse { "This notice could not be loaded." }
        }
        AlertDialog(
            onDismissRequest = { selectedDocument = null },
            title = { Text(document.title) },
            text = {
                Box(
                    Modifier
                        .heightIn(max = 520.dp)
                        .verticalScroll(rememberScrollState()),
                ) {
                    Text(content, fontSize = 12.sp, color = colors.primaryText)
                }
            },
            confirmButton = {
                TextButton(onClick = { selectedDocument = null }) { Text("Close") }
            },
        )
    }

    SettingsScreenLayout(animatedBackground = dynamicBackgroundEnabled) {
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .navigationBarsPadding(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = DS.Spacing.LG.scaled(metrics),
                top = DS.Spacing.LG.scaled(metrics),
                end = DS.Spacing.LG.scaled(metrics),
                bottom = 80.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ScreenBackButton(onClick = onBack)
                    Text(
                        "Open-source licenses",
                        modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                        color = colors.primaryText,
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
            item {
                Text(
                    "Enve includes open-source software and offers optional model downloads. " +
                        "The notices below are generated and packaged with this build.",
                    color = colors.secondaryText,
                    fontSize = 14.sp,
                    lineHeight = 20.sp,
                )
            }
            item {
                Text("Bundled notices", color = colors.secondaryText, fontSize = 13.sp, fontWeight = FontWeight.Bold)
            }
            items(legalDocuments, key = LegalDocument::assetPath) { document ->
                SettingsCard {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { selectedDocument = document }
                            .padding(DS.Spacing.LG.scaled(metrics)),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.Description, null, tint = colors.accent)
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .padding(horizontal = DS.Spacing.MD.scaled(metrics)),
                        ) {
                            Text(document.title, color = colors.primaryText, fontWeight = FontWeight.SemiBold)
                            Text(document.subtitle, color = colors.secondaryText, fontSize = 12.sp)
                        }
                        Icon(Icons.Default.ChevronRight, null, tint = colors.secondaryText)
                    }
                }
            }
            item {
                Text(
                    "Resolved release dependencies (${dependencies.size})",
                    color = colors.secondaryText,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(top = DS.Spacing.SM.scaled(metrics)),
                )
            }
            if (dependencies.isEmpty()) {
                item {
                    Text("The dependency inventory could not be loaded.", color = colors.secondaryText)
                }
            } else {
                items(dependencies, key = DependencyNotice::id) { dependency ->
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable(enabled = dependency.website != null) {
                                dependency.website?.let { website ->
                                    runCatching {
                                        context.startActivity(Intent(Intent.ACTION_VIEW, website.toUri()))
                                    }
                                }
                            }
                            .padding(vertical = DS.Spacing.SM.scaled(metrics)),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                dependency.name,
                                modifier = Modifier.weight(1f),
                                color = colors.primaryText,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(dependency.version, color = colors.secondaryText, fontSize = 12.sp)
                        }
                        Spacer(Modifier.height(2.dp))
                        Text(dependency.licenses, color = colors.secondaryText, fontSize = 12.sp)
                        HorizontalDivider(
                            modifier = Modifier.padding(top = DS.Spacing.SM.scaled(metrics)),
                            color = colors.separator.copy(alpha = 0.5f),
                        )
                    }
                }
            }
        }
    }
}

private fun parseDependencies(json: String): List<DependencyNotice> {
    val root = JSONObject(json)
    val libraries = root.getJSONArray("libraries")
    val licenseDefinitions = root.optJSONObject("licenses")
    val notices = ArrayList<DependencyNotice>(libraries.length())
    for (index in 0 until libraries.length()) {
        val library = libraries.getJSONObject(index)
        val licenseArray = library.optJSONArray("licenses")
        val licenses = buildList {
            if (licenseArray != null) {
                for (licenseIndex in 0 until licenseArray.length()) {
                    val licenseId = licenseArray.getString(licenseIndex)
                    add(licenseDefinitions?.optJSONObject(licenseId)?.optString("name").orEmpty().ifBlank { licenseId })
                }
            }
        }.joinToString().ifBlank { "License not declared by artifact" }
        notices += DependencyNotice(
            id = library.getString("uniqueId"),
            name = library.optString("name").ifBlank { library.optString("uniqueId") },
            version = library.optString("artifactVersion"),
            licenses = licenses,
            website = library.optString("website").takeIf(String::isNotBlank),
        )
    }
    return notices.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER, DependencyNotice::name))
}
