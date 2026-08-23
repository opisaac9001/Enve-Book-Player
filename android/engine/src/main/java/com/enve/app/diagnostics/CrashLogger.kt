package com.enve.app.diagnostics

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import androidx.core.content.pm.PackageInfoCompat
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object CrashLogger {
    private const val MAX_FILES = 20
    private val timestamp = SimpleDateFormat("yyyy-MM-dd_HH-mm-ss", Locale.US)

    private var buildLine = "Build: unknown"
    private var appIdLine = "Application id: unknown"

    fun install(context: Context) {
        val appContext = context.applicationContext
        captureBuildInfo(appContext)
        val crashDir = File(appContext.filesDir, "crashes").apply { mkdirs() }
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeCrashFile(crashDir, thread, throwable)
                pruneOldFiles(crashDir)
            } catch (_: Throwable) {

            }
            previous?.uncaughtException(thread, throwable)
        }
    }

    fun listCrashes(context: Context): List<File> {
        val dir = File(context.filesDir, "crashes")
        if (!dir.exists()) return emptyList()
        return dir.listFiles().orEmpty()
            .sortedByDescending { it.lastModified() }
    }

    fun clearAll(context: Context) {
        val dir = File(context.filesDir, "crashes")
        if (dir.exists()) dir.listFiles()?.forEach { it.delete() }
    }

    @Suppress("DEPRECATION")
    private fun writeCrashFile(dir: File, thread: Thread, throwable: Throwable) {
        val stackTrace = StringWriter().apply { throwable.printStackTrace(PrintWriter(this)) }.toString()
        val now = Date()
        val name = "crash_${timestamp.format(now)}.txt"
        val body = buildString {
            appendLine("─── Enve crash ${timestamp.format(now)} ───")
            appendLine(buildLine)
            appendLine(appIdLine)
            appendLine("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
            appendLine("Device: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.PRODUCT})")
            appendLine("Thread: ${thread.name} (id=${thread.id}, priority=${thread.priority})")
            appendLine()
            appendLine(stackTrace)
        }
        File(dir, name).writeText(body)
    }

    private fun captureBuildInfo(appContext: Context) {
        runCatching {
            val pkg = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
            val code = PackageInfoCompat.getLongVersionCode(pkg)
            val debuggable = (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            buildLine = "Build: ${pkg.versionName} ($code) ${if (debuggable) "debug" else "release"}"
            appIdLine = "Application id: ${appContext.packageName}"
        }
    }

    private fun pruneOldFiles(dir: File) {
        val files = dir.listFiles().orEmpty().sortedByDescending { it.lastModified() }
        if (files.size <= MAX_FILES) return
        files.drop(MAX_FILES).forEach { it.delete() }
    }
}
