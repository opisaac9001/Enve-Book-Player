package com.enve.app.ui.webbrowser

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.net.http.SslError
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.HttpAuthHandler
import android.webkit.RenderProcessGoneDetail
import android.webkit.SslErrorHandler
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.webkit.ProfileStore
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.util.UUID
import kotlin.coroutines.resume

internal const val MAX_CAPTURE_CHARS = 3 * 1024 * 1024
internal const val MAX_TABLE_CHAPTERS = 10_000
private const val MAX_CAPTURE_ELEMENTS = 60_000
private const val MAX_TABLE_PAGES = 500
private const val TABLE_PAGE_TIMEOUT_MS = 8_000L
private const val TABLE_POLL_MS = 150L

private val royalRoadHosts = setOf("royalroad.com", "www.royalroad.com")
private val royalRoadFictionPath = Regex("^/fiction/(\\d+)(?:/[^/]+)?/?$")
private val royalRoadChapterPath = Regex("^/fiction/(\\d+)/[^/]*/chapter/(\\d+)(?:/[^/]*)?/?$")

fun isWebStoryBrowserAvailable(): Boolean = WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)

@Composable
fun WebStoryBrowser(
    initialUrl: String,
    onClose: () -> Unit,
    onCapture: (url: String, html: String) -> Unit,
) {
    val startUrl = remember(initialUrl) { browsableUrl(initialUrl) }
    val available = remember { isWebStoryBrowserAvailable() }
    Column(
        Modifier
            .fillMaxSize()
            .background(Hearth.palette.bg)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding(),
    ) {
        when {
            !available -> BrowserMessage(BrowserNotice.UNAVAILABLE, onClose)
            startUrl == null -> BrowserMessage(BrowserNotice.INVALID_URL, onClose)
            else -> BrowserSession(startUrl, onClose, onCapture)
        }
    }
}

internal enum class BrowserNotice(val message: String) {
    UNAVAILABLE("Private browsing needs a newer Android System WebView. Update it from the Play Store and try again."),
    INVALID_URL("Paste a web address that starts with http:// or https://."),
    BLOCKED_LINK("That link doesn't lead to a web page, so it was blocked."),
    CERTIFICATE("The site's security certificate isn't trusted, so the page was blocked."),
    HTTP_AUTH("This site asks for a browser sign-in prompt, which isn't supported here."),
    UNREACHABLE("The page couldn't be reached. Check the connection and try again."),
    LOAD_FAILED("The page couldn't be loaded."),
    NOT_READY("Wait for the page to finish loading, then try again."),
    NAVIGATED("The page changed while it was being captured. Wait for it to settle and try again."),
    EMPTY("No readable text was found on this page."),
    TOO_LARGE("The page is larger than Enve imports."),
    CAPTURE_FAILED("The page couldn't be captured. Try again once it finishes loading."),
    CHAPTERS_UNREADABLE("The full chapter list couldn't be read, so nothing was imported. Let the page finish loading and try again."),
    RENDERER_GONE("The page stopped responding and was closed."),
}

internal sealed interface CaptureOutcome {
    data class Captured(val html: String) : CaptureOutcome
    data class Failed(val notice: BrowserNotice) : CaptureOutcome
}

internal data class RoyalRoadChapter(val id: String, val url: String, val title: String)

internal data class RoyalRoadTableState(
    val active: Int,
    val pages: Int,
    val chapters: List<RoyalRoadChapter>,
    val embedded: List<RoyalRoadChapter>?,
    val hasFirst: Boolean,
    val hasNext: Boolean,
) {
    val chapterIds: List<String> get() = chapters.map { it.id }
}

internal sealed interface TableStep {
    data class Ready(val state: RoyalRoadTableState) : TableStep
    object Clicked : TableStep
    data class Failed(val notice: BrowserNotice) : TableStep
}

internal fun browsableUrl(raw: String): String? =
    raw.trim().toHttpUrlOrNull()?.takeIf { it.username.isEmpty() && it.password.isEmpty() }?.toString()

internal fun royalRoadFictionId(url: String): String? {
    val parsed = url.toHttpUrlOrNull() ?: return null
    if (!parsed.isHttps || parsed.host !in royalRoadHosts || parsed.username.isNotEmpty() || parsed.password.isNotEmpty()) return null
    return royalRoadFictionPath.matchEntire(parsed.encodedPath)?.groupValues?.get(1)
}

