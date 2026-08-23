package com.enve.app.ui.screens

import com.enve.app.data.reader.CustomFont
import com.enve.app.data.repository.CustomFontRepository
import java.io.File
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.data.Container
import org.readium.r2.shared.util.file.FileResource
import org.readium.r2.shared.util.mediatype.MediaType
import org.readium.r2.shared.util.resource.Resource

internal class ReadiumCustomFontResources(fonts: List<CustomFont>) : Container<Resource> {
    private data class Key(val fontId: String, val variant: CustomFontRepository.Variant)
    private data class Entry(val relativeUrl: Url, val sourceUrl: Url, val file: File, val mediaType: MediaType)

    private val entriesByKey: Map<Key, Entry> = buildMap {
        fonts.forEach { font ->
            add(font, CustomFontRepository.Variant.REGULAR, font.regularPath)
            add(font, CustomFontRepository.Variant.BOLD, font.boldPath)
            add(font, CustomFontRepository.Variant.ITALIC, font.italicPath)
            add(font, CustomFontRepository.Variant.BOLD_ITALIC, font.boldItalicPath)
        }
    }
    private val entriesByUrl = entriesByKey.values.associateBy(Entry::relativeUrl)

    override val entries: Set<Url> = entriesByUrl.keys
    val links: List<Link> = entriesByUrl.values.map { Link(it.relativeUrl, mediaType = it.mediaType) }
    val isEmpty: Boolean get() = entriesByUrl.isEmpty()

    fun sourceUrl(fontId: String, variant: CustomFontRepository.Variant): Url? =
        entriesByKey[Key(fontId, variant)]?.sourceUrl

    override fun get(url: Url): Resource? = entriesByUrl[url.removeQuery().removeFragment()]
        ?.file
        ?.let(::FileResource)

    override fun close() = Unit

    private fun MutableMap<Key, Entry>.add(
        font: CustomFont,
        variant: CustomFontRepository.Variant,
        path: String?,
    ) {
        val file = path?.let(::File)?.takeIf(File::isFile) ?: return
        val extension = file.extension.lowercase()
        val mediaType = when (extension) {
            "ttf" -> TTF_MEDIA_TYPE
            "otf" -> OTF_MEDIA_TYPE
            else -> return
        }
        val relativeUrl = requireNotNull(
            Url.fromDecodedPath("$RESOURCE_ROOT/${font.id}/${variant.resourceName}.$extension"),
        )
        put(
            Key(font.id, variant),
            Entry(
                relativeUrl = relativeUrl,
                sourceUrl = PUBLICATION_BASE_URL.resolve(relativeUrl),
                file = file,
                mediaType = mediaType,
            ),
        )
    }

    private val CustomFontRepository.Variant.resourceName: String
        get() = when (this) {
            CustomFontRepository.Variant.REGULAR -> "regular"
            CustomFontRepository.Variant.BOLD -> "bold"
            CustomFontRepository.Variant.ITALIC -> "italic"
            CustomFontRepository.Variant.BOLD_ITALIC -> "bold-italic"
        }

    private companion object {
        const val RESOURCE_ROOT = "enve-reader-fonts"
        val PUBLICATION_BASE_URL = requireNotNull(Url("https://readium/publication/"))
        val TTF_MEDIA_TYPE = requireNotNull(MediaType("font/ttf"))
        val OTF_MEDIA_TYPE = requireNotNull(MediaType("font/otf"))
    }
}
