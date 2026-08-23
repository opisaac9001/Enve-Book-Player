package com.enve.local

import com.enve.core.data.model.Book
import com.enve.core.data.provider.ProviderMetadataUpdate
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class LocalBookMetadataSidecar(
    val version: Int = 1,
    val fileName: String,
    val updatedAt: Long,
    val metadata: LocalBookSidecarMetadata,
)

@Serializable
data class LocalBookSidecarMetadata(
    val title: String,
    val subtitle: String? = null,
    val author: String? = null,
    val narrator: String? = null,
    val description: String? = null,
    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val publisher: String? = null,
    val publishedDate: String? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val pageCount: Int? = null,
    val categories: List<String> = emptyList(),
)

object LocalBookSidecarCodec {
    private val json = Json {
        encodeDefaults = true
        ignoreUnknownKeys = true
        prettyPrint = true
    }

    fun sidecarName(fileName: String): String = "$fileName.enve.json"

    fun encode(
        fileName: String,
        metadata: ProviderMetadataUpdate,
        updatedAt: Long = System.currentTimeMillis(),
    ): String = json.encodeToString(
        LocalBookMetadataSidecar(
            fileName = fileName,
            updatedAt = updatedAt,
            metadata = metadata.toSidecarMetadata(),
        )
    )

    fun decode(text: String): LocalBookMetadataSidecar =
        json.decodeFromString(LocalBookMetadataSidecar.serializer(), text)

    fun apply(book: Book, sidecar: LocalBookMetadataSidecar): Book {
        val metadata = sidecar.metadata
        return book.copy(
            title = metadata.title.takeIf { it.isNotBlank() } ?: book.title,
            subtitle = metadata.subtitle,
            author = metadata.author,
            narrator = metadata.narrator,
            description = metadata.description,
            seriesName = metadata.seriesName,
            seriesNumber = metadata.seriesNumber,
            publisher = metadata.publisher,
            publishedDate = metadata.publishedDate,
            isbn13 = metadata.isbn13,
            language = metadata.language,
            pageCount = metadata.pageCount,
            categories = metadata.categories,
        )
    }

    private fun ProviderMetadataUpdate.toSidecarMetadata(): LocalBookSidecarMetadata =
        LocalBookSidecarMetadata(
            title = title,
            subtitle = subtitle,
            author = author,
            narrator = narrator,
            description = description,
            seriesName = seriesName,
            seriesNumber = seriesNumber,
            publisher = publisher,
            publishedDate = publishedDate,
            isbn13 = isbn13,
            language = language,
            pageCount = pageCount,
            categories = categories,
        )
}
