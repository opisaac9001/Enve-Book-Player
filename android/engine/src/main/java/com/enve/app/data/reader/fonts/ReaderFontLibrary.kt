package com.enve.app.data.reader.fonts

import com.enve.app.data.reader.CustomFont
import com.enve.app.data.repository.CustomFontRepository
import com.enve.app.data.repository.CustomFontRepository.Variant
import com.enve.app.data.repository.MAX_CUSTOM_FONT_BYTES
import com.enve.app.data.repository.copyFontBounded
import com.enve.app.data.repository.validatedCustomFontExtension
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.ResponseBody
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReaderFontLibrary @Inject constructor(
    @RefreshClient private val client: OkHttpClient,
    private val repository: CustomFontRepository,
    private val locations: ProfileStorageLocations,
) {
    private val facesByDirectory = ConcurrentHashMap<String, Map<Variant, String>>()

    suspend fun preview(family: ReaderFontFamily): Result<File> = resultOf {
        val regular = faces(family).getValue(Variant.REGULAR)
        cachedPreview(family, regular)
            ?: download(family, regular, previewFile(family, regular)).also { prunePreviews() }
    }

    suspend fun install(family: ReaderFontFamily): Result<CustomFont> = resultOf {
        val staging = File(locations.cacheDirectory, "$STAGING_DIRECTORY/${family.directory}-${System.nanoTime()}")
        try {
            val faces = faces(family)
            val files = faces.values.distinct().associateWith { filename ->
                cachedPreview(family, filename) ?: download(family, filename, File(staging, filename))
            }
            repository.installFamily(family.name, faces.mapValues { (_, filename) -> files.getValue(filename) })
                .getOrThrow()
        } finally {
            staging.deleteRecursively()
        }
    }

    private suspend fun faces(family: ReaderFontFamily): Map<Variant, String> =
        facesByDirectory[family.directory] ?: run {
            val text = fetch(ReaderFontCatalog.metadataUrl(family)) { body ->
                val source = body.source()
                check(!source.request(MAX_METADATA_BYTES + 1)) { "Font details for ${family.name} were unexpectedly large" }
                source.buffer.readUtf8()
            }
            ReaderFontCatalog.resolveFaces(ReaderFontCatalog.parseMetadata(text))
                .takeIf { Variant.REGULAR in it }
                ?.also { facesByDirectory[family.directory] = it }
                ?: error("${family.name} has no downloadable regular style")
        }

    private suspend fun download(family: ReaderFontFamily, filename: String, destination: File): File {
        val directory = requireNotNull(destination.parentFile).apply { mkdirs() }
        val partial = File(directory, "${destination.name}.part")
        try {
            fetch(ReaderFontCatalog.fileUrl(family, filename)) { body ->
                require(body.contentLength() <= MAX_CUSTOM_FONT_BYTES) { "${family.name} is larger than 16 MB" }
                partial.outputStream().use { output -> body.byteStream().copyFontBounded(output) }
            }
            validatedCustomFontExtension(partial)
                ?: error("${family.name} did not download as a valid TrueType or OpenType font")
            destination.delete()
            check(partial.renameTo(destination)) { "Couldn't save ${family.name}" }
            return destination
        } finally {
            partial.delete()
        }
    }

    private suspend fun <T> fetch(url: HttpUrl, read: (ResponseBody) -> T): T = coroutineScope {
        val call = client.newCall(Request.Builder().url(url).build())
        val cancelOnAbort = launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                awaitCancellation()
            } finally {
                call.cancel()
            }
        }
        try {
            call.execute().use { response ->
                check(response.isSuccessful) { "Google Fonts returned HTTP ${response.code}" }
                read(requireNotNull(response.body) { "Google Fonts returned an empty response" })
            }
        } finally {
            cancelOnAbort.cancel()
        }
    }

    private fun previewFile(family: ReaderFontFamily, filename: String): File =
        File(locations.cacheDirectory, "$PREVIEW_DIRECTORY/${family.directory}/$filename")

    private fun cachedPreview(family: ReaderFontFamily, filename: String): File? =
        previewFile(family, filename).takeIf { it.isFile && validatedCustomFontExtension(it) != null }

    private fun prunePreviews() {
        File(locations.cacheDirectory, PREVIEW_DIRECTORY)
            .walkBottomUp()
            .filter(File::isFile)
            .sortedByDescending(File::lastModified)
            .drop(MAX_CACHED_PREVIEWS)
            .forEach(File::delete)
    }

    private suspend fun <T> resultOf(block: suspend () -> T): Result<T> = withContext(Dispatchers.IO) {
        try {
            Result.success(block())
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private companion object {
        const val PREVIEW_DIRECTORY = "reader-font-previews"
        const val STAGING_DIRECTORY = "reader-font-downloads"
        const val MAX_CACHED_PREVIEWS = 8
        const val MAX_METADATA_BYTES = 512L * 1024
    }
}