private fun royalRoadChapterId(url: String, fictionId: String): String? {
    val parsed = url.toHttpUrlOrNull() ?: return null
    if (!parsed.isHttps || parsed.host !in royalRoadHosts || parsed.username.isNotEmpty() || parsed.password.isNotEmpty()) return null
    val match = royalRoadChapterPath.matchEntire(parsed.encodedPath) ?: return null
    return match.groupValues[2].takeIf { match.groupValues[1] == fictionId }
}

internal fun parseCaptureResult(raw: String?, maxChars: Int = MAX_CAPTURE_CHARS): CaptureOutcome {
    val result = parseJsonObject(raw)
    val html = result?.string("h")
    return when (result?.string("s")) {
        "ok" -> when {
            html.isNullOrBlank() -> CaptureOutcome.Failed(BrowserNotice.CAPTURE_FAILED)
            html.length > maxChars -> CaptureOutcome.Failed(BrowserNotice.TOO_LARGE)
            else -> CaptureOutcome.Captured(html)
        }
        "navigated" -> CaptureOutcome.Failed(BrowserNotice.NAVIGATED)
        "empty" -> CaptureOutcome.Failed(BrowserNotice.EMPTY)
        "too_large" -> CaptureOutcome.Failed(BrowserNotice.TOO_LARGE)
        "chapters" -> CaptureOutcome.Failed(BrowserNotice.CHAPTERS_UNREADABLE)
        else -> CaptureOutcome.Failed(BrowserNotice.CAPTURE_FAILED)
    }
}

internal fun parseTableState(raw: String?, fictionId: String): TableStep {
    val result = parseJsonObject(raw)
    return when (result?.string("s")) {
        "ok" -> {
            val chapters = chapterList(result["chapters"], fictionId)
            val active = (result["active"] as? JsonPrimitive)?.intOrNull
            val pages = (result["pages"] as? JsonPrimitive)?.intOrNull
            if (chapters == null || active == null || pages == null || active < 1 || pages < active) {
                return TableStep.Failed(BrowserNotice.CHAPTERS_UNREADABLE)
            }
            val embedded = chapterList(result["embedded"], fictionId)
                ?.takeIf { isCompleteTable(it, chapters, active, pages) }
            TableStep.Ready(
                RoyalRoadTableState(
                    active = active,
                    pages = pages,
                    chapters = chapters,
                    embedded = embedded,
                    hasFirst = (result["first"] as? JsonPrimitive)?.booleanOrNull == true,
                    hasNext = (result["next"] as? JsonPrimitive)?.booleanOrNull == true,
                ),
            )
        }
        "clicked" -> TableStep.Clicked
        "navigated" -> TableStep.Failed(BrowserNotice.NAVIGATED)
        else -> TableStep.Failed(BrowserNotice.CHAPTERS_UNREADABLE)
    }
}

private fun isCompleteTable(embedded: List<RoyalRoadChapter>, visible: List<RoyalRoadChapter>, active: Int, pages: Int): Boolean {
    if (active != 1 || visible.isEmpty() || embedded.take(visible.size).map { it.id } != visible.map { it.id }) return false
    val pageSize = visible.size
    return if (pages == 1) embedded.size == pageSize else embedded.size in ((pages - 1) * pageSize + 1)..(pages * pageSize)
}

private fun chapterList(element: JsonElement?, fictionId: String): List<RoyalRoadChapter>? {
    val items = element as? JsonArray ?: return null
    if (items.size > MAX_TABLE_CHAPTERS) return null
    val chapters = items.map { item ->
        val entry = item as? JsonObject ?: return null
        val id = entry.string("id") ?: return null
        val url = entry.string("url") ?: return null
        if (royalRoadChapterId(url, fictionId) != id) return null
        RoyalRoadChapter(id, url, entry.string("title").orEmpty())
    }
    return chapters.takeIf { list -> list.distinctBy { it.id }.size == list.size }
}

private fun parseJsonObject(raw: String?): JsonObject? = raw?.let {
    try {
        Json.parseToJsonElement(it)
    } catch (e: SerializationException) {
        null
    }
} as? JsonObject

private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

