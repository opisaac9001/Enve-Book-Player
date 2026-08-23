package com.enve.app

import android.content.Intent
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class OAuthCallbackIntentFilterTest {
    @Test
    fun oauthCallbacksResolveToMainActivity() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val callbacks = listOf(
            "grimmory://oauth2-callback?code=test&state=test",
            "booklore://oauth2-callback?code=test&state=test",
            "audiobookshelf://oauth?code=test&state=test",
            "storyteller://auth-callback?token=test",
            "enve://auth-callback?token=test",
            "enve://plex-return",
        )

        callbacks.forEach { callback ->
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(callback)).apply {
                addCategory(Intent.CATEGORY_BROWSABLE)
                setPackage(context.packageName)
            }
            val activity = context.packageManager.resolveActivity(intent, 0)

            assertEquals(MainActivity::class.java.name, activity?.activityInfo?.name)
        }
    }
}
