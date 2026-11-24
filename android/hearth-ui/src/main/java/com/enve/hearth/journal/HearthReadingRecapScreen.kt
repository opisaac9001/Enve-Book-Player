package com.enve.hearth.journal

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.shell.profileViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.UUID

@Composable
fun HearthReadingRecapScreen(
    onBack: () -> Unit,
    onSelectBook: (Book) -> Unit,
) {
    val vm: ReadingRecapViewModel = profileViewModel()
    val recap by vm.recap.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    val locale = Locale.getDefault()

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable(role = Role.Button, onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "Back",
                    tint = palette.text,
                    modifier = Modifier.size(26.dp),
                )
            }
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column(Modifier.weight(1f)) {
                Overline("Your reading life")
                Text(
                    "Recaps",
                    style = HearthText.ScreenTitle,
                    color = palette.text,
                    modifier = Modifier.semantics { heading() },
                )
            }
        }

        recap?.let { current ->
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = PaddingValues(
                    start = Hearth.Spacing.XL,
                    top = Hearth.Spacing.M,
                    end = Hearth.Spacing.XL,
                    bottom = Hearth.Spacing.XXL,
                ),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL),
            ) {
                item {
                    PeriodControls(
                        recap = current,
                        locale = locale,
                        onShowMonths = vm::showMonths,
                        onShowYears = vm::showYears,
                        onPrevious = vm::previous,
                        onNext = vm::next,
                    )
                }
                if (current.isEmpty) {
                    item { EmptyRecap(current, locale) }
                } else {
                    item { ShareableRecap(current, locale) }
                    if (current.topBooks.isNotEmpty()) {
                        item { RecapBooks("Most time with", current.topBooks, onSelectBook) }
                    }
                    if (current.topAuthor != null || current.topNarrator != null || current.pagesRead > 0) {
                        item { RecapVoices(current) }
                    }
                }
                item {
                    Text(
                        ReadingRecapFormat.historyDisclosure(current),
                        style = HearthText.Caption,
                        color = palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
private fun PeriodControls(
    recap: ReadingRecap,
    locale: Locale,
    onShowMonths: () -> Unit,
    onShowYears: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
) {
    val unit = ReadingRecapFormat.unit(recap.period)
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            HearthChip("Month", selected = recap.period is ReadingRecapPeriod.Month, onClick = onShowMonths)
            HearthChip("Year", selected = recap.period is ReadingRecapPeriod.Year, onClick = onShowYears)
        }
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            PeriodStep(Icons.AutoMirrored.Outlined.KeyboardArrowLeft, "Previous $unit", recap.canGoBack, onPrevious)
            Text(
                ReadingRecapFormat.title(recap.period, locale),
                style = hearthDisplay(24.sp, FontWeight.SemiBold),
                color = Hearth.palette.text,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .weight(1f)
                    .semantics {
                        heading()
                        liveRegion = LiveRegionMode.Polite
                    },
            )
            PeriodStep(Icons.AutoMirrored.Outlined.KeyboardArrowRight, "Next $unit", recap.canGoForward, onNext)
        }
    }
}

@Composable
private fun PeriodStep(
    icon: ImageVector,
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = label,
            tint = if (enabled) palette.text else palette.textTertiary.copy(alpha = 0.4f),
            modifier = Modifier.size(28.dp),
        )
    }
}

@Composable
private fun EmptyRecap(recap: ReadingRecap, locale: Locale) {
    val palette = Hearth.palette
    RecapSection(modifier = Modifier.semantics(mergeDescendants = true) {}) {
        Icon(Icons.Outlined.AutoStories, contentDescription = null, tint = palette.ember, modifier = Modifier.size(28.dp))
        Text(ReadingRecapFormat.emptyTitle(recap, locale), style = HearthText.BookTitle, color = palette.text)
        Text(ReadingRecapFormat.emptyBody(recap), style = HearthText.Body, color = palette.textSecondary)
    }
}

@Composable
private fun ShareableRecap(recap: ReadingRecap, locale: Locale) {
    val palette = Hearth.palette
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val layer = rememberGraphicsLayer()
    var shareFailed by remember(recap) { mutableStateOf(false) }
    val title = "Share ${ReadingRecapFormat.title(recap.period, locale)} recap"
    val text = ReadingRecapFormat.shareText(recap, locale)

    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Box(
            Modifier
                .drawWithContent {
                    layer.record { this@drawWithContent.drawContent() }
                    drawLayer(layer)
                }
                .background(palette.bg)
                .padding(Hearth.Spacing.S),
        ) {
            RecapCard(recap, locale)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            EmberButton(
                text = "Share image",
                leadingIcon = Icons.Outlined.Share,
                modifier = Modifier.weight(1f),
                onClick = {
                    scope.launch {
                        val bitmap = layer.toImageBitmap().asAndroidBitmap()
                        shareFailed = try {
                            ReadingRecapShare.image(context, bitmap, text, title)
                            false
                        } catch (_: IOException) {
                            true
                        }
                    }
                },
            )
            QuietButton(
                text = "Share text",
                modifier = Modifier.weight(1f),
                onClick = { ReadingRecapShare.text(context, text, title) },
            )
        }
        if (shareFailed) {
            Text(
                "The recap image couldn't be prepared. Try sharing it as text.",
                style = HearthText.Caption,
                color = palette.statusError,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
            )
        }
    }
}