internal fun captureScript(expectedUrl: String, chapters: List<RoyalRoadChapter>? = null): String {
    val chapterJson = chapters?.let { list ->
        JsonArray(list.map { JsonObject(mapOf("url" to JsonPrimitive(it.url), "title" to JsonPrimitive(it.title))) })
    } ?: JsonNull
    return "($CAPTURE_FUNCTION)(${JsonPrimitive(expectedUrl)}, $MAX_CAPTURE_CHARS, $MAX_CAPTURE_ELEMENTS, $chapterJson)"
}

internal fun tableScript(expectedUrl: String, fictionId: String, action: String): String =
    "($TABLE_FUNCTION)(${JsonPrimitive(expectedUrl)}, ${JsonPrimitive(fictionId)}, ${JsonPrimitive(action)}, $MAX_TABLE_CHAPTERS)"

@Composable
private fun BrowserSession(startUrl: String, onClose: () -> Unit, onCapture: (String, String) -> Unit) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val session = remember(startUrl) { WebStorySession(context, startUrl) }
    val currentOnCapture by rememberUpdatedState(onCapture)

    DisposableEffect(session) {
        onDispose { session.release() }
    }
    DisposableEffect(session, lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            when (event) {
                Lifecycle.Event.ON_RESUME -> session.resume()
                Lifecycle.Event.ON_PAUSE -> session.pause()
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(session, session.rendererGone) {
        if (session.rendererGone) session.release()
    }

    if (session.rendererGone) {
        BrowserMessage(BrowserNotice.RENDERER_GONE, onClose)
        return
    }

    BackHandler {
        if (session.canGoBack) session.goBack() else onClose()
    }

    val palette = Hearth.palette
    val eink = Hearth.eink
    val ready = !session.loading && !session.capturing

    Column(Modifier.fillMaxSize()) {
        BrowserToolbar(session, onClose)
        if (session.loading && !eink.suppressAnimations) {
            LinearProgressIndicator(
                progress = { session.progress / 100f },
                modifier = Modifier.fillMaxWidth().height(2.dp),
                color = palette.ember,
                trackColor = palette.hairline,
            )
        } else {
            HorizontalDivider(color = palette.hairline)
        }
        session.notice?.let { notice ->
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(palette.bgElevated)
                    .clickable { session.notice = null }
                    .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                Text(
                    notice.message,
                    style = HearthText.Caption,
                    color = palette.statusError,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    Icons.Default.Close,
                    contentDescription = "Dismiss",
                    tint = palette.textSecondary,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
        AndroidView(
            factory = { session.webView },
            modifier = Modifier.weight(1f).fillMaxWidth(),
        )
        HorizontalDivider(color = palette.hairline)
        EmberButton(
            text = when {
                !session.capturing -> "Import this page"
                session.capturePage > 0 -> "Reading chapter page ${session.capturePage}… Tap to cancel"
                else -> "Capturing page… Tap to cancel"
            },
            onClick = { session.capture { url, html -> currentOnCapture(url, html) } },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
            tint = if (ready) null else palette.textTertiary,
        )
    }
}

@Composable
private fun BrowserToolbar(session: WebStorySession, onClose: () -> Unit) {
    val palette = Hearth.palette
    val host = session.url?.toHttpUrlOrNull()?.host
    val subtitle = if (session.loading && Hearth.eink.suppressAnimations) "Loading…" else host.orEmpty()
    Row(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XS, vertical = Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        ToolbarButton(Icons.Default.Close, "Cancel", enabled = true, onClick = onClose)
        Column(Modifier.weight(1f).padding(horizontal = Hearth.Spacing.S)) {
            Text(
                session.title?.takeIf { it.isNotBlank() } ?: host.orEmpty(),
                style = HearthText.Body,
                color = palette.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                subtitle,
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        ToolbarButton(Icons.AutoMirrored.Filled.ArrowBack, "Back", session.canGoBack, session::goBack)
        ToolbarButton(Icons.AutoMirrored.Filled.ArrowForward, "Forward", session.canGoForward, session::goForward)
        if (session.loading) {
            ToolbarButton(Icons.Default.Clear, "Stop", enabled = true, onClick = session::stop)
        } else {
            ToolbarButton(Icons.Default.Refresh, "Reload", enabled = true, onClick = session::reload)
        }
    }
}

@Composable
private fun ToolbarButton(icon: ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    val palette = Hearth.palette
    IconButton(onClick = onClick, enabled = enabled) {
        Icon(icon, contentDescription = label, tint = if (enabled) palette.text else palette.textTertiary)
    }
}

@Composable
private fun BrowserMessage(notice: BrowserNotice, onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Column(
        Modifier
            .fillMaxSize()
            .padding(Hearth.Spacing.XXL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            notice.message,
            style = HearthText.Body,
            color = Hearth.palette.text,
            textAlign = TextAlign.Center,
        )
        EmberButton(text = "Close", onClick = onClose)
    }
}

@SuppressLint("SetJavaScriptEnabled")
private class WebStorySession(context: Context, startUrl: String) {
    var url by mutableStateOf<String?>(startUrl)
    var title by mutableStateOf<String?>(null)
    var progress by mutableIntStateOf(0)
    var loading by mutableStateOf(true)
    var canGoBack by mutableStateOf(false)
    var canGoForward by mutableStateOf(false)
    var capturing by mutableStateOf(false)
    var capturePage by mutableIntStateOf(0)
    var notice by mutableStateOf<BrowserNotice?>(null)
    var rendererGone by mutableStateOf(false)

    private var generation = 0
    private var mainFrameFailed = false
    private var released = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var captureJob: Job? = null

    val webView = WebView(context)
    private val profileName = TransientWebProfiles.attach(webView)

    init {
        with(webView.settings) {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            mediaPlaybackRequiresUserGesture = true
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            safeBrowsingEnabled = true
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = true
            displayZoomControls = false
            setSupportMultipleWindows(false)
            setGeolocationEnabled(false)
        }
        webView.webViewClient = Client()
        webView.webChromeClient = Chrome()
        webView.loadUrl(startUrl)
    }

    fun goBack() {
        if (released || !webView.canGoBack()) return
        beginNavigation()
        webView.goBack()
    }

    fun goForward() {
        if (released || !webView.canGoForward()) return
        beginNavigation()
        webView.goForward()
    }

    fun reload() {
        if (released) return
        beginNavigation()
        webView.reload()
    }

    fun stop() {
        if (released) return
        webView.stopLoading()
        loading = false
    }

    fun resume() {
        if (!released) webView.onResume()
    }

    fun pause() {
        if (!released) webView.onPause()
    }

    fun capture(onCapture: (String, String) -> Unit) {
        if (released) return
        if (capturing) {
            captureJob?.cancel()
            return
        }
        val expected = webView.url?.substringBefore('#')
        when {
            mainFrameFailed -> notice = BrowserNotice.LOAD_FAILED
            loading || expected == null || browsableUrl(expected) == null -> notice = BrowserNotice.NOT_READY
            else -> {
                val startGeneration = generation
                val fictionId = royalRoadFictionId(expected)
                capturing = true
                notice = null
                captureJob = scope.launch {
                    val outcome = try {
                        val chapters = fictionId?.let { collectRoyalRoadChapters(expected, it, startGeneration) }
                        ensureUnchanged(expected, startGeneration)
                        val raw = evaluate(captureScript(expected, chapters))
                        ensureUnchanged(expected, startGeneration)
                        parseCaptureResult(raw)
                    } catch (e: CaptureAbort) {
                        CaptureOutcome.Failed(e.notice)
                    } finally {
                        capturing = false
                        capturePage = 0
                    }
                    when (outcome) {
                        is CaptureOutcome.Captured -> onCapture(expected, outcome.html)
                        is CaptureOutcome.Failed -> notice = outcome.notice
                    }
                }
            }
        }
    }

    private suspend fun collectRoyalRoadChapters(expected: String, fictionId: String, startGeneration: Int): List<RoyalRoadChapter> {
        var state = readTable(expected, fictionId, startGeneration)
        if (state.active != 1) {
            if (!state.hasFirst) throw CaptureAbort(BrowserNotice.CHAPTERS_UNREADABLE)
            state = turnTablePage(expected, fictionId, startGeneration, "first", 1, state.chapterIds)
        }
        state.embedded?.let { return it }
        val chapters = LinkedHashMap<String, RoyalRoadChapter>()
        var page = 1
        while (true) {
            capturePage = page
            if (state.chapters.isEmpty()) throw CaptureAbort(BrowserNotice.CHAPTERS_UNREADABLE)
            state.chapters.forEach { chapters.putIfAbsent(it.id, it) }
            if (chapters.size > MAX_TABLE_CHAPTERS) throw CaptureAbort(BrowserNotice.TOO_LARGE)
            if (!state.hasNext) break
            if (page >= MAX_TABLE_PAGES) throw CaptureAbort(BrowserNotice.TOO_LARGE)
            page++
            state = turnTablePage(expected, fictionId, startGeneration, "next", page, state.chapterIds)
        }
        if (page != state.pages) throw CaptureAbort(BrowserNotice.CHAPTERS_UNREADABLE)
        return chapters.values.toList()
    }

    private suspend fun tableStep(expected: String, fictionId: String, startGeneration: Int, action: String): TableStep {
        ensureUnchanged(expected, startGeneration)
        val step = parseTableState(evaluate(tableScript(expected, fictionId, action)), fictionId)
        ensureUnchanged(expected, startGeneration)
        return step
    }

    private suspend fun readTable(expected: String, fictionId: String, startGeneration: Int): RoyalRoadTableState =
        when (val step = tableStep(expected, fictionId, startGeneration, "state")) {
            is TableStep.Ready -> step.state
            is TableStep.Failed -> throw CaptureAbort(step.notice)
            TableStep.Clicked -> throw CaptureAbort(BrowserNotice.CHAPTERS_UNREADABLE)
        }

    private suspend fun turnTablePage(
        expected: String,
        fictionId: String,
        startGeneration: Int,
        action: String,
        target: Int,
        previous: List<String>,
    ): RoyalRoadTableState {
        when (val step = tableStep(expected, fictionId, startGeneration, action)) {
            TableStep.Clicked -> Unit
            is TableStep.Failed -> throw CaptureAbort(step.notice)
            is TableStep.Ready -> throw CaptureAbort(BrowserNotice.CHAPTERS_UNREADABLE)
        }
        return withTimeoutOrNull(TABLE_PAGE_TIMEOUT_MS) {
            var turned: RoyalRoadTableState? = null
            while (turned == null) {
                delay(TABLE_POLL_MS)
                val step = tableStep(expected, fictionId, startGeneration, "state")
                if (step is TableStep.Failed && step.notice != BrowserNotice.CHAPTERS_UNREADABLE) throw CaptureAbort(step.notice)
                turned = (step as? TableStep.Ready)?.state
                    ?.takeIf { it.active == target && it.chapters.isNotEmpty() && it.chapterIds != previous }
            }
            turned
        } ?: throw CaptureAbort(BrowserNotice.CHAPTERS_UNREADABLE)
    }

    private fun ensureUnchanged(expected: String, startGeneration: Int) {
        if (released || generation != startGeneration || webView.url?.substringBefore('#') != expected) {
            throw CaptureAbort(BrowserNotice.NAVIGATED)
        }
    }

    private suspend fun evaluate(script: String): String? = suspendCancellableCoroutine { continuation ->
        webView.evaluateJavascript(script) { result ->
            if (continuation.isActive) continuation.resume(result)
        }
    }

    fun release() {
        if (released) return
        released = true
        scope.cancel()
        capturing = false
        canGoBack = false
        canGoForward = false
        webView.stopLoading()
        webView.webChromeClient = null
        (webView.parent as? ViewGroup)?.removeView(webView)
        webView.destroy()
        TransientWebProfiles.delete(profileName)
    }

    private fun beginNavigation() {
        generation++
        notice = null
        mainFrameFailed = false
    }

    private fun syncHistory() {
        if (released) return
        canGoBack = webView.canGoBack()
        canGoForward = webView.canGoForward()
    }

    private inner class Client : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            if (request == null) return true
            if (!request.isForMainFrame) return request.url.scheme?.lowercase() !in subframeSchemes
            if (browsableUrl(request.url.toString()) == null) {
                if (request.hasGesture()) notice = BrowserNotice.BLOCKED_LINK
                return true
            }
            beginNavigation()
            return false
        }

        override fun onPageStarted(view: WebView?, pageUrl: String?, favicon: Bitmap?) {
            generation++
            loading = true
            url = pageUrl
            syncHistory()
        }

        override fun onPageFinished(view: WebView?, pageUrl: String?) {
            loading = false
            syncHistory()
        }

        override fun doUpdateVisitedHistory(view: WebView?, pageUrl: String?, isReload: Boolean) {
            url = pageUrl
            syncHistory()
        }

        override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
            if (request?.isForMainFrame != true) return
            mainFrameFailed = true
            notice = when (error?.errorCode) {
                WebViewClient.ERROR_HOST_LOOKUP,
                WebViewClient.ERROR_CONNECT,
                WebViewClient.ERROR_TIMEOUT,
                -> BrowserNotice.UNREACHABLE
                else -> BrowserNotice.LOAD_FAILED
            }
        }

        override fun onReceivedSslError(view: WebView?, handler: SslErrorHandler?, error: SslError?) {
            handler?.cancel()
            if (error?.url == view?.url) mainFrameFailed = true
            notice = BrowserNotice.CERTIFICATE
        }

        override fun onReceivedHttpAuthRequest(view: WebView?, handler: HttpAuthHandler?, host: String?, realm: String?) {
            handler?.cancel()
            notice = BrowserNotice.HTTP_AUTH
        }

        override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
            rendererGone = true
            return true
        }
    }

    private inner class Chrome : WebChromeClient() {
        override fun onProgressChanged(view: WebView?, newProgress: Int) {
            progress = newProgress
        }

        override fun onReceivedTitle(view: WebView?, pageTitle: String?) {
            title = pageTitle
        }
    }

    private companion object {
        val subframeSchemes = setOf("http", "https", "about", "data", "blob")
    }
}

private class CaptureAbort(val notice: BrowserNotice) : Exception(notice.message)

private object TransientWebProfiles {
    private const val PREFIX = "enve-web-story-"
    private const val DELETE_ATTEMPTS = 20
    private const val DELETE_RETRY_MS = 250L
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(webView: WebView): String {
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            val store = ProfileStore.getInstance()
            store.allProfileNames.filter { it.startsWith(PREFIX) }.forEach { tryDelete(store, it) }
            val name = PREFIX + UUID.randomUUID()
            val profile = store.getOrCreateProfile(name)
            WebViewCompat.setProfile(webView, name)
            profile.cookieManager.setAcceptThirdPartyCookies(webView, false)
            return name
        }
        error("WebView multi-profile support is required")
    }

    fun delete(name: String, attempt: Int = 1) {
        if (WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) {
            if (!tryDelete(ProfileStore.getInstance(), name) && attempt < DELETE_ATTEMPTS) {
                mainHandler.postDelayed({ delete(name, attempt + 1) }, DELETE_RETRY_MS)
            }
        }
    }

    private fun tryDelete(store: ProfileStore, name: String): Boolean {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.MULTI_PROFILE)) return false
        return try {
            store.deleteProfile(name)
            true
        } catch (e: IllegalStateException) {
            false
        }
    }
}

