package com.enve.app.widgets

import android.content.Context
import android.content.Intent
import androidx.annotation.DrawableRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.Action
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionSendBroadcast
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.enve.app.MainActivity
import com.enve.app.R
import com.enve.core.data.model.AppMediaType

private val bg = ColorProvider(Color(0xFF191512))
private val surface = ColorProvider(Color(0xFF302821))
private val text = ColorProvider(Color(0xFFF3EBDD))
private val secondary = ColorProvider(Color(0xFFB9AA98))
private val ember = ColorProvider(Color(0xFFF5921A))

class BookPlayerWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        provideContent {
            val snapshot by remember {
                widgetSnapshots(context, BookWidgetStore.PREFS) { BookWidgetStore.load(context) }
            }.collectAsState(BookWidgetStore.load(context))
            val size = LocalSize.current
            when {
                snapshot.book == null -> Empty()
                size.width < 220.dp -> Compact(context, snapshot, size)
                size.width >= size.height * 1.5f -> Wide(context, snapshot, size)
                else -> Large(context, snapshot, size)
            }
        }
    }

    @Composable
    private fun Empty() {
        val small = LocalSize.current.height < 150.dp || LocalSize.current.width < 150.dp
        Column(
            GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).padding(16.dp)
                .clickable(actionStartActivity<MainActivity>()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (!small) {
                Text("YOUR HEARTH", style = TextStyle(ember, 10.sp, FontWeight.Bold))
                Spacer(GlanceModifier.height(10.dp))
            }
            Text("Light a new fire", style = TextStyle(text, 18.sp, FontWeight.Bold))
            if (!small) {
                Spacer(GlanceModifier.height(6.dp))
                Text("Choose your next book", style = TextStyle(secondary, 12.sp))
            }
        }
    }

    @Composable
    private fun Compact(context: Context, state: BookWidgetSnapshot, size: DpSize) {
        Column(
            GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).padding(12.dp)
                .clickable(openAction(state)),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (size.height >= 160.dp) {
                val height = size.height - 120.dp
                val width = minOf(size.width - 24.dp, height * if (state.book?.mediaType == AppMediaType.EBOOK) 0.7f else 1f)
                WidgetCover(state.artworkPath, state.book?.title, width, height)
                Spacer(GlanceModifier.height(6.dp))
            }
            Text(state.book?.title.orEmpty(), style = TextStyle(text, 13.sp, FontWeight.Bold), maxLines = 1)
            if (size.height >= 160.dp) {
                Spacer(GlanceModifier.height(4.dp))
                Progress(state, size.width - 24.dp)
            }
            Actions(context, state, size.width - 24.dp, compact = true)
        }
    }

    @Composable
    private fun Wide(context: Context, state: BookWidgetSnapshot, size: DpSize) {
        Row(
            GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).padding(14.dp)
                .clickable(openAction(state)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val height = minOf(110.dp, size.height - 28.dp)
            val coverWidth = height * if (state.book?.mediaType == AppMediaType.EBOOK) 0.7f else 1f
            WidgetCover(state.artworkPath, state.book?.title, coverWidth, height)
            Spacer(GlanceModifier.width(14.dp))
            val width = (size.width - 42.dp - coverWidth).coerceAtLeast(1.dp)
            Column(GlanceModifier.width(width)) {
                Heading(state, 1, showAuthor = size.height >= 160.dp)
                if (size.height >= 160.dp) {
                    Spacer(GlanceModifier.height(6.dp))
                    Progress(state, width)
                }
                Actions(context, state, width)
            }
        }
    }

    @Composable
    private fun Large(context: Context, state: BookWidgetSnapshot, size: DpSize) {
        Column(
            GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).padding(16.dp)
                .clickable(openAction(state)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                val coverWidth = minOf(128.dp, (size.width - 46.dp) * 0.42f)
                val coverHeight = minOf(size.height - 132.dp,
                    coverWidth * if (state.book?.mediaType == AppMediaType.EBOOK) 1.4f else 1f)
                WidgetCover(state.artworkPath, state.book?.title, coverWidth, coverHeight.coerceAtLeast(24.dp))
                Spacer(GlanceModifier.width(14.dp))
                Column(GlanceModifier.width(size.width - coverWidth - 46.dp)) { Heading(state, 3) }
            }
            Spacer(GlanceModifier.height(12.dp))
            val width = size.width - 32.dp
            Progress(state, width)
            Actions(context, state, width)
            if (state.upNext.isNotEmpty() && size.height >= 280.dp) {
                Spacer(GlanceModifier.height(10.dp))
                Text("UP NEXT", style = TextStyle(ember, 10.sp, FontWeight.Bold))
                state.upNext.forEach { title -> Text(title, style = TextStyle(text, 12.sp), maxLines = 1) }
            }
        }
    }

    @Composable
    private fun Heading(state: BookWidgetSnapshot, titleLines: Int, showAuthor: Boolean = true) {
        Text(state.heading, style = TextStyle(ember, 10.sp, FontWeight.Bold), maxLines = 1)
        Text(state.book?.title.orEmpty(), style = TextStyle(text, 16.sp, FontWeight.Bold), maxLines = titleLines)
        if (showAuthor) state.book?.author?.let { Text(it, style = TextStyle(secondary, 11.sp), maxLines = 1) }
    }

    @Composable
    private fun Progress(state: BookWidgetSnapshot, width: Dp) {
        val fraction = state.progress.coerceIn(0f, 1f)
        Box(GlanceModifier.width(width).height(4.dp).cornerRadius(2.dp).background(surface)) {
            if (fraction > 0f) Box(GlanceModifier.width(width * fraction).height(4.dp).cornerRadius(2.dp).background(ember)) {}
        }
        Spacer(GlanceModifier.height(4.dp))
        val mode = when {
            state.book?.readAlongAvailable == true -> "complete"
            state.book?.mediaType == AppMediaType.EBOOK -> "read"
            else -> "listened"
        }
        Text("${(fraction * 100).toInt()}% $mode", style = TextStyle(secondary, 11.sp))
    }

    @Composable
    private fun Actions(context: Context, state: BookWidgetSnapshot, width: Dp, compact: Boolean = false) {
        Row(GlanceModifier.width(width), horizontalAlignment = Alignment.CenterHorizontally,
            verticalAlignment = Alignment.CenterVertically) {
            if (state.showsAudioControls) {
                val showSkip = !compact && state.readAlongSessionId == null &&
                    width >= if (state.readerBook == null) 120.dp else 200.dp
                if (showSkip) Command(context, state, R.drawable.widget_rewind, "Skip backward", "back")
                Command(context, state, if (state.isPlaying) R.drawable.widget_pause else R.drawable.widget_play,
                    if (state.isPlaying) "Pause" else "Play", "toggle")
                if (showSkip) Command(context, state, R.drawable.widget_forward, "Skip forward", "forward")
            }
            state.readerBook?.let { reader ->
                Text(if (reader.readAlongAvailable) "Read along" else "Read",
                    modifier = GlanceModifier.padding(horizontal = 8.dp, vertical = 12.dp)
                        .clickable(readerAction(reader)),
                    style = TextStyle(ember, 12.sp, FontWeight.Bold))
            }
        }
    }

    @Composable
    private fun Command(context: Context, state: BookWidgetSnapshot, @DrawableRes icon: Int, label: String, command: String) {
        Box(GlanceModifier.size(40.dp).clickable(actionSendBroadcast(
            Intent(context, BookWidgetCommandReceiver::class.java)
                .putExtra("command", command).putExtra("book_key", state.book?.uniqueKey)
                .putExtra("read_along_session", state.readAlongSessionId),
        )), contentAlignment = Alignment.Center) {
            Image(ImageProvider(icon), label, GlanceModifier.size(24.dp),
                colorFilter = ColorFilter.tint(if (command == "toggle") ember else text))
        }
    }

    private fun openAction(state: BookWidgetSnapshot): Action =
        state.readerBook?.let { readerAction(it) }
            ?: actionStartActivity<MainActivity>(
                actionParametersOf(ActionParameters.Key<Boolean>(MainActivity.EXTRA_OPEN_PLAYER) to true),
            )
}

class BookPlayerWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BookPlayerWidget()
}