@Composable
private fun RecapCard(recap: ReadingRecap, locale: Locale) {
    val palette = Hearth.palette
    RecapSection(
        modifier = Modifier.semantics(mergeDescendants = true) {},
        padding = Hearth.Spacing.XL,
    ) {
        Overline("My ${ReadingRecapFormat.title(recap.period, locale)}")
        Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
            Text(ReadingRecapFormat.duration(recap.totalSeconds), style = hearthDisplay(44.sp), color = palette.text)
            Text("with books", style = HearthText.Caption, color = palette.textSecondary)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            RecapMetric(ReadingRecapFormat.duration(recap.listeningSeconds), "Listening", Modifier.weight(1f))
            RecapMetric(ReadingRecapFormat.duration(recap.readingSeconds), "Reading", Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
            RecapMetric(recap.activeDays.toString(), "Active days", Modifier.weight(1f))
            RecapMetric(recap.sessions.toString(), "Sessions", Modifier.weight(1f))
        }
        recap.busiestDay?.let {
            RecapDetail("Busiest day", "${ReadingRecapFormat.day(it.date, locale)} · ${ReadingRecapFormat.duration(it.seconds)}")
        }
        recap.topBooks.firstOrNull()?.let { RecapDetail("Most time with", ReadingRecapFormat.bookTitle(it)) }
        recap.topAuthor?.let { RecapDetail("Top author", it.name) }
        Text("enve", style = HearthText.Overline, color = palette.ember)
    }
}

@Composable
private fun RecapBooks(
    title: String,
    entries: List<RecapBookEntry>,
    onSelectBook: (Book) -> Unit,
) {
    val palette = Hearth.palette
    RecapSection {
        Overline(title)
        entries.forEach { entry ->
            val book = entry.book
            Row(
                Modifier
                    .fillMaxWidth()
                    .then(
                        if (book != null) Modifier.clickable(role = Role.Button) { onSelectBook(book) } else Modifier,
                    )
                    .padding(vertical = Hearth.Spacing.XS),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                if (book != null) {
                    CoverTile(
                        model = book.coverUrl,
                        mediaType = book.mediaType,
                        modifier = Modifier.width(42.dp),
                    )
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
                    Text(
                        ReadingRecapFormat.bookTitle(entry),
                        style = HearthText.Label,
                        color = palette.text,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    book?.author?.trim()?.takeIf(String::isNotEmpty)?.let {
                        Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Text(
                    ReadingRecapFormat.duration(entry.seconds),
                    style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun RecapVoices(recap: ReadingRecap) {
    RecapSection {
        Overline("Voices and pages")
        recap.topAuthor?.let { RecapDetail("Top author", "${it.name} · ${ReadingRecapFormat.duration(it.seconds)}") }
        recap.topNarrator?.let { RecapDetail("Top narrator", "${it.name} · ${ReadingRecapFormat.duration(it.seconds)}") }
        if (recap.pagesRead > 0) RecapDetail("Pages turned", "%,d".format(recap.pagesRead))
    }
}

@Composable
private fun RecapMetric(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Text(value, style = hearthDisplay(22.sp, FontWeight.SemiBold), color = Hearth.palette.text)
        Overline(label)
    }
}

@Composable
private fun RecapDetail(label: String, value: String) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Overline(label)
        Text(value, style = HearthText.Label, color = Hearth.palette.text)
    }
}

@Composable
private fun RecapSection(
    modifier: Modifier = Modifier,
    padding: Dp = Hearth.Spacing.L,
    content: @Composable ColumnScope.() -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape: Shape = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Card)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(if (eink.active) 1.5.dp else 1.dp, if (eink.active) palette.text else palette.hairline, shape)
            .padding(padding),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        content = content,
    )
}

private object ReadingRecapShare {
    private const val DIRECTORY = "reading-recap-share"
    private const val RETAINED_IMAGES = 5

    suspend fun image(context: Context, bitmap: Bitmap, text: String, title: String) {
        val application = context.applicationContext
        val uri = withContext(Dispatchers.IO) {
            val directory = File(application.cacheDir, DIRECTORY).apply { mkdirs() }
            directory.listFiles()?.sortedByDescending { it.lastModified() }?.drop(RETAINED_IMAGES - 1)?.forEach { it.delete() }
            val file = File(directory, "${UUID.randomUUID()}.png")
            file.outputStream().use { if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) throw IOException("PNG encoding failed") }
            FileProvider.getUriForFile(application, "${application.packageName}.fileprovider", file)
        }
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            putExtra(Intent.EXTRA_TEXT, text)
            clipData = ClipData.newRawUri(title, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, title))
    }

    fun text(context: Context, text: String, title: String) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        context.startActivity(Intent.createChooser(intent, title))
    }
}
