package com.enve.app.playback

import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.HandlerThread
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaBrowser
import androidx.media3.session.SessionToken
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
@androidx.annotation.OptIn(UnstableApi::class)
class AndroidAutoColdStartTest {
    @Test
    fun carBrowserConnectsAndLoadsShelvesBeforeAppOpens() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val thread = HandlerThread("android-auto-cold-start").apply { start() }
        val handler = Handler(thread.looper)
        val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
        val browser = MediaBrowser.Builder(context, token)
            .setApplicationLooper(thread.looper)
            .buildAsync()
            .get(15, TimeUnit.SECONDS)

        try {
            val root = handler.call { browser.getLibraryRoot(null) }.get(15, TimeUnit.SECONDS).value
            assertNotNull(root)
            assertEquals(AutoMediaBrowserHelper.ROOT_ID, root!!.mediaId)

            val shelves = handler.call { browser.getChildren(root.mediaId, 0, 100, null) }
                .get(15, TimeUnit.SECONDS).value
            assertNotNull(shelves)
            assertEquals(
                listOf(
                    AutoMediaBrowserHelper.SHELF_IN_PROGRESS,
                    AutoMediaBrowserHelper.SHELF_LIBRARY,
                    AutoMediaBrowserHelper.SHELF_DOWNLOADS,
                    AutoMediaBrowserHelper.SHELF_RECENT,
                ),
                shelves!!.map { it.mediaId },
            )
        } finally {
            handler.call { browser.release() }
            thread.quitSafely()
        }
    }

    private fun <T> Handler.call(block: () -> T): T =
        FutureTask(block).also(::post).get(15, TimeUnit.SECONDS)
}
