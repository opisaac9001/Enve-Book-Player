package com.enve.app.ui.screens.reader

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ColorFilter
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import android.view.Choreographer
import android.view.PixelCopy
import android.view.View
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import com.enve.core.data.local.ReaderPageTurnStyle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

internal object ReaderPageCurlPolicy {
    fun shouldCurl(
        style: ReaderPageTurnStyle,
        animatedPageTurns: Boolean,
        scrollMode: Boolean,
        reduceMotion: Boolean,
        animatorsEnabled: Boolean,
        einkActive: Boolean,
    ): Boolean = style == ReaderPageTurnStyle.CURL && animatedPageTurns && !scrollMode &&
        !reduceMotion && animatorsEnabled && !einkActive
}

internal class ReaderPageCurlRunner<S : Any>(
    private val scope: CoroutineScope,
    private val capture: suspend () -> S?,
    private val present: (S, Boolean) -> Unit,
    private val animate: suspend () -> Unit,
    private val dismiss: (S) -> Unit,
    private val settleTimeoutMs: Long = SETTLE_TIMEOUT_MS,
) {
    private var job: Job? = null
    private var closed = false

    val active: Boolean get() = job?.isActive == true

    fun turn(forward: Boolean, curl: Boolean, awaitTurn: () -> suspend () -> Unit, perform: () -> Unit) {
        if (closed) return
        val interrupted = active
        cancel()
        if (!curl || interrupted) {
            perform()
            return
        }
        job = scope.launch(start = CoroutineStart.UNDISPATCHED) {
            var snapshot: S? = null
            var performed = false
            try {
                snapshot = capture() ?: return@launch
                present(snapshot, forward)
                val settled = awaitTurn()
                performed = true
                perform()
                if (withTimeoutOrNull(settleTimeoutMs) { settled() } != null) animate()
            } finally {
                snapshot?.let(dismiss)
                if (!performed && !closed) perform()
            }
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
    }

    fun close() {
        closed = true
        cancel()
    }

    companion object {
        const val SETTLE_TIMEOUT_MS = 700L
        const val PAINT_SETTLE_MS = 48L
    }
}

internal fun View.windowBounds(): Rect? {
    if (!isAttachedToWindow || !isLaidOut || width <= 0 || height <= 0) return null
    val origin = IntArray(2).also(this::getLocationInWindow)
    return Rect(origin[0], origin[1], origin[0] + width, origin[1] + height)
}

internal class ReaderPageCurlSnapshot(val host: ViewGroup, val bitmap: Bitmap, val bounds: Rect)

internal class ReaderPageCurl(
    private val activity: Activity,
    scope: CoroutineScope,
    private val host: () -> ViewGroup,
    private val viewport: () -> Rect?,
) {
    private val drawable = ReaderPageCurlDrawable(activity.resources.displayMetrics.density)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val choreographer = Choreographer.getInstance()
    private var attachedTo: ViewGroup? = null
    private val runner = ReaderPageCurlRunner(
        scope = scope,
        capture = ::capture,
        present = ::present,
        animate = ::animate,
        dismiss = ::dismiss,
    )

    fun turn(forward: Boolean, curl: Boolean, awaitTurn: () -> suspend () -> Unit, perform: () -> Unit) =
        runner.turn(forward, curl, awaitTurn, perform)

    fun cancel() = runner.cancel()

    fun close() {
        runner.close()
        attachedTo?.overlay?.remove(drawable)
        attachedTo = null
    }

    private suspend fun capture(): ReaderPageCurlSnapshot? {
        val host = host()
        val hostBounds = host.windowBounds() ?: return null
        val source = Rect(viewport() ?: return null)
        if (!source.intersect(hostBounds)) return null
        val scale = min(1f, sqrt(MAX_SNAPSHOT_PIXELS / (source.width().toFloat() * source.height())))
        val bitmap = Bitmap.createBitmap(
            max(1, (source.width() * scale).toInt()),
            max(1, (source.height() * scale).toInt()),
            Bitmap.Config.ARGB_8888,
        )
        val copied = copyWindow(source, bitmap) ?: return null
        source.offset(-hostBounds.left, -hostBounds.top)
        return ReaderPageCurlSnapshot(host, copied, source)
    }

    private suspend fun copyWindow(source: Rect, bitmap: Bitmap): Bitmap? = suspendCancellableCoroutine { continuation ->
        try {
            PixelCopy.request(activity.window, source, bitmap, { result ->
                val copied = if (result == PixelCopy.SUCCESS) bitmap else null
                if (copied == null) bitmap.recycle()
                continuation.resume(copied) { _, rejected, _ -> rejected?.recycle() }
            }, mainHandler)
        } catch (_: IllegalArgumentException) {
            bitmap.recycle()
            continuation.resume(null)
        }
    }

    private fun present(snapshot: ReaderPageCurlSnapshot, forward: Boolean) {
        val host = snapshot.host
        if (attachedTo !== host) {
            attachedTo?.overlay?.remove(drawable)
            host.overlay.add(drawable)
            attachedTo = host
        }
        drawable.bounds = snapshot.bounds
        drawable.show(snapshot.bitmap, forward)
    }

    private suspend fun animate() = suspendCancellableCoroutine<Unit> { continuation ->
        val animator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = CURL_DURATION_MS
            interpolator = DecelerateInterpolator(CURL_DECELERATION)
            addUpdateListener { drawable.progress = it.animatedValue as Float }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    if (continuation.isActive) continuation.resume(Unit)
                }
            })
        }
        continuation.invokeOnCancellation { animator.cancel() }
        animator.start()
    }

    private fun dismiss(snapshot: ReaderPageCurlSnapshot) {
        drawable.clear(snapshot.bitmap)
        choreographer.postFrameCallback { choreographer.postFrameCallback { snapshot.bitmap.recycle() } }
    }

    private companion object {
        const val MAX_SNAPSHOT_PIXELS = 2_500_000f
        const val CURL_DURATION_MS = 460L
        const val CURL_DECELERATION = 1.4f
    }
}

