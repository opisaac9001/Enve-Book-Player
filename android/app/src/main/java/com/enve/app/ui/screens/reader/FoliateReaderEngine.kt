package com.enve.app.ui.screens.reader

import android.annotation.SuppressLint
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ActionMode
import android.view.Menu
import android.view.MenuItem
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewFeature
import com.enve.app.data.reader.CustomFont
import com.enve.app.data.reader.ReaderPreferences
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import java.io.ByteArrayInputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.readium.r2.shared.publication.Locator

internal class FoliateBridgeSession(
    val capability: String = UUID.randomUUID().toString(),
) {
    private var initialStateServed = false
    private var lastSequence = 0L

    fun serveInitialState(): Boolean {
        if (initialStateServed) return false
        initialStateServed = true
        return true
    }

    fun accepts(capability: String?, sequence: Long): Boolean {
        if (!initialStateServed || capability != this.capability) return false
        if (sequence != lastSequence + 1L) return false
        lastSequence = sequence
        return true
    }
}

private class SelectionActionModeCallback(
    private val delegate: ActionMode.Callback,
) : ActionMode.Callback {
    override fun onCreateActionMode(mode: ActionMode, menu: Menu): Boolean {
        val created = delegate.onCreateActionMode(mode, menu)
        menu.clear()
        return created
    }

    override fun onPrepareActionMode(mode: ActionMode, menu: Menu): Boolean {
        val prepared = delegate.onPrepareActionMode(mode, menu)
        menu.clear()
        return prepared
    }

    override fun onActionItemClicked(mode: ActionMode, item: MenuItem): Boolean = false

    override fun onDestroyActionMode(mode: ActionMode) {
        delegate.onDestroyActionMode(mode)
    }
}

