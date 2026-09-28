package com.enve.app.ui.auth

import android.annotation.SuppressLint
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.viewModels
import androidx.lifecycle.ViewModel
import androidx.lifecycle.lifecycleScope
import com.enve.app.data.opds.OPDS_IMPLICIT_REDIRECT_URI
import com.enve.app.data.opds.buildOpdsImplicitAuthorizeUrl
import com.enve.app.data.opds.isOpdsImplicitRedirect
import com.enve.app.data.opds.newOpdsImplicitState
import com.enve.app.data.repository.isHttpUrl
import com.enve.engine.opds.OpdsAuthMethodKind
import com.enve.engine.opds.OpdsAuthMethodState
import com.enve.engine.opds.OpdsCatalogFacade
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.launch
import javax.inject.Inject

class OpdsImplicitFlowViewModel : ViewModel() {
    val state: String = newOpdsImplicitState()

    @Volatile
    var completed: Boolean = false
}

@AndroidEntryPoint
class OpdsAuthBrowserActivity : ComponentActivity() {

    @Inject
    lateinit var catalog: OpdsCatalogFacade

    private val flow: OpdsImplicitFlowViewModel by viewModels()

    private var webView: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID).orEmpty()
        val methodType = intent.getStringExtra(EXTRA_METHOD_TYPE).orEmpty()
        val authorizeUrl = intent.getStringExtra(EXTRA_AUTHORIZE_URL).orEmpty()
        val startUrl = buildOpdsImplicitAuthorizeUrl(authorizeUrl, OPDS_IMPLICIT_REDIRECT_URI, flow.state)
        if (connectionId.isBlank() || startUrl == null) {
            finish()
            return
        }

        val method = OpdsAuthMethodState(
            kind = OpdsAuthMethodKind.OAUTH_IMPLICIT,
            type = methodType,
            loginLabel = null,
            passwordLabel = null,
            authorizeUrl = authorizeUrl,
        )

        val view = WebView(this).apply {
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView?,
                    request: WebResourceRequest?,
                ): Boolean {
                    val url = request?.url?.toString() ?: return false
                    if (isHttpUrl(url)) return false
                    if (request.isForMainFrame && isOpdsImplicitRedirect(url, OPDS_IMPLICIT_REDIRECT_URI)) {
                        complete(connectionId, method, url)
                    }
                    return true
                }
            }
        }
        webView = view
        setContentView(view)
        view.loadUrl(startUrl)
    }

    override fun onDestroy() {
        webView?.let { view ->
            (view.parent as? ViewGroup)?.removeView(view)
            view.stopLoading()
            view.webViewClient = WebViewClient()
            view.destroy()
        }
        webView = null
        super.onDestroy()
    }

    private fun complete(connectionId: String, method: OpdsAuthMethodState, redirectUrl: String) {
        if (flow.completed) return
        flow.completed = true
        lifecycleScope.launch {
            catalog.completeImplicitSignIn(connectionId, method, redirectUrl, flow.state)
            finish()
        }
    }

    companion object {
        const val EXTRA_CONNECTION_ID = "opds_connection_id"
        const val EXTRA_METHOD_TYPE = "opds_method_type"
        const val EXTRA_AUTHORIZE_URL = "opds_authorize_url"
    }
}
