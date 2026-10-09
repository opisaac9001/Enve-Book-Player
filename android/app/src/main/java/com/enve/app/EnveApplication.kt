package com.enve.app

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Process
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import coil.ImageLoader
import coil.ImageLoaderFactory
import com.enve.app.diagnostics.CrashLogger
import com.enve.app.playback.AudiobookDownloadWorker
import com.enve.app.readium.ReadiumManager
import com.enve.app.storyalign.StoryAlignWorker
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

@HiltAndroidApp
class EnveApplication : Application(), ImageLoaderFactory, Configuration.Provider {

    val readiumManager: ReadiumManager by lazy { ReadiumManager(this) }

    val imageLoader: ImageLoader by lazy { ImageLoader.Builder(this).build() }

    @Inject
    lateinit var profiles: com.enve.app.profiles.ProfileSwitchCoordinator

    @Inject
    lateinit var bookWidgetPublisher: com.enve.app.widgets.BookWidgetPublisher

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()

    override fun onCreate() {
        super.onCreate()
        if (isLibrarianModelProcess()) {
            CrashLogger.install(this)
            return
        }

        runCatching {
            android.webkit.WebView(this).destroy()
        }
        androidx.lifecycle.ProcessLifecycleOwner.get().lifecycle.addObserver(object : androidx.lifecycle.DefaultLifecycleObserver {
            override fun onStop(owner: androidx.lifecycle.LifecycleOwner) {
                profiles.onBackground()
            }
        })
        createDownloadNotificationChannel()
        createStoryAlignNotificationChannel()

        CrashLogger.install(this)

        runCatching {
            val field = android.database.CursorWindow::class.java.getDeclaredField("sCursorWindowSize")
            field.isAccessible = true
            field.set(null, 50 * 1024 * 1024)
        }

        Thread {
            runCatching {
                val availability = com.google.android.gms.common.GoogleApiAvailability.getInstance()
                if (availability.isGooglePlayServicesAvailable(this) ==
                    com.google.android.gms.common.ConnectionResult.SUCCESS
                ) {
                    com.google.android.gms.cast.framework.CastContext.getSharedInstance(this)
                }
            }
        }.start()
    }

    override fun newImageLoader(): ImageLoader = imageLoader

    private fun createDownloadNotificationChannel() {
        val channel = NotificationChannel(
            AudiobookDownloadWorker.CHANNEL_ID,
            getString(R.string.download_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { setShowBadge(false) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun createStoryAlignNotificationChannel() {
        val channel = NotificationChannel(
            StoryAlignWorker.CHANNEL_ID,
            getString(R.string.storyalign_notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply { setShowBadge(false) }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun isLibrarianModelProcess(): Boolean {
        val processName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            getProcessName()
        } else {
            val pid = Process.myPid()
            val manager = getSystemService(android.app.ActivityManager::class.java)
            manager?.runningAppProcesses?.firstOrNull { it.pid == pid }?.processName
        }
        return processName?.endsWith(":librarian_model") == true
    }
}