class FoliateReaderEngine(
    context: Context,
    private val container: FrameLayout,
    private val epubFile: File,
    customFonts: List<CustomFont>,
    private val initialCheckpoint: EpubBridgeCheckpoint?,
    private val identity: EpubBridgeCheckpoint,
    initialPreferences: ReaderPreferences,
    private val onReady: (
        List<ReaderEngineTocItem>,
        EpubBridgeCheckpoint?,
        String,
    ) -> Unit,
    private val onLocation: (ReaderEngineLocation) -> Unit,
    private val onSelectionChanged: () -> Unit,
    private val onAnnotationActivated: (String) -> Unit,
    private val onExternalLink: (Uri) -> Unit,
    private val onError: (String) -> Unit,
) : ReaderEngineNavigator {
    private data class CustomFontFace(
        val family: String,
        val assetPath: String,
        val file: File,
        val weight: Int,
        val style: String,
    )

    override val kind = ReaderEngineKind.FOLIATE

    @Volatile
    override var currentLocator: Locator? = null
        private set

    @Volatile
    override var currentSelection: Locator? = null
        private set

    private val pendingSearches = ConcurrentHashMap<String, CompletableDeferred<List<Locator>>>()
    private val customFontFaces = buildCustomFontFaces(customFonts)
    private val customFontFiles = customFontFaces.associateBy(CustomFontFace::assetPath)
    private val bridgeSession = FoliateBridgeSession()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val webView = object : WebView(context) {
        override fun startActionMode(callback: ActionMode.Callback): ActionMode? =
            super.startActionMode(SelectionActionModeCallback(callback))

        override fun startActionMode(callback: ActionMode.Callback, type: Int): ActionMode? =
            super.startActionMode(SelectionActionModeCallback(callback), type)
    }
    private var preferences = initialPreferences
    private var closed = false
    private var ready = false
    private val readyTimeout = Runnable {
        if (!closed && !ready) {
            onError("compatibility:Foliate did not finish loading on this Android System WebView.")
        }
    }

    init {
        container.removeAllViews()
        container.addView(
            webView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
        configureWebView()
        mainHandler.postDelayed(readyTimeout, READY_TIMEOUT_MS)
    }

    override fun goForward() = evaluate("window.enveReader.goForward()")

    override fun goBackward() = evaluate("window.enveReader.goBackward()")

    override fun goToProgress(fraction: Float) =
        evaluate("window.enveReader.goToProgress(${fraction.coerceIn(0f, 1f)})")

    override fun goToHref(href: String) =
        evaluate("window.enveReader.goToHref(${JSONObject.quote(href)})")

    override fun goToCfi(cfi: String) =
        evaluate("window.enveReader.goToLocator({locations:{cfi:${JSONObject.quote(cfi)}}})")

    override fun goToLocator(locator: Locator) {
        val json = locator.toJSON().toString()
        evaluate("window.enveReader.goToLocator($json)")
    }

    override fun applyPreferences(preferences: ReaderPreferences) {
        this.preferences = preferences
        if (!ready) return
        evaluate("window.enveReader.applyPreferences(${preferences.toFoliateJson()})")
    }

    override fun applyAnnotations(annotations: List<ReaderAnnotation>) {
        if (!ready) return
        val payload = JSONArray()
        annotations
            .asSequence()
            .filter { AnnotationKind.parse(it.kind) == AnnotationKind.HIGHLIGHT }
            .forEach { annotation ->
                val locator = annotation.locatorJson
                    ?.let { json -> runCatching { JSONObject(json) }.getOrNull() }

                val cfi = annotation.cfi
                    ?.let { if (it.startsWith("epubcfi(")) it else "epubcfi($it)" }
                    ?: if (locator.hasPortableRangeAnchor()) {
                        null
                    } else {
                        EpubBridgeCheckpointCodec.foliateCfi(annotation.locatorJson)
                    }
                if (cfi == null && locator == null) return@forEach
                val item = JSONObject()
                    .put("id", annotation.id)
                    .put("color", annotation.colorHex)
                    .put("style", annotation.style.lowercase())
                cfi?.let { item.put("cfi", it) }
                locator?.let { item.put("locator", it) }
                payload.put(item)
            }
        evaluate("window.enveReader.applyAnnotations($payload)")
    }

    private fun JSONObject?.hasPortableRangeAnchor(): Boolean {
        if (this == null) return false
        if (!optJSONObject("text")?.optString("highlight").isNullOrBlank()) return true
        val locations = optJSONObject("locations") ?: return false
        return locations.has("domRange") || !locations.optString("cssSelector").isNullOrBlank()
    }

    override fun clearSelection() = evaluate("window.enveReader.clearSelection()")

    override fun clearSearch() = evaluate("window.enveReader.clearSearch()")

    override fun autoScrollStep(distance: Float) =
        evaluate("window.enveReader.autoScrollStep(${distance.coerceIn(1f, 100f)})")

    override suspend fun search(query: String, limit: Int): List<Locator> {
        val requestId = UUID.randomUUID().toString()
        val deferred = CompletableDeferred<List<Locator>>()
        pendingSearches[requestId] = deferred
        evaluate(
            "window.enveReader.search(" +
                "${JSONObject.quote(requestId)}," +
                "${JSONObject.quote(query)}," +
                "${limit.coerceIn(1, 500)})",
        )
        return try {
            withTimeout(SEARCH_TIMEOUT_MS) { deferred.await() }
        } catch (error: CancellationException) {
            clearSearch()
            throw error
        } finally {
            pendingSearches.remove(requestId)
        }
    }

    override fun close() {
        if (closed) return
        mainHandler.removeCallbacks(readyTimeout)
        pendingSearches.values.forEach { it.cancel() }
        pendingSearches.clear()
        webView.evaluateJavascript(
            "(function(){ if (window.enveReader && window.enveReader.close) window.enveReader.close(); })()",
            null,
        )
        closed = true
        if (isSupported()) {
            WebViewCompat.removeWebMessageListener(webView, JS_BRIDGE)
        }
        webView.stopLoading()
        container.removeView(webView)
        webView.destroy()
    }

    @SuppressLint("SetJavaScriptEnabled", "RequiresFeature")
    private fun configureWebView() {
        check(isSupported()) {
            "This Android System WebView does not support secure Foliate messaging."
        }
        val assetLoader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/") { path ->
                if (path !in ALLOWED_ASSETS) {
                    blockedResponse()
                } else {
                    val mediaType = when {
                        path.endsWith(".html") -> "text/html"
                        path.endsWith(".css") -> "text/css"
                        path.endsWith(".js") -> "text/javascript"
                        path.endsWith(".ttf") -> "font/ttf"
                        path.endsWith(".otf") -> "font/otf"
                        else -> "application/octet-stream"
                    }
                    runCatching {
                        WebResourceResponse(
                            mediaType,
                            Charsets.UTF_8.name(),
                            webView.context.assets.open(path),
                        ).withoutCaching()
                    }.getOrElse { blockedResponse() }
                }
            }
            .addPathHandler("/book/") { path ->
                if (path == "current.epub" && epubFile.isFile) {
                    WebResourceResponse(
                        EPUB_MEDIA_TYPE,
                        null,
                        epubFile.inputStream(),
                    ).withoutCaching()
                } else {
                    blockedResponse()
                }
            }
            .addPathHandler("/fonts/") { path ->
                val face = customFontFiles[path]
                if (face == null || !face.file.isFile) {
                    blockedResponse()
                } else {
                    WebResourceResponse(
                        if (face.file.extension.equals("otf", ignoreCase = true)) {
                            "font/otf"
                        } else {
                            "font/ttf"
                        },
                        null,
                        face.file.inputStream(),
                    ).withoutCaching()
                }
            }
            .build()

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = false
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
            cacheMode = android.webkit.WebSettings.LOAD_NO_CACHE
        }
        WebViewCompat.addWebMessageListener(
            webView,
            JS_BRIDGE,
            setOf(ASSET_ORIGIN),
            NativeMessageListener(),
        )
        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(
                view: WebView?,
                request: WebResourceRequest,
            ): WebResourceResponse? {
                val uri = request.url
                if (uri.scheme == "blob" || uri.scheme == "data") return null
                val local = assetLoader.shouldInterceptRequest(uri)
                return local ?: blockedResponse()
            }

            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest,
            ): Boolean {
                val uri = request.url
                if (!request.isForMainFrame) {
                    return uri.scheme != "blob" && uri.scheme != "data"
                }
                return uri.scheme != "https" ||
                    uri.host != ASSET_HOST ||
                    uri.path != "/assets/foliate-reader.html"
            }

            override fun onRenderProcessGone(
                view: WebView?,
                detail: RenderProcessGoneDetail?,
            ): Boolean {
                onError("The Foliate renderer stopped unexpectedly.")
                return true
            }
        }
        webView.loadUrl("$ASSET_ORIGIN/assets/foliate-reader.html")
    }

    private fun evaluate(script: String) {
        webView.post {
            if (!closed) webView.evaluateJavascript(script, null)
        }
    }

    private fun initialStateJson(): String =
        JSONObject()
            .put(
                "checkpoint",
                initialCheckpoint?.let { JSONObject(EpubBridgeCheckpointCodec.encode(it)) },
            )
            .put(
                "identity",
                JSONObject()
                    .put("publicationSha256", identity.publicationSha256)
                    .put("providerFileId", identity.providerFileId)
                    .put("revision", identity.revision)
                    .put("writerEpoch", identity.writerEpoch),
            )
            .put("capability", bridgeSession.capability)
            .put("preferences", preferences.toFoliateJson())
            .put(
                "customFonts",
                JSONArray().apply {
                    customFontFaces
                        .groupBy(CustomFontFace::family)
                        .forEach { (family, faces) ->
                            put(
                                JSONObject()
                                    .put("family", family)
                                    .put(
                                        "faces",
                                        JSONArray().apply {
                                            faces.forEach { face ->
                                                put(
                                                    JSONObject()
                                                        .put(
                                                            "url",
                                                            "$ASSET_ORIGIN/fonts/${face.assetPath}",
                                                        )
                                                        .put("weight", face.weight)
                                                        .put("style", face.style),
                                                )
                                            }
                                        },
                                    ),
                            )
                        }
                },
            )
            .toString()

    private inner class NativeMessageListener : WebViewCompat.WebMessageListener {
        @SuppressLint("RequiresFeature")
        override fun onPostMessage(
            view: WebView,
            message: WebMessageCompat,
            sourceOrigin: Uri,
            isMainFrame: Boolean,
            replyProxy: JavaScriptReplyProxy,
        ) {
            if (!isMainFrame || !sourceOrigin.isTrustedAssetOrigin()) return
            val envelope = runCatching { JSONObject(message.data ?: return) }
                .getOrNull() ?: return
            val type = envelope.optString("type")
            if (type == "initialState") {
                if (bridgeSession.serveInitialState()) {
                    replyProxy.postMessage(initialStateJson())
                }
                return
            }
            if (
                !bridgeSession.accepts(
                    capability = envelope.optString("capability"),
                    sequence = envelope.optLong("sequence", -1L),
                )
            ) {
                return
            }
            val payload = envelope.opt("payload")
            when (type) {
                "ready" -> handleReady(payload as? JSONObject ?: JSONObject())
                "relocate" -> handleRelocate(payload as? JSONObject ?: return)
                "selection" -> handleSelection(payload as? JSONObject)
                "annotationActivated" -> {
                    val id = (payload as? JSONObject)?.optString("id").orEmpty()
                    if (id.isNotBlank()) webView.post { onAnnotationActivated(id) }
                }
                "externalLink" -> handleExternalLink(
                    (payload as? JSONObject)?.optString("href").orEmpty(),
                )
                "searchResult" -> handleSearchResult(payload as? JSONObject ?: return)
                "error" -> {
                    val detail = (payload as? JSONObject)?.optString("message").orEmpty()
                    webView.post {
                        onError(detail.ifBlank { "The Foliate renderer reported an error." })
                    }
                }
            }
        }

        private fun handleReady(root: JSONObject) {
            runCatching {
                val toc = root.optJSONArray("toc") ?: JSONArray()
                val items = buildList {
                    for (index in 0 until toc.length()) {
                        val item = toc.optJSONObject(index) ?: continue
                        val href = item.optString("href").takeIf { it.isNotBlank() } ?: continue
                        add(
                            ReaderEngineTocItem(
                                title = item.optString("title").ifBlank { "Untitled" },
                                href = href,
                                depth = item.optInt("depth", 0).coerceAtLeast(0),
                            ),
                        )
                    }
                }
                val checkpoint = root.optJSONObject("checkpoint")
                    ?.let { EpubBridgeCheckpointCodec.decode(it.toString()) }
                Triple(items, checkpoint, root.optString("restoreMethod"))
            }.onSuccess { (items, checkpoint, restoreMethod) ->
                ready = true
                mainHandler.removeCallbacks(readyTimeout)
                webView.post { onReady(items, checkpoint, restoreMethod) }
            }
                .onFailure { webView.post { onError("Foliate returned an invalid table of contents.") } }
        }

        private fun handleRelocate(root: JSONObject) {
            runCatching {
                val checkpoint = EpubBridgeCheckpointCodec.decode(
                    root.getJSONObject("checkpoint").toString(),
                ) ?: error("Missing checkpoint")
                val locator = Locator.fromJSON(root.optJSONObject("locator"))
                    ?: error("Missing locator")
                ReaderEngineLocation(
                    checkpoint = checkpoint,
                    locator = locator,
                    currentPage = root.optInt("currentPage", 1).coerceAtLeast(1),
                    totalPages = root.optInt("totalPages", 1).coerceAtLeast(1),
                    sectionTitle = root.optString("sectionTitle"),
                    userInitiated = root.optBoolean("userInitiated", false),
                )
            }.onSuccess { location ->
                currentLocator = location.locator
                webView.post { onLocation(location) }
            }.onFailure { webView.post { onError("Foliate returned an invalid reading position.") } }
        }

        private fun handleSelection(payload: JSONObject?) {
            currentSelection = payload
                ?.optJSONObject("locator")
                ?.let { Locator.fromJSON(it) }
            webView.post { onSelectionChanged() }
        }

        private fun handleExternalLink(url: String) {
            val uri = runCatching { Uri.parse(url) }.getOrNull() ?: return
            if (uri.scheme != "http" && uri.scheme != "https") return
            webView.post { onExternalLink(uri) }
        }

        private fun handleSearchResult(payload: JSONObject) {
            val requestId = payload.optString("requestId")
            val deferred = pendingSearches.remove(requestId) ?: return
            val result = runCatching {
                payload.optString("error").takeIf { it.isNotBlank() }?.let(::error)
                val rows = payload.optJSONArray("results") ?: JSONArray()
                buildList {
                    for (index in 0 until rows.length()) {
                        val locator = Locator.fromJSON(rows.optJSONObject(index)?.optJSONObject("locator"))
                        if (locator != null) add(locator)
                    }
                }
            }
            result.onSuccess(deferred::complete)
                .onFailure(deferred::completeExceptionally)
        }
    }

    private fun ReaderPreferences.toFoliateJson(): JSONObject =
        JSONObject()
            .put("theme", theme.name)
            .put("font", font.name)
            .put("customFontName", customFontName)
            .put("fontSize", fontSize)
            .put("lineHeight", lineHeight)
            .put("pageMargins", pageMargins)
            .put("wordSpacing", wordSpacing)
            .put("letterSpacing", letterSpacing)
            .put("fontWeight", fontWeight)
            .put("paragraphSpacing", paragraphSpacing)
            .put("paragraphIndent", paragraphIndent)
            .put("scroll", scroll)
            .put("publisherStyles", publisherStyles)
            .put("justified", justified)
            .put("columns", columns.name)
            .put("bionicReading", bionicReading)

    private fun buildCustomFontFaces(fonts: List<CustomFont>): List<CustomFontFace> =
        buildList {
            fonts.forEachIndexed { index, font ->
                fun addFace(path: String?, variant: String, weight: Int, style: String) {
                    val file = path?.let(::File)?.takeIf(File::isFile) ?: return
                    val extension = file.extension.lowercase()
                    if (extension != "ttf" && extension != "otf") return
                    add(
                        CustomFontFace(
                            family = font.displayName,
                            assetPath = "font-$index-$variant.$extension",
                            file = file,
                            weight = weight,
                            style = style,
                        ),
                    )
                }
                addFace(font.regularPath, "regular", 400, "normal")
                addFace(font.boldPath, "bold", 700, "normal")
                addFace(font.italicPath, "italic", 400, "italic")
                addFace(font.boldItalicPath, "bold-italic", 700, "italic")
            }
        }

    private fun blockedResponse() =
        WebResourceResponse(
            "text/plain",
            Charsets.UTF_8.name(),
            ByteArrayInputStream(ByteArray(0)),
        ).withoutCaching()

    private fun WebResourceResponse.withoutCaching(): WebResourceResponse = apply {
        responseHeaders = mapOf(
            "Cache-Control" to "no-store, no-cache, must-revalidate",
            "Pragma" to "no-cache",
        )
    }

    private fun Uri.isTrustedAssetOrigin(): Boolean =
        scheme == "https" &&
            host == ASSET_HOST &&
            port == -1

    companion object {
        const val ASSET_HOST = "appassets.androidplatform.net"
        const val ASSET_ORIGIN = "https://$ASSET_HOST"
        const val JS_BRIDGE = "EnveFoliate"
        const val EPUB_MEDIA_TYPE = "application/epub+zip"
        const val READY_TIMEOUT_MS = 20_000L
        const val SEARCH_TIMEOUT_MS = 20_000L

        private val ALLOWED_ASSETS = setOf(
            "foliate-reader.html",
            "foliate-reader.css",
            "foliate-reader.js",
            "foliate/view.js",
            "foliate/epub.js",
            "foliate/epubcfi.js",
            "foliate/fixed-layout.js",
            "foliate/paginator.js",
            "foliate/progress.js",
            "foliate/overlayer.js",
            "foliate/text-walker.js",
            "foliate/search.js",
            "foliate/tts.js",
            "foliate/footnotes.js",
            "foliate/vendor/zip.js",
        )

        fun isSupported(): Boolean =
            WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)
    }
}
