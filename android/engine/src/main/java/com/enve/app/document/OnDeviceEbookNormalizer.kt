package com.enve.app.document

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

enum class EbookSourceFormat(val extension: String, val displayName: String) {
    EPUB("epub", "EPUB"),
    READALOUD("epub", "Read Aloud"),
    MOBI("mobi", "MOBI"),
    AZW("azw", "AZW"),
    AZW3("azw3", "AZW3"),
    FB2("fb2", "FB2"),
    UNKNOWN("book", "book"),
    ;

    val isKindleFamily: Boolean
        get() = this == MOBI || this == AZW || this == AZW3

    companion object {
        fun fromServerType(value: String?): EbookSourceFormat = when (value?.uppercase(Locale.US)) {
            "EPUB" -> EPUB
            "READALOUD", "READ_ALOUD", "READ-ALOUD" -> READALOUD
            "MOBI" -> MOBI
            "AZW" -> AZW
            "AZW3" -> AZW3
            "FB2" -> FB2
            else -> UNKNOWN
        }
    }
}

class EbookNormalizationException(message: String, cause: Throwable? = null) : Exception(message, cause)

interface KindleEpubConverter {
    suspend fun convertToEpub(source: File, destination: File): File
}

class OnDeviceEbookNormalizer(
    private val kindleConverter: KindleEpubConverter? = null,
) {
    suspend fun normalizeToEpub(
        source: File,
        format: EbookSourceFormat,
        outputDir: File,
        outputName: String,
    ): File = withContext(Dispatchers.IO) {
        outputDir.mkdirs()
        val normalized = File(outputDir, "$outputName.epub")

        if (normalized.exists() && normalized.length() > 0L) {
            val sourceFresh = source.exists() && source.lastModified() > normalized.lastModified()
            if (!sourceFresh) return@withContext normalized
        }

        when (format) {
            EbookSourceFormat.EPUB -> {
                if (source != normalized) source.copyTo(normalized, overwrite = true)
                normalized
            }
            EbookSourceFormat.READALOUD -> {
                if (source != normalized) source.copyTo(normalized, overwrite = true)
                normalized
            }
            EbookSourceFormat.MOBI,
            EbookSourceFormat.AZW,
            EbookSourceFormat.AZW3 -> {
                val converter = kindleConverter ?: throw EbookNormalizationException(
                    "On-device ${format.displayName} conversion requires the native libmobi converter module."
                )
                converter.convertToEpub(source, normalized)
            }
            EbookSourceFormat.FB2 -> throw EbookNormalizationException(
                "On-device FB2 conversion is not bundled yet."
            )
            EbookSourceFormat.UNKNOWN -> throw EbookNormalizationException(
                "Unknown ebook format."
            )
        }
    }
}
