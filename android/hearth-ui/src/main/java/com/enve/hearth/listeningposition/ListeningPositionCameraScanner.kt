package com.enve.hearth.listeningposition

import android.Manifest
import android.content.pm.PackageManager
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.enve.hearth.design.Hearth
import com.google.zxing.BinaryBitmap
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.ReaderException
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.qrcode.QRCodeReader
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors

@Composable
fun ListeningPositionCameraScanner(onScan: (String) -> Unit) {
    val context = LocalContext.current
    val owner = LocalLifecycleOwner.current
    var permission by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var problem by remember { mutableStateOf<String?>(null) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permission = it }
    val callback by rememberUpdatedState(onScan)
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permission = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            }
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    Column {
        if (!permission) {
            Text("Enable the camera to scan a code, or choose an image below.", color = Hearth.palette.textSecondary)
            TextButton(onClick = { request.launch(Manifest.permission.CAMERA) }) { Text("Enable camera", color = Hearth.palette.text) }
        } else if (problem != null) {
            Text(problem!!, color = Hearth.palette.textSecondary)
        } else {
            val previewView = remember(context) {
                PreviewView(context).apply {
                    implementationMode = PreviewView.ImplementationMode.COMPATIBLE
                    scaleType = PreviewView.ScaleType.FILL_CENTER
                }
            }
            DisposableEffect(owner, previewView) {
                val executor = Executors.newSingleThreadExecutor()
                val future = ProcessCameraProvider.getInstance(context)
                val preview = Preview.Builder().build().also { it.surfaceProvider = previewView.surfaceProvider }
                val analysis = ImageAnalysis.Builder()
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setResolutionSelector(ResolutionSelector.Builder()
                        .setResolutionStrategy(ResolutionStrategy(Size(1280, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                        .build())
                    .build()
                    .also { analysis ->
                        val reader = QRCodeReader()
                        analysis.setAnalyzer(executor) { image ->
                            image.use { decode(reader, it) }?.let { message -> previewView.post { callback(message) } }
                        }
                    }
                var disposed = false
                future.addListener({
                    if (disposed) return@addListener
                    try {
                        val provider = future.get()
                        val selector = if (provider.hasCamera(CameraSelector.DEFAULT_BACK_CAMERA)) CameraSelector.DEFAULT_BACK_CAMERA else CameraSelector.DEFAULT_FRONT_CAMERA
                        provider.bindToLifecycle(owner, selector, preview, analysis)
                    } catch (_: ExecutionException) { problem = CAMERA_UNAVAILABLE }
                    catch (_: IllegalArgumentException) { problem = CAMERA_UNAVAILABLE }
                    catch (_: IllegalStateException) { problem = CAMERA_UNAVAILABLE }
                }, ContextCompat.getMainExecutor(context))
                onDispose {
                    disposed = true
                    if (future.isDone) runCatching { future.get().unbind(preview, analysis) }
                    analysis.clearAnalyzer()
                    executor.shutdown()
                }
            }
            AndroidView(factory = { previewView }, modifier = Modifier.fillMaxWidth().height(260.dp).clipToBounds())
        }
    }
}

private const val CAMERA_UNAVAILABLE = "Camera scanning isn't available. Choose an image of the code instead."

private fun decode(reader: QRCodeReader, image: ImageProxy): String? {
    val plane = image.planes[0]
    val buffer = plane.buffer
    val bytes = ByteArray(buffer.remaining()).also(buffer::get)
    val source = PlanarYUVLuminanceSource(bytes, plane.rowStride, image.height, 0, 0, image.width, image.height, false)
    return try {
        reader.decode(BinaryBitmap(HybridBinarizer(source))).text
    } catch (_: ReaderException) {
        null
    } finally {
        reader.reset()
    }
}
