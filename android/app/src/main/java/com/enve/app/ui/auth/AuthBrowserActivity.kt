// AGENT-LOCKED
package com.enve.app.ui.auth

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.core.view.WindowCompat
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import com.enve.app.MainActivity

class AuthBrowserActivity : ComponentActivity() {
    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    // Preserve the origin across ViewModel resets during the Storyteller callback.
    private var originServerUrl: String = ""
    private var requiredCookieName: String? = null
    private var requireOriginReturnBeforeCookie: Boolean = false
    private var hasLeftOriginForCookieAuth: Boolean = false
    private var cookieReturned: Boolean = false
    private val cookieHandler = Handler(Looper.getMainLooper())
    private val cookiePoller = object : Runnable {
        override fun run() {
            val currentUrl = if (::webView.isInitialized) webView.url else null
            if (checkRequiredCookie(currentUrl)) return
            cookieHandler.postDelayed(this, 250L)
        }
    }

    private fun checkRequiredCookie(currentUrl: String? = null): Boolean {
        if (cookieReturned || originServerUrl.isBlank()) return false
        val name = requiredCookieName ?: return false
        if (requireOriginReturnBeforeCookie && !isReturnedFromCookieAuth(currentUrl)) return false
        val raw = CookieManager.getInstance().getCookie(originServerUrl).orEmpty()
        if (!raw.contains("$name=")) return false
        cookieReturned = true
        setResult(Activity.RESULT_OK, Intent().putExtra(EXTRA_RESULT_COOKIE, raw))
        finish()
        return true
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, true)

        val startUrl = intent.getStringExtra(EXTRA_URL)?.takeIf { it.isNotBlank() }
        if (startUrl == null) {
            finish()
            return
        }
        originServerUrl = runCatching {
            val parsed = Uri.parse(startUrl)
            "${parsed.scheme}://${parsed.host}${if (parsed.port != -1) ":${parsed.port}" else ""}"
        }.getOrDefault("")
        requiredCookieName = intent.getStringExtra(EXTRA_REQUIRED_COOKIE)?.takeIf { it.isNotBlank() }
        requireOriginReturnBeforeCookie = intent.getBooleanExtra(EXTRA_REQUIRE_ORIGIN_RETURN_BEFORE_COOKIE, false)