internal class ReaderPageCurlDrawable(density: Float) : Drawable() {
    private var snapshot: Bitmap? = null
    private var forward = true
    private var paperColor = Color.WHITE
    private val pagePaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG)
    private val showThroughPaint = Paint(Paint.FILTER_BITMAP_FLAG or Paint.ANTI_ALIAS_FLAG).apply { alpha = SHOW_THROUGH_ALPHA }
    private val paper = Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.WHITE) }
    private val shadowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        shader = LinearGradient(0f, 0f, 1f, 0f, SHADOW_COLOR, Color.TRANSPARENT, Shader.TileMode.CLAMP)
    }
    private val shadowMatrix = Matrix()
    private val shadowTransform = FloatArray(9).apply {
        this[4] = 1f
        this[8] = 1f
    }
    private val shadowPath = Path()
    private val shadowWidth = SHADOW_WIDTH_DP * density
    private val front = FloatArray(VERTEX_COUNT * 2)
    private val back = FloatArray(VERTEX_COUNT * 2)
    private val frontColors = IntArray(VERTEX_COUNT)
    private val backColors = IntArray(VERTEX_COUNT)
    private val flapRows = BooleanArray(ROWS + 1)

    var progress = 0f
        set(value) {
            field = value.coerceIn(0f, 1f)
            invalidateSelf()
        }

    fun show(bitmap: Bitmap, forward: Boolean) {
        snapshot = bitmap
        this.forward = forward
        paperColor = medianColor(bitmap)
        progress = 0f
    }

    fun clear(bitmap: Bitmap) {
        if (snapshot !== bitmap) return
        snapshot = null
        invalidateSelf()
    }

    override fun draw(canvas: Canvas) {
        val bitmap = snapshot?.takeUnless(Bitmap::isRecycled) ?: return
        val width = bounds.width().toFloat()
        val height = bounds.height().toFloat()
        if (width <= 0f || height <= 0f) return
        val backVisible = layoutMeshes(width, height)
        val lift = min(1f, (1f - progress) * FADE_OUT_SPAN) * min(1f, progress * FADE_IN_SPAN)
        val direction = if (forward) 1f else -1f

        canvas.save()
        canvas.clipRect(bounds)
        drawEdgeShadow(canvas, front, direction * shadowWidth, (CAST_SHADOW_ALPHA * lift).toInt(), null)
        canvas.drawBitmapMesh(bitmap, COLUMNS, ROWS, front, 0, frontColors, 0, pagePaint)
        if (backVisible) {
            canvas.drawBitmapMesh(paper, COLUMNS, ROWS, back, 0, backColors, 0, pagePaint)
            canvas.drawBitmapMesh(bitmap, COLUMNS, ROWS, back, 0, null, 0, showThroughPaint)
            drawEdgeShadow(canvas, back, -direction * shadowWidth / 2f, (FREE_EDGE_SHADOW_ALPHA * lift).toInt(), flapRows)
        }
        canvas.restore()
    }

    private fun layoutMeshes(width: Float, height: Float): Boolean {
        val radius = min(width, height) * RADIUS_FRACTION
        val quarter = radius * HALF_PI
        val halfTurn = radius * PI_FLOAT
        val leadingCrease = width - progress * (width + radius)
        val bow = width * BOW_FRACTION * sin(PI_FLOAT * progress)
        var backVisible = false
        for (row in 0..ROWS) {
            val y = height * row / ROWS
            val t = 2f * y / height - 1f
            val crease = leadingCrease - bow * (1f - t * t)
            for (column in 0..COLUMNS) {
                val vertex = row * (COLUMNS + 1) + column
                val u = width * (if (forward) column else COLUMNS - column) / COLUMNS
                val curled = u - crease

                val frontSine = sin((curled / radius).coerceIn(0f, HALF_PI))
                val frontX = if (curled <= 0f) u else crease + radius * frontSine
                place(front, vertex, frontX, y, width)
                frontColors[vertex] = shade(Color.WHITE, 1f - FRONT_SHADE * frontSine * frontSine)

                val backX: Float
                val backLight: Float
                if (curled <= halfTurn) {
                    val sine = sin(max(curled / radius, HALF_PI))
                    backX = crease + radius * sine
                    backLight = 1f - BACK_SHADE * sine * sine
                } else {
                    backX = crease - (curled - halfTurn)
                    backLight = 1f
                }
                place(back, vertex, backX, y, width)
                backColors[vertex] = shade(paperColor, backLight)
                if (curled > quarter) backVisible = true
                if (column == if (forward) COLUMNS else 0) flapRows[row] = curled > halfTurn
            }
        }
        return backVisible
    }

    private fun place(mesh: FloatArray, vertex: Int, x: Float, y: Float, width: Float) {
        mesh[vertex * 2] = bounds.left + if (forward) x else width - x
        mesh[vertex * 2 + 1] = bounds.top + y
    }

    private fun drawEdgeShadow(canvas: Canvas, mesh: FloatArray, extent: Float, alpha: Int, rows: BooleanArray?) {
        if (alpha <= 0) return
        shadowPaint.alpha = alpha
        for (row in 0 until ROWS) {
            if (rows != null && !(rows[row] && rows[row + 1])) continue
            val top = (row * (COLUMNS + 1) + if (forward) COLUMNS else 0) * 2
            val bottom = top + (COLUMNS + 1) * 2
            val x0 = mesh[top]
            val y0 = mesh[top + 1]
            val x1 = mesh[bottom]
            val y1 = mesh[bottom + 1]
            shadowPath.rewind()
            shadowPath.moveTo(x0, y0)
            shadowPath.lineTo(x1, y1)
            shadowPath.lineTo(x1 + extent, y1)
            shadowPath.lineTo(x0 + extent, y0)
            shadowPath.close()
            val slope = (x1 - x0) / (y1 - y0)
            shadowTransform[0] = extent
            shadowTransform[1] = slope
            shadowTransform[2] = x0 - slope * y0
            shadowMatrix.setValues(shadowTransform)
            shadowPaint.shader.setLocalMatrix(shadowMatrix)
            canvas.drawPath(shadowPath, shadowPaint)
        }
    }

    private fun shade(color: Int, light: Float): Int {
        val level = light.coerceIn(0f, 1f)
        return Color.rgb(
            (Color.red(color) * level).toInt(),
            (Color.green(color) * level).toInt(),
            (Color.blue(color) * level).toInt(),
        )
    }

    private fun medianColor(bitmap: Bitmap): Int {
        val samples = IntArray(PAPER_SAMPLES * PAPER_SAMPLES) { index ->
            val x = (bitmap.width - 1) * (1 + index % PAPER_SAMPLES) / (PAPER_SAMPLES + 1)
            val y = (bitmap.height - 1) * (1 + index / PAPER_SAMPLES) / (PAPER_SAMPLES + 1)
            bitmap.getPixel(x, y)
        }
        return samples.sortedBy { Color.red(it) * 299 + Color.green(it) * 587 + Color.blue(it) * 114 }[samples.size / 2]
    }

    override fun setAlpha(alpha: Int) = Unit

    override fun setColorFilter(colorFilter: ColorFilter?) = Unit

    @Deprecated("Deprecated in Java")
    override fun getOpacity(): Int = PixelFormat.TRANSLUCENT

    private companion object {
        const val COLUMNS = 32
        const val ROWS = 16
        const val VERTEX_COUNT = (COLUMNS + 1) * (ROWS + 1)
        const val PI_FLOAT = PI.toFloat()
        const val HALF_PI = PI_FLOAT / 2f
        const val RADIUS_FRACTION = 0.14f
        const val BOW_FRACTION = 0.07f
        const val FRONT_SHADE = 0.34f
        const val BACK_SHADE = 0.28f
        const val SHOW_THROUGH_ALPHA = 0x2E
        const val PAPER_SAMPLES = 5
        const val SHADOW_WIDTH_DP = 26f
        const val SHADOW_COLOR = 0x5C000000
        const val CAST_SHADOW_ALPHA = 255
        const val FREE_EDGE_SHADOW_ALPHA = 150
        const val FADE_IN_SPAN = 12f
        const val FADE_OUT_SPAN = 6f
    }
}
