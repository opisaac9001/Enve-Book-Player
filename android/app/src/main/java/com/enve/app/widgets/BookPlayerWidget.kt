package com.enve.app.widgets

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.drawable.toBitmap
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionParametersOf
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.appwidget.action.actionSendBroadcast
import androidx.glance.background
import androidx.glance.layout.Box
import androidx.glance.layout.Column
import androidx.glance.layout.ContentScale
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import coil.ImageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.app.MainActivity
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.PlaybackFacade
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.distinctUntilChangedBy
import kotlinx.coroutines.launch

private data class BookWidgetSnapshot(
    val title: String?,
    val author: String?,
    val isPlaying: Boolean,
    val positionMs: Long,
    val durationMs: Long,
    val coverUrl: String?,
    val artworkPath: String?,
    val shelfTitles: List<String>,
)

private object BookWidgetStore {
    private const val PREFS = "enve_book_widget"
    private const val SEPARATOR = "\u001E"

    fun save(context: Context, snapshot: BookWidgetSnapshot) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("title", snapshot.title)
            .putString("author", snapshot.author)
            .putBoolean("playing", snapshot.isPlaying)
            .putLong("position", snapshot.positionMs)
            .putLong("duration", snapshot.durationMs)
            .putString("cover_url", snapshot.coverUrl)
            .putString("shelf", snapshot.shelfTitles.joinToString(SEPARATOR))
            .apply()
    }

    fun saveArtwork(context: Context, path: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("artwork", path).apply()
    }

    fun clearArtwork(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove("artwork").apply()
    }

    fun load(context: Context): BookWidgetSnapshot {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        return BookWidgetSnapshot(
            title = prefs.getString("title", null),
            author = prefs.getString("author", null),
            isPlaying = prefs.getBoolean("playing", false),
            positionMs = prefs.getLong("position", 0L),
            durationMs = prefs.getLong("duration", 0L),
            coverUrl = prefs.getString("cover_url", null),
            artworkPath = prefs.getString("artwork", null),
            shelfTitles = prefs.getString("shelf", null)?.split(SEPARATOR).orEmpty().filter(String::isNotBlank),
        )
    }
}

@Singleton
class BookWidgetPublisher @Inject constructor(
    @ApplicationContext private val context: Context,
    private val playback: PlaybackFacade,
    library: LibraryFacade,
    private val imageLoader: ImageLoader,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    init {
        scope.launch {
            combine(playback.nowPlaying, playback.transport, library.continueBooks, library.downloaded) { now, transport, recent, downloaded ->
                val previousArtwork = BookWidgetStore.load(context).artworkPath
                BookWidgetSnapshot(
                    title = now?.title,
                    author = now?.author,
                    isPlaying = transport.isPlaying,
                    positionMs = transport.positionMs,
                    durationMs = transport.durationMs,
                    coverUrl = now?.coverUrl,
                    artworkPath = previousArtwork,
                    shelfTitles = (recent + downloaded).distinctBy { it.uniqueKey }.take(3).map { it.title },
                )
            }.distinctUntilChangedBy { snapshot ->
                listOf(
                    snapshot.title,
                    snapshot.author,
                    snapshot.isPlaying,
                    snapshot.positionMs / 15_000,
                    snapshot.durationMs,
                    snapshot.coverUrl,
                    snapshot.shelfTitles,
                )
            }.collect { snapshot ->
                val previousCover = BookWidgetStore.load(context).coverUrl
                if (snapshot.coverUrl != previousCover) BookWidgetStore.clearArtwork(context)
                BookWidgetStore.save(context, snapshot)
                BookPlayerWidget().updateAll(context)
                if (snapshot.coverUrl != null && snapshot.coverUrl != previousCover) cacheArtwork(snapshot.coverUrl)
            }
        }
    }

    private suspend fun cacheArtwork(url: String) {
        try {
            val result = imageLoader.execute(
                ImageRequest.Builder(context).data(url).size(512).allowHardware(false).build(),
            ) as? SuccessResult ?: return
            val file = File(context.filesDir, "widget_book_cover.jpg")
            FileOutputStream(file).use { output ->
                result.drawable.toBitmap(512, 512).compress(Bitmap.CompressFormat.JPEG, 86, output)
            }
            BookWidgetStore.saveArtwork(context, file.absolutePath)
            BookPlayerWidget().updateAll(context)
        } catch (error: CancellationException) {
            throw error
        } catch (_: Exception) {
        }
    }
}

class BookWidgetCommandReceiver : BroadcastReceiver() {
    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface PlaybackEntryPoint {
        fun playback(): PlaybackFacade
    }

    override fun onReceive(context: Context, intent: Intent) {
        val playback = EntryPointAccessors.fromApplication(
            context.applicationContext,
            PlaybackEntryPoint::class.java,
        ).playback()
        when (intent.getStringExtra("command")) {
            "back" -> playback.skipBackward()
            "toggle" -> playback.togglePlayPause()
            "forward" -> playback.skipForward()
        }
    }
}

private val bg = ColorProvider(Color(0xFF191512))
private val surface = ColorProvider(Color(0xFF302821))
private val text = ColorProvider(Color(0xFFF3EBDD))
private val secondary = ColorProvider(Color(0xFFB9AA98))
private val ember = ColorProvider(Color(0xFFF5921A))

class BookPlayerWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(
        setOf(DpSize(120.dp, 120.dp), DpSize(250.dp, 120.dp), DpSize(250.dp, 250.dp)),
    )

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snapshot = BookWidgetStore.load(context)
        provideContent {
            val size = LocalSize.current
            when {
                size.width < 180.dp -> Compact(context, snapshot)
                size.height < 180.dp -> Wide(context, snapshot)
                else -> Large(context, snapshot)
            }
        }
    }

    @Composable
    private fun Compact(context: Context, state: BookWidgetSnapshot) {
        Box(GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).clickable(openPlayerAction())) {
            Artwork(state, GlanceModifier.fillMaxSize())
            Column(GlanceModifier.fillMaxSize().padding(12.dp)) {
                Spacer(GlanceModifier.height(70.dp))
                Text(state.title ?: "Continue Listening", style = TextStyle(text, 13.sp, FontWeight.Bold), maxLines = 1)
                Spacer(GlanceModifier.height(6.dp))
                Command(context, if (state.isPlaying) "⏸" else "▶", "toggle", ember)
            }
        }
    }

    @Composable
    private fun Wide(context: Context, state: BookWidgetSnapshot) {
        Row(GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).padding(14.dp).clickable(openPlayerAction())) {
            Artwork(state, GlanceModifier.size(92.dp).cornerRadius(16.dp))
            Spacer(GlanceModifier.width(14.dp))
            Column {
                Text("CONTINUE LISTENING", style = TextStyle(ember, 10.sp, FontWeight.Bold))
                Text(state.title ?: "Nothing playing", style = TextStyle(text, 16.sp, FontWeight.Bold), maxLines = 1)
                Text(state.author ?: "Open Enve to choose a book", style = TextStyle(secondary, 11.sp), maxLines = 1)
                Spacer(GlanceModifier.height(8.dp))
                Progress(state, 120.dp)
                Spacer(GlanceModifier.height(8.dp))
                Controls(context, state)
            }
        }
    }

    @Composable
    private fun Large(context: Context, state: BookWidgetSnapshot) {
        Column(GlanceModifier.fillMaxSize().background(bg).cornerRadius(24.dp).padding(16.dp).clickable(openPlayerAction())) {
            Row {
                Artwork(state, GlanceModifier.size(112.dp).cornerRadius(18.dp))
                Spacer(GlanceModifier.width(14.dp))
                Column {
                    Text("NOW LISTENING", style = TextStyle(ember, 10.sp, FontWeight.Bold))
                    Text(state.title ?: "Nothing playing", style = TextStyle(text, 17.sp, FontWeight.Bold), maxLines = 2)
                    Text(state.author.orEmpty(), style = TextStyle(secondary, 11.sp), maxLines = 1)
                }
            }
            Spacer(GlanceModifier.height(10.dp))
            Progress(state, 218.dp)
            Spacer(GlanceModifier.height(10.dp))
            Controls(context, state)
            if (state.shelfTitles.isNotEmpty()) {
                Spacer(GlanceModifier.height(12.dp))
                Text("UP NEXT", style = TextStyle(ember, 10.sp, FontWeight.Bold))
                state.shelfTitles.take(2).forEach { title ->
                    Text(title, style = TextStyle(text, 12.sp, FontWeight.Medium), maxLines = 1)
                }
            }
        }
    }

    @Composable
    private fun Artwork(state: BookWidgetSnapshot, modifier: GlanceModifier) {
        val bitmap = state.artworkPath?.let(BitmapFactory::decodeFile)
        if (bitmap != null) Image(ImageProvider(bitmap), null, modifier, ContentScale.Crop)
        else Box(modifier.background(surface)) {}
    }

    @Composable
    private fun Progress(state: BookWidgetSnapshot, width: Dp) {
        val fraction = if (state.durationMs > 0) (state.positionMs.toFloat() / state.durationMs).coerceIn(0f, 1f) else 0f
        Box(GlanceModifier.width(width).height(4.dp).cornerRadius(2.dp).background(surface)) {
            Box(GlanceModifier.width(width * fraction).height(4.dp).cornerRadius(2.dp).background(ember)) {}
        }
    }

    @Composable
    private fun Controls(context: Context, state: BookWidgetSnapshot) {
        Row {
            Command(context, "↶", "back", text)
            Spacer(GlanceModifier.width(26.dp))
            Command(context, if (state.isPlaying) "⏸" else "▶", "toggle", ember)
            Spacer(GlanceModifier.width(26.dp))
            Command(context, "↷", "forward", text)
        }
    }

    @Composable
    private fun Command(context: Context, glyph: String, command: String, color: ColorProvider) {
        Text(
            glyph,
            style = TextStyle(color, 20.sp, FontWeight.Bold),
            modifier = GlanceModifier.clickable(
                actionSendBroadcast(
                    Intent(context, BookWidgetCommandReceiver::class.java).putExtra("command", command),
                ),
            ),
        )
    }

    private fun openPlayerAction() = actionStartActivity<MainActivity>(
        actionParametersOf(ActionParameters.Key<Boolean>(MainActivity.EXTRA_OPEN_PLAYER) to true),
    )
}

class BookPlayerWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BookPlayerWidget()
}
