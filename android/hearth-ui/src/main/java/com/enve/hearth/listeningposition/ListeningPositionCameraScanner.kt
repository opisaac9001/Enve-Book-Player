package com.enve.hearth.listeningposition

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.Matrix
import android.graphics.SurfaceTexture
import android.hardware.camera2.*
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.view.Surface
import android.view.TextureView
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
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

@Composable
fun ListeningPositionCameraScanner(onScan: (String) -> Unit) {
    val context = LocalContext.current
    var permission by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var problem by remember { mutableStateOf<String?>(null) }
    val request = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { permission = it }
    val callback by rememberUpdatedState(onScan)
    val owner = LocalLifecycleOwner.current
    var resumed by remember(owner) { mutableStateOf(owner.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) }
    DisposableEffect(owner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                permission = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
                problem = null
                resumed = true
            } else if (event == Lifecycle.Event.ON_PAUSE) resumed = false
        }
        owner.lifecycle.addObserver(observer)
        onDispose { owner.lifecycle.removeObserver(observer) }
    }
    Column {
        if (!permission) {
            Text("Enable the camera to scan a code, or choose an image below.", color = Hearth.palette.textSecondary)
            TextButton(onClick = { request.launch(Manifest.permission.CAMERA) }) { Text("Enable camera", color = Hearth.palette.text) }
        } else if (!resumed) {
            Text("Camera paused", color = Hearth.palette.textSecondary)
        } else if (problem != null) {
            Text(problem!!, color = Hearth.palette.textSecondary)
        } else {
            val scanner = remember(context) { CameraQrScanner(context, { callback(it) }, { problem = it }) }
            DisposableEffect(scanner) { onDispose { scanner.close() } }
            AndroidView(factory = { TextureView(it).also(scanner::attach) }, modifier = Modifier.fillMaxWidth().height(260.dp))
        }
    }
}

