package com.enve.app.sleep

import android.annotation.SuppressLint
import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity

class SleepPermissionsRationaleActivity : ComponentActivity() {
    private lateinit var policyView: WebView

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        policyView = WebView(this).apply {
            webViewClient = WebViewClient()
            settings.javaScriptEnabled = false
            settings.domStorageEnabled = false
            loadUrl(PRIVACY_POLICY_URL)
        }
        setContentView(policyView)
    }

    override fun onDestroy() {
        policyView.destroy()
        super.onDestroy()
    }

    private companion object {
        const val PRIVACY_POLICY_URL = "https://envemedia.com/privacy-policy"
    }
}
