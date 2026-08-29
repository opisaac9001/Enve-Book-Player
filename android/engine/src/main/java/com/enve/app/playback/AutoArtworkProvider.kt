package com.enve.app.playback

import android.Manifest
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.File

class AutoArtworkProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String? =
        uri.lastPathSegment?.takeIf(FILE_NAME_PATTERN::matches)?.let { "image/jpeg" }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        require(mode == "r") { "Artwork is read-only" }
        requireCallerCanRead()
        val fileName = requireNotNull(uri.lastPathSegment?.takeIf(FILE_NAME_PATTERN::matches)) {
            "Invalid artwork path"
        }
        val cacheDirectory = File(requireNotNull(context).cacheDir, CACHE_DIRECTORY).canonicalFile
        val artwork = File(cacheDirectory, fileName).canonicalFile
        require(artwork.parentFile == cacheDirectory && artwork.isFile) { "Artwork not found" }
        return ParcelFileDescriptor.open(artwork, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun requireCallerCanRead() {
        val providerContext = requireNotNull(context)
        val callingUid = Binder.getCallingUid()
        if (callingUid == Process.myUid()) return
        if (
            providerContext.checkPermission(
                Manifest.permission.MEDIA_CONTENT_CONTROL,
                Binder.getCallingPid(),
                callingUid,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return
        }

        val packageManager = providerContext.packageManager
        val packages = packageManager.getPackagesForUid(callingUid).orEmpty()
        val debuggable = providerContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0
        if (debuggable && CarControllerPackages.MEDIA_SIMULATOR in packages) return
        if (packages.any { packageName ->
                packageName in CarControllerPackages.HOSTS && packageManager.isSystemPackage(packageName)
            }
        ) {
            return
        }
        throw SecurityException("Caller cannot read Android Auto artwork")
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    companion object {
        const val CACHE_DIRECTORY = "android_auto_artwork"
        private val FILE_NAME_PATTERN = Regex("[0-9a-f]{64}\\.jpg")

        fun uriFor(context: Context, fileName: String): Uri = Uri.Builder()
            .scheme("content")
            .authority("${context.packageName}.auto-artwork")
            .appendPath(fileName)
            .build()
    }
}

private fun PackageManager.isSystemPackage(packageName: String): Boolean {
    val flags = getApplicationInfo(packageName, 0).flags
    return flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0
}