private class CameraQrScanner(
    context: Context,
    private val onScan: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val manager = context.getSystemService(CameraManager::class.java)
    private val thread = HandlerThread("ListeningPositionCamera").apply { start() }
    private val handler = Handler(thread.looper)
    private var view: TextureView? = null
    @Volatile private var closed = false
    private var opening = false
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var images: ImageReader? = null
    private var preview: Surface? = null
    private var lastScan = 0L
    private var autofocus = CaptureRequest.CONTROL_AF_MODE_OFF

    fun attach(texture: TextureView) {
        view = texture
        texture.surfaceTextureListener = object : TextureView.SurfaceTextureListener {
            override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) { handler.post { open(surface) } }
            override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) = Unit
            override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean { close(); return true }
            override fun onSurfaceTextureUpdated(surface: SurfaceTexture) = Unit
        }
        if (texture.isAvailable) texture.surfaceTexture?.let { surface -> handler.post { open(surface) } }
    }

    @SuppressLint("MissingPermission")
    private fun open(surface: SurfaceTexture) {
        if (closed) return
        try {
            val ids = manager.cameraIdList
            val id = ids.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK }
                ?: ids.firstOrNull() ?: return fail()
            val characteristics = manager.getCameraCharacteristics(id)
            val modes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES) ?: intArrayOf()
            autofocus = when {
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE in modes -> CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
                CaptureRequest.CONTROL_AF_MODE_AUTO in modes -> CaptureRequest.CONTROL_AF_MODE_AUTO
                else -> CaptureRequest.CONTROL_AF_MODE_OFF
            }
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return fail()
            fun choose(sizes: Array<android.util.Size>?) = sizes.orEmpty().filter { it.width <= 1280 && it.height <= 1280 }
                .minByOrNull { kotlin.math.abs(it.width * it.height - 640 * 480) } ?: sizes.orEmpty().minByOrNull { it.width.toLong() * it.height }
            val imageSize = choose(map.getOutputSizes(ImageFormat.YUV_420_888)) ?: return fail()
            val previewSize = choose(map.getOutputSizes(SurfaceTexture::class.java)) ?: return fail()
            surface.setDefaultBufferSize(previewSize.width, previewSize.height)
            preview = Surface(surface)
            view?.post {
                val texture = view ?: return@post
                val displayRotation = when (texture.display?.rotation) { Surface.ROTATION_90 -> 90; Surface.ROTATION_180 -> 180; Surface.ROTATION_270 -> 270; else -> 0 }
                val rotation = ((characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0) - displayRotation + 360) % 360
                val rotatedWidth = if (rotation % 180 == 0) previewSize.width else previewSize.height
                val rotatedHeight = if (rotation % 180 == 0) previewSize.height else previewSize.width
                val width = texture.width.toFloat().coerceAtLeast(1f)
                val height = texture.height.toFloat().coerceAtLeast(1f)
                val scale = maxOf(width / rotatedWidth, height / rotatedHeight)
                texture.setTransform(Matrix().apply {
                    setScale(previewSize.width / width, previewSize.height / height)
                    postTranslate(-previewSize.width / 2f, -previewSize.height / 2f)
                    postRotate(rotation.toFloat())
                    postScale(scale, scale)
                    postTranslate(width / 2, height / 2)
                })
            }
            images = ImageReader.newInstance(imageSize.width, imageSize.height, ImageFormat.YUV_420_888, 2).also { reader ->
                reader.setOnImageAvailableListener({ source ->
                    if (closed) return@setOnImageAvailableListener
                    val latest = try { source.acquireLatestImage() } catch (_: IllegalStateException) { null }
                    latest?.use { image ->
                        val now = SystemClock.elapsedRealtime()
                        if (closed || now - lastScan < 500) return@use
                        lastScan = now
                        val plane = image.planes[0]
                        val buffer = plane.buffer
                        val bytes = ByteArray(image.width * image.height)
                        for (y in 0 until image.height) for (x in 0 until image.width) {
                            bytes[y * image.width + x] = buffer.get(buffer.position() + y * plane.rowStride + x * plane.pixelStride)
                        }
                        val sourceImage = PlanarYUVLuminanceSource(bytes, image.width, image.height, 0, 0, image.width, image.height, false)
                        try {
                            val message = QRCodeReader().decode(BinaryBitmap(HybridBinarizer(sourceImage))).text
                            view?.post { if (!closed) onScan(message) }
                        } catch (_: ReaderException) { }
                    }
                }, handler)
            }
            if (closed) return
            opening = true
            manager.openCamera(id, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    opening = false
                    if (closed) { camera.close(); thread.quitSafely(); return }
                    device = camera
                    start(camera)
                }
                override fun onDisconnected(camera: CameraDevice) { opening = false; camera.close(); if (closed) thread.quitSafely() else fail() }
                override fun onError(camera: CameraDevice, error: Int) { opening = false; camera.close(); if (closed) thread.quitSafely() else fail() }
            }, handler)
        } catch (_: CameraAccessException) { opening = false; fail() }
        catch (_: SecurityException) { opening = false; fail() }
        catch (_: IllegalArgumentException) { opening = false; fail() }
    }

    @Suppress("DEPRECATION")
    private fun start(camera: CameraDevice) {
        val surface = preview ?: return
        val reader = images ?: return
        try {
            camera.createCaptureSession(listOf(surface, reader.surface), object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(configured: CameraCaptureSession) {
                    if (closed) { configured.close(); return }
                    session = configured
                    try {
                        val request = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                            addTarget(surface)
                            addTarget(reader.surface)
                            set(CaptureRequest.CONTROL_AF_MODE, autofocus)
                        }.build()
                        configured.setRepeatingRequest(request, null, handler)
                    } catch (_: CameraAccessException) { fail() }
                    catch (_: IllegalStateException) { fail() }
                    catch (_: IllegalArgumentException) { fail() }
                }
                override fun onConfigureFailed(configured: CameraCaptureSession) { configured.close(); fail() }
            }, handler)
        } catch (_: CameraAccessException) { fail() }
        catch (_: IllegalStateException) { fail() }
        catch (_: IllegalArgumentException) { fail() }
    }

    private fun fail() {
        view?.post { if (view?.isAttachedToWindow == true) onError("Camera scanning isn't available. Choose an image of the code instead.") }
        close()
    }

    fun close() {
        if (closed) return
        closed = true
        handler.post {
            session?.close()
            device?.close()
            images?.close()
            preview?.release()
            if (!opening) thread.quitSafely()
        }
    }
}