private const val CAPTURE_FUNCTION = """function (expected, maxChars, maxElements, chapters) {
  try {
    if (location.href.split('#')[0] !== expected) return { s: 'navigated' };
    var source = document;
    if (!source.body) return { s: 'empty' };
    var target = source.implementation.createHTMLDocument('');
    var dropped = ['script', 'noscript', 'template', 'style', 'link', 'meta', 'base', 'iframe', 'frame', 'frameset',
      'object', 'embed', 'applet', 'portal', 'canvas', 'video', 'audio', 'source', 'track', 'slot', 'svg', 'math'];
    var urlAttributes = ['href', 'src', 'action', 'formaction', 'poster', 'background', 'cite', 'longdesc', 'data', 'xlink:href'];
    var headAttributes = ['name', 'property', 'itemprop', 'content', 'rel', 'href', 'hreflang', 'type', 'title', 'lang'];
    var headLinks = ['canonical', 'author', 'prev', 'next', 'alternate', 'license'];
    var elements = 0;

    function webUrl(value) {
      try {
        var protocol = new URL(value, source.baseURI).protocol;
        return protocol === 'http:' || protocol === 'https:';
      } catch (e) {
        return false;
      }
    }

    function scrub(element) {
      var names = [];
      for (var i = 0; i < element.attributes.length; i++) names.push(element.attributes[i].name);
      for (var j = 0; j < names.length; j++) {
        var name = names[j].toLowerCase();
        if (name.indexOf('on') === 0 || name === 'style' || name === 'srcdoc' || name === 'ping' || name === 'nonce' ||
            (urlAttributes.indexOf(name) >= 0 && !webUrl(element.getAttribute(names[j])))) {
          element.removeAttribute(names[j]);
        }
      }
    }

    function boxHidden(element, style) {
      if (style.display === 'none' || parseFloat(style.opacity) === 0) return true;
      if (style.display !== 'contents' && typeof element.checkVisibility === 'function' &&
          !element.checkVisibility({ opacityProperty: true, checkOpacity: true })) return true;
      if (style.position !== 'absolute' && style.position !== 'fixed') return false;
      var rect = element.getBoundingClientRect();
      if (rect.right + scrollX < 0 || rect.bottom + scrollY < 0) return true;
      return rect.width <= 1 && rect.height <= 1 && style.overflow !== 'visible';
    }

    function textHidden(style) {
      var color = style.color.replace(/\s/g, '');
      return style.visibility !== 'visible' || parseFloat(style.fontSize) === 0 || color === 'transparent' ||
        (color.indexOf('rgba(') === 0 && color.slice(-3) === ',0)');
    }

    function stripText(element) {
      var nodes = Array.prototype.slice.call(element.childNodes);
      for (var i = 0; i < nodes.length; i++) if (nodes[i].nodeType === 3) element.removeChild(nodes[i]);
    }

    function restoreImage(original, copy) {
      var current = original.currentSrc;
      if (current && webUrl(current) && !copy.getAttribute('src')) copy.setAttribute('src', current);
    }

    function prune(original, copy) {
      var originals = original.childNodes;
      var copies = copy.childNodes;
      var pairs = [];
      for (var i = 0; i < originals.length && i < copies.length; i++) pairs.push([originals[i], copies[i]]);
      for (var k = 0; k < pairs.length; k++) {
        var from = pairs[k][0];
        var to = pairs[k][1];
        if (from.nodeType === 3) continue;
        if (from.nodeType !== 1) { copy.removeChild(to); continue; }
        if (++elements > maxElements) throw 'too_large';
        var name = from.localName.toLowerCase();
        if (dropped.indexOf(name) >= 0) { copy.removeChild(to); continue; }
        var style = getComputedStyle(from);
        if (boxHidden(from, style)) { copy.removeChild(to); continue; }
        scrub(to);
        if (name === 'img') restoreImage(from, to);
        prune(from, to);
        if (textHidden(style)) stripText(to);
      }
    }

    var head = target.head;
    while (head.firstChild) head.removeChild(head.firstChild);
    var charset = target.createElement('meta');
    charset.setAttribute('charset', 'utf-8');
    head.appendChild(charset);
    if (source.title) {
      var title = target.createElement('title');
      title.textContent = source.title;
      head.appendChild(title);
    }
    var candidates = source.head ?
      source.head.querySelectorAll('base[href], meta[name], meta[property], meta[itemprop], link[rel][href]') : [];
    for (var c = 0; c < candidates.length; c++) {
      var node = candidates[c];
      var tag = node.localName;
      if (tag === 'link') {
        var rels = (node.getAttribute('rel') || '').toLowerCase().split(/\s+/);
        var keep = false;
        for (var r = 0; r < rels.length; r++) if (headLinks.indexOf(rels[r]) >= 0) keep = true;
        if (!keep) continue;
      }
      if (tag !== 'meta' && !webUrl(node.getAttribute('href'))) continue;
      var entry = target.createElement(tag);
      for (var a = 0; a < headAttributes.length; a++) {
        var value = node.getAttribute(headAttributes[a]);
        if (value !== null) entry.setAttribute(headAttributes[a], value);
      }
      head.appendChild(entry);
    }

    var body = target.importNode(source.body, true);
    scrub(body);
    prune(source.body, body);
    if (textHidden(getComputedStyle(source.body))) stripText(body);
    var root = target.documentElement;
    var lang = source.documentElement.getAttribute('lang');
    var dir = source.documentElement.getAttribute('dir');
    if (lang) root.setAttribute('lang', lang);
    if (dir) root.setAttribute('dir', dir);
    root.replaceChild(body, target.body);
    if (chapters) {
      var list = body.querySelector('#chapters');
      if (!list || list.localName !== 'table' || !list.parentElement) return { s: 'chapters' };
      var pagers = list.parentElement.querySelectorAll('.pagination, .pagination-small, .chapter-nav');
      for (var p = 0; p < pagers.length; p++) if (pagers[p].parentNode) pagers[p].parentNode.removeChild(pagers[p]);
      var sections = Array.prototype.slice.call(list.children);
      for (var q = 0; q < sections.length; q++) {
        if (['thead', 'caption', 'colgroup'].indexOf(sections[q].localName) < 0) list.removeChild(sections[q]);
      }
      var tbody = target.createElement('tbody');
      for (var n = 0; n < chapters.length; n++) {
        var row = target.createElement('tr');
        row.setAttribute('class', 'chapter-row');
        var cell = target.createElement('td');
        var anchor = target.createElement('a');
        anchor.setAttribute('href', chapters[n].url);
        anchor.textContent = chapters[n].title || ('Chapter ' + (n + 1));
        cell.appendChild(anchor);
        row.appendChild(cell);
        tbody.appendChild(row);
      }
      list.appendChild(tbody);
    }
    if (!body.textContent.trim()) return { s: 'empty' };
    var html = '<!DOCTYPE html>' + root.outerHTML;
    if (html.length > maxChars) return { s: 'too_large' };
    if (location.href.split('#')[0] !== expected) return { s: 'navigated' };
    return { s: 'ok', h: html };
  } catch (e) {
    return { s: e === 'too_large' ? 'too_large' : 'failed' };
  }
}"""

