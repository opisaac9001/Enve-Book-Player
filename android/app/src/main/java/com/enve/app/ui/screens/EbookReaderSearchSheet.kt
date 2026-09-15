package com.enve.app.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CheckboxDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.ReaderSearchResult

@Composable
internal fun ReaderSearchSheet(
    query: String,
    results: List<ReaderSearchResult>,
    loading: Boolean,
    error: String?,
    status: String?,
    wholeWords: Boolean,
    optionsAvailable: Boolean,
    hasMore: Boolean,
    colors: ChromeColors,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onWholeWordsChange: (Boolean) -> Unit,
    onCancel: () -> Unit,
    onLoadMore: () -> Unit,
    onResultClick: (ReaderSearchResult) -> Unit,
    onClose: () -> Unit,
) {
    val metrics = rememberAdaptiveMetrics()
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .imePadding()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Search Book",
                color = colors.primaryText,
                fontSize = DS.FontSize.Headline.scaled(metrics),
                fontWeight = FontWeight.Bold,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = onClose) {
                Icon(Icons.Default.Close, "Close", tint = colors.secondaryText)
            }
        }

        OutlinedTextField(
            value = query,
            onValueChange = onQueryChange,
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            leadingIcon = { Icon(Icons.Default.Search, null, tint = colors.secondaryText) },
            trailingIcon = {
                IconButton(onClick = if (loading) onCancel else onSearch) {
                    if (loading) {
                        Icon(Icons.Default.Close, "Cancel search", tint = colors.accentText)
                    } else {
                        Icon(Icons.Default.Search, "Search", tint = colors.accentText)
                    }
                }
            },
            placeholder = { Text("Search text", color = colors.secondaryText) },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { onSearch() }),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = colors.accentText,
                unfocusedBorderColor = colors.divider,
                focusedTextColor = colors.primaryText,
                unfocusedTextColor = colors.primaryText,
                cursorColor = colors.accentText,
            ),
        )

        if (optionsAvailable) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(
                    checked = wholeWords,
                    onCheckedChange = onWholeWordsChange,
                    colors = CheckboxDefaults.colors(checkedColor = colors.accentText, uncheckedColor = colors.secondaryText),
                )
                Text(
                    "Whole words",
                    color = colors.primaryText,
                    modifier = Modifier.clickable { onWholeWordsChange(!wholeWords) },
                )
            }
            Text(
                if (wholeWords) "Word or exact phrase. Matching headings appear first."
                else "Includes partial words. Searches cached text; large books may take longer.",
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
        if (status != null) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (loading) {
                    CircularProgressIndicator(color = colors.accentText, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                }
                Text(status, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
            }
        }
        if (error != null) {
            Text(error, color = colors.secondaryText)
        }
        if (results.isNotEmpty()) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 500.dp),
            ) {
                items(results, key = { it.id }) { result ->
                    SearchResultRow(result = result, colors = colors, onClick = { onResultClick(result) })
                    HorizontalDivider(color = colors.divider)
                }
                if (hasMore) {
                    item {
                        TextButton(onClick = onLoadMore, enabled = !loading, modifier = Modifier.fillMaxWidth()) {
                            Text("Load more results", color = colors.accentText)
                        }
                    }
                }
            }
        } else if (!loading && error == null) {
            SearchEmptyText("Enter a word or phrase to search this book.", colors)
        }
    }
}

@Composable
private fun SearchResultRow(
    result: ReaderSearchResult,
    colors: ChromeColors,
    onClick: () -> Unit,
) {
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = "${result.progressPct}%",
            color = colors.accentText,
            fontSize = DS.FontSize.Caption.scaled(metrics),
            fontWeight = FontWeight.Bold,
            modifier = Modifier.width(42.dp.scaled(metrics)),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = result.title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Subheadline.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = buildAnnotatedString {
                    append(result.contextBefore)
                    if (result.contextBefore.isNotBlank() && result.matchText.isNotBlank()) append(" ")
                    withStyle(
                        SpanStyle(
                            color = colors.accentText,
                            fontWeight = FontWeight.SemiBold,
                            background = colors.accentText.copy(alpha = 0.14f),
                        ),
                    ) {
                        append(result.matchText)
                    }
                    if (result.matchText.isNotBlank() && result.contextAfter.isNotBlank()) append(" ")
                    append(result.contextAfter)
                },
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 2.dp),
            )
        }
    }
}

@Composable
private fun SearchEmptyText(text: String, colors: ChromeColors) {
    val metrics = rememberAdaptiveMetrics()
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 120.dp.scaled(metrics))
            .padding(DS.Spacing.XXL.scaled(metrics)),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = colors.secondaryText, fontSize = DS.FontSize.Subheadline.scaled(metrics), textAlign = TextAlign.Center)
    }
}
