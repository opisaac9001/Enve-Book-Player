package com.enve.hearth.podcasts

import android.content.Intent
import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.listeningposition.ListeningPositionQRCode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException

@Composable
internal fun PodcastEpisodeShareSheet(title: String, url: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val bitmap by produceState<Bitmap?>(null, url) {
        value = withContext(Dispatchers.Default) { ListeningPositionQRCode.image(url) }
    }
    var imageShareFailed by remember(url) { mutableStateOf(false) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(
            Modifier.fillMaxSize().background(Hearth.palette.bg).statusBarsPadding().navigationBarsPadding()
                .verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Overline("Share episode", Modifier.weight(1f))
                TextButton(onClick = onClose) { Text("Close", color = Hearth.palette.textSecondary) }
            }
            Text(title, style = HearthText.ScreenTitle, color = Hearth.palette.text)
            bitmap?.let { image ->
                Image(
                    image.asImageBitmap(),
                    "Episode QR code for $title",
                    Modifier.widthIn(max = 300.dp).fillMaxWidth().aspectRatio(1f).align(Alignment.CenterHorizontally),
                    filterQuality = FilterQuality.None,
                )
            }
            Text(
                "Send the link or scan the QR code with your camera to open the episode.",
                style = HearthText.Body,
                color = Hearth.palette.textSecondary,
            )
            EmberButton("Share link", onClick = {
                val intent = Intent(Intent.ACTION_SEND).setType("text/plain")
                    .putExtra(Intent.EXTRA_TEXT, url)
                    .putExtra(Intent.EXTRA_SUBJECT, title)
                context.startActivity(Intent.createChooser(intent, "Share episode"))
            })
            bitmap?.let { image ->
                QuietButton("Share QR image", onClick = {
                    imageShareFailed = try {
                        ListeningPositionQRCode.share(context, image, title = "Share episode QR image")
                        false
                    } catch (_: IOException) {
                        true
                    }
                })
            }
            if (imageShareFailed) {
                Text("Couldn't share the image. Try again.", style = HearthText.Body, color = Hearth.palette.textSecondary)
            }
        }
    }
}