private const val TABLE_FUNCTION = """function (expected, fictionId, action, maxChapters) {
  try {
    if (location.href.split('#')[0] !== expected) return { s: 'navigated' };
    var table = document.querySelector('#chapters');
    if (!table || !table.parentElement) return { s: 'missing' };
    var pager = table.parentElement.querySelector('ul.pagination-small');

    function clean(value) {
      return (value || '').replace(/\s+/g, ' ').trim();
    }

    function chapterOf(href) {
      try {
        var url = new URL(href, document.baseURI);
        var match = url.pathname.match(/^\/fiction\/(\d+)\/[^\/]*\/chapter\/(\d+)(?:\/[^\/]*)?\/?$/);
        if (url.origin !== location.origin || url.username || url.password || !match || match[1] !== fictionId) return null;
        return { id: match[2], url: url.origin + url.pathname, title: '' };
      } catch (e) {
        return null;
      }
    }

    function pageOf(element) {
      var number = Number(clean(element && element.textContent));
      return number > 0 && number % 1 === 0 ? number : 0;
    }

    function safeControl(link) {
      if (!link || !pager || !pager.contains(link)) return false;
      var href = link.getAttribute('href');
      var target = link.getAttribute('target');
      return (href === null || href === '' || href.charAt(0) === '#') && (!target || target === '_self');
    }

    var visible = [];
    var seen = {};
    var links = table.querySelectorAll('a[href*="/chapter/"]');
    for (var i = 0; i < links.length; i++) {
      if (!links[i].getClientRects().length) continue;
      var chapter = chapterOf(links[i].getAttribute('href'));
      if (!chapter) return { s: 'invalid' };
      var title = clean(links[i].textContent);
      if (seen[chapter.id]) {
        if (!seen[chapter.id].title) seen[chapter.id].title = title;
        continue;
      }
      chapter.title = title;
      seen[chapter.id] = chapter;
      visible.push(chapter);
    }

    var active = 1;
    var pages = 1;
    var first = null;
    var next = null;
    if (pager) {
      active = pageOf(pager.querySelector('.page-active a')) || pageOf(pager.querySelector('.page-active'));
      if (!active) return { s: 'missing' };
      var controls = pager.querySelectorAll('a');
      for (var j = 0; j < controls.length; j++) {
        var number = pageOf(controls[j]);
        if (number > pages) pages = number;
        if (number === 1 && !first) first = controls[j];
      }
      if (active > pages) pages = active;
      var arrow = pager.querySelector('.nav-arrow:not(.disabled) a .fa-chevron-right');
      next = arrow ? arrow.closest('a') : null;
    }

    if (action === 'first' || action === 'next') {
      var control = action === 'first' ? first : next;
      if (!safeControl(control)) return { s: 'unsafe' };
      control.click();
      return { s: 'clicked' };
    }

    var embedded = null;
    var list = window.chapters;
    if (active === 1 && Array.isArray(list) && list.length && list.length <= maxChapters) {
      embedded = [];
      for (var k = 0; k < list.length; k++) {
        var item = list[k];
        var entry = item && typeof item.url === 'string' ? chapterOf(item.url) : null;
        if (!entry || String(item.id) !== entry.id) {
          embedded = null;
          break;
        }
        entry.title = clean(typeof item.title === 'string' ? item.title : '');
        embedded.push(entry);
      }
    }

    return { s: 'ok', active: active, pages: pages, chapters: visible, embedded: embedded, first: !!first, next: !!next };
  } catch (e) {
    return { s: 'failed' };
  }
}"""