        setupContent(startUrl)
        // Clear stale identity-provider state before starting an ephemeral session.
        CookieManager.getInstance().removeAllCookies(null)
        CookieManager.getInstance().flush()
        android.webkit.WebStorage.getInstance().deleteAllData()
        webView.clearCache(true)
        webView.clearHistory()
        webView.loadUrl(startUrl)
        if (requiredCookieName != null) cookieHandler.postDelayed(cookiePoller, 1000L)

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (::webView.isInitialized && webView.canGoBack()) {
                    webView.goBack()
                } else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })
    }

    override fun onDestroy() {
        cookieHandler.removeCallbacks(cookiePoller)
        if (::webView.isInitialized) {
            (webView.parent as? ViewGroup)?.removeView(webView)
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupContent(startUrl: String) {
        val accent = intent.getIntExtra(EXTRA_ACCENT, DEFAULT_ACCENT)
        val host = runCatching { Uri.parse(startUrl).host.orEmpty() }.getOrDefault("")

        progressBar = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            isIndeterminate = false
            max = 100
            progress = 0
            visibility = View.GONE
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                resources.displayMetrics.density.toInt().coerceAtLeast(1) * 3,
            )
        }

        webView = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f,
            )
            // Avoid an opaque black surface before the identity provider's first paint.
            setBackgroundColor(Color.WHITE)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.loadsImagesAutomatically = true
            settings.javaScriptCanOpenWindowsAutomatically = true
            settings.setSupportMultipleWindows(false)
            settings.mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            // Google rejects the WebView marker in the user agent during federated sign-in.
            settings.userAgentString = sanitizeWebViewUserAgent(settings.userAgentString)
            if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_AUTHENTICATION)) {
                WebSettingsCompat.setWebAuthenticationSupport(
                    settings,
                    WebSettingsCompat.WEB_AUTHENTICATION_SUPPORT_FOR_APP,
                )
            }
            webViewClient = AuthWebViewClient()
            webChromeClient = object : WebChromeClient() {
                override fun onProgressChanged(view: WebView?, newProgress: Int) {
                    progressBar.progress = newProgress
                    progressBar.visibility = if (newProgress in 1..99) View.VISIBLE else View.GONE
                }
            }
        }

        CookieManager.getInstance().setAcceptCookie(true)
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true)

        val toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(accent)
            setPadding(dp(8), dp(10), dp(8), dp(10))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }

        val closeButton = TextView(this).apply {
            text = getString(com.enve.app.R.string.auth_close)
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(6), dp(12), dp(6))
            setOnClickListener { finish() }
        }

        val title = TextView(this).apply {
            text = host.ifBlank { getString(com.enve.app.R.string.auth_sign_in) }
            setTextColor(Color.WHITE)
            textSize = 16f
            gravity = Gravity.CENTER
            maxLines = 1
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }

        val spacer = SpaceView(this).apply {
            layoutParams = LinearLayout.LayoutParams(closeButton.measuredWidth.takeIf { it > 0 } ?: dp(72), 1)
        }

        toolbar.addView(closeButton)
        toolbar.addView(title)
        toolbar.addView(spacer)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
            addView(toolbar)
            addView(progressBar)
            addView(webView)
        }

        // Keep the toolbar below the status bar in the edge-to-edge app theme.
        androidx.core.view.ViewCompat.setOnApplyWindowInsetsListener(toolbar) { v, insets ->
            val top = insets.getInsets(androidx.core.view.WindowInsetsCompat.Type.statusBars()).top
            v.setPadding(v.paddingLeft, dp(10) + top, v.paddingRight, v.paddingBottom)
            insets
        }

        setContentView(root)
    }

    private fun handleUrl(uri: Uri): Boolean {
        markCookieAuthNavigation(uri)
        if (isAuthCallback(uri)) {
            // Carry the origin through the callback in case ViewModel state was reset.
            val enrichedUri = if (originServerUrl.isNotBlank() && uri.getQueryParameter("server").isNullOrBlank()) {
                uri.buildUpon().appendQueryParameter("server", originServerUrl).build()
            } else {
                uri
            }
            val callbackIntent = Intent(this, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                data = enrichedUri
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            }
            startActivity(callbackIntent)
            finish()
            return true
        }

        val scheme = uri.scheme.orEmpty().lowercase()
        if (scheme == "http" || scheme == "https") {
            return false
        }

        runCatching {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
            finish()
        }
        return true
    }

    private fun markCookieAuthNavigation(uri: Uri) {
        if (!requireOriginReturnBeforeCookie) return
        if (!isSameOrigin(uri) || isCookieAuthCallback(uri)) {
            hasLeftOriginForCookieAuth = true
        }
    }

    private fun isReturnedFromCookieAuth(currentUrl: String?): Boolean {
        val uri = currentUrl?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return false
        markCookieAuthNavigation(uri)
        return hasLeftOriginForCookieAuth &&
            isSameOrigin(uri) &&
            !isCookieAuthStart(uri) &&
            !isCookieAuthCallback(uri)
    }

    private fun isSameOrigin(uri: Uri): Boolean {
        val origin = runCatching { Uri.parse(originServerUrl) }.getOrNull() ?: return false
        return uri.scheme.equals(origin.scheme, ignoreCase = true) &&
            uri.host.equals(origin.host, ignoreCase = true) &&
            uri.port == origin.port
    }

    private fun isCookieAuthStart(uri: Uri): Boolean {
        val path = uri.path.orEmpty().trimEnd('/').lowercase()
        return path.contains("/oauth2/authorization") ||
            path.contains("/login/oauth2/authorization")
    }

    private fun isCookieAuthCallback(uri: Uri): Boolean {
        return uri.path.orEmpty().lowercase().contains("/login/oauth2/code")
    }

    private fun isAuthCallback(uri: Uri): Boolean {
        val scheme = uri.scheme.orEmpty().lowercase()
        val host = uri.host.orEmpty().lowercase()
        val path = uri.path.orEmpty().lowercase()
        if (scheme == "storyteller") return true
        if (scheme == "audiobookshelf" && host == "oauth") return true
        if (scheme == "grimmory" || scheme == "booklore") return true
        if (path.contains("oauth2-callback")) return true
        return host == "auth-callback" || path.contains("auth-callback")
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private fun sanitizeWebViewUserAgent(default: String): String {
        // Remove WebView markers rejected by Google's embedded-browser check.
        return default
            .replace("; wv)", ")")
            .replace(" wv ", " ")
            .replace("Version/[\\d.]+ Chrome".toRegex(), "Chrome")
    }

    private inner class AuthWebViewClient : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            return request?.url?.let(::handleUrl) ?: false
        }

        @Deprecated("Deprecated in Java")
        override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
            return url?.let { handleUrl(Uri.parse(it)) } ?: false
        }

        override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
            // Some JavaScript-driven redirects bypass shouldOverrideUrlLoading.
            if (url != null && handleUrl(Uri.parse(url))) {
                view?.stopLoading()
            }
        }

        override fun onPageFinished(view: WebView?, url: String?) {
            // Complete Cloudflare Access authentication as soon as its cookie arrives.
            checkRequiredCookie(url)
        }

        override fun onReceivedError(
            view: WebView?,
            request: WebResourceRequest?,
            error: android.webkit.WebResourceError?,
        ) {
            val uri = request?.url ?: return
            if (request.isForMainFrame && handleUrl(uri)) {
                view?.stopLoading()
            }
        }

        override fun onReceivedHttpError(
            view: WebView?,
            request: WebResourceRequest?,
            errorResponse: WebResourceResponse?,
        ) {
            // Replace only main-frame authentication failures with the fallback page.
            if (request?.isForMainFrame == true) {
                val code = errorResponse?.statusCode ?: 0
                if (code in 400..599) {
                    val html = buildString {
                        append("<html><body style='font-family:sans-serif;padding:24px;text-align:center;'>")
                        append("<h2 style='color:#555;'>Web login unavailable</h2>")
                        append("<p style='color:#777;'>This server returned HTTP $code for the login page.")
                        append(" It may not have SSO/web login configured.</p>")
                        append("<p style='color:#777;'>Close this window and use the <b>Credentials</b> tab to sign in with your username and password.</p>")
                        append("</body></html>")
                    }
                    view?.loadDataWithBaseURL(null, html, "text/html", "UTF-8", null)
                }
            }
        }
    }

    companion object {
        private const val EXTRA_URL = "com.enve.app.extra.AUTH_BROWSER_URL"
        private const val EXTRA_ACCENT = "com.enve.app.extra.AUTH_BROWSER_ACCENT"
        // Finish successfully once the expected host cookie appears.
        private const val EXTRA_REQUIRED_COOKIE = "com.enve.app.extra.AUTH_REQUIRED_COOKIE"
        private const val EXTRA_REQUIRE_ORIGIN_RETURN_BEFORE_COOKIE = "com.enve.app.extra.AUTH_REQUIRE_ORIGIN_RETURN_BEFORE_COOKIE"
        const val EXTRA_RESULT_COOKIE = "com.enve.app.extra.AUTH_RESULT_COOKIE"
        private const val DEFAULT_ACCENT = 0xFF6C7AE0.toInt()

        fun createIntent(
            context: Context,
            url: String,
            accent: Int,
            requiredCookie: String? = null,
            requireOriginReturnBeforeCookie: Boolean = false,
        ): Intent {
            return Intent(context, AuthBrowserActivity::class.java).apply {
                putExtra(EXTRA_URL, url)
                putExtra(EXTRA_ACCENT, accent)
                putExtra(EXTRA_REQUIRE_ORIGIN_RETURN_BEFORE_COOKIE, requireOriginReturnBeforeCookie)
                if (!requiredCookie.isNullOrBlank()) {
                    putExtra(EXTRA_REQUIRED_COOKIE, requiredCookie)
                }
                if (context !is Activity) {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            }
        }
    }
}

private class SpaceView(context: Context) : View(context)
