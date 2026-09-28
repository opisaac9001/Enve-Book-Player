package com.enve.app

import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.ui.auth.AuthBrowserActivity
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AuthBrowserCallbackTest {
    @Test
    fun cookieLoginKeepsServerRedirectsInBrowser() {
        androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val browser = AuthBrowserActivity()
            val cookie = AuthBrowserActivity::class.java.getDeclaredField("requiredCookieName")
                .apply { isAccessible = true }
            val callback = AuthBrowserActivity::class.java.getDeclaredMethod("isAuthCallback", Uri::class.java)
                .apply { isAccessible = true }
            val serverCallback = Uri.parse("https://example.com/oauth2-callback?code=test&state=test")
            assertTrue(callback.invoke(browser, serverCallback) as Boolean)
            cookie.set(browser, "CF_Authorization")
            assertFalse(callback.invoke(browser, serverCallback) as Boolean)
            assertTrue(callback.invoke(browser, Uri.parse("grimmory://oauth2-callback?code=test&state=test")) as Boolean)
            assertTrue(callback.invoke(browser, Uri.parse("booklore://oauth2-callback?code=test&state=test")) as Boolean)
        }
    }
}
