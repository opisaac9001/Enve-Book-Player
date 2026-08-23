package com.enve.app.storyalign.epub

import com.enve.engine.storyalign.StoryAlignGranularity
import java.io.File
import java.io.InputStream
import java.util.zip.ZipInputStream

class EpubZip private constructor(private val entries: Map<String, ByteArray>) {
    fun bytes(path: String): ByteArray? = entries[path]
    fun entries(): Map<String, ByteArray> = entries

    companion object {
        fun from(input: InputStream): EpubZip {
            val map = LinkedHashMap<String, ByteArray>()
            ZipInputStream(input).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    if (!entry.isDirectory) map[entry.name] = zis.readBytes()
                    entry = zis.nextEntry
                }
            }
            return EpubZip(map)
        }

        fun from(file: File): EpubZip = file.inputStream().buffered().use { from(it) }
    }
}

object EpubParser {

    fun parse(zip: EpubZip, granularity: StoryAlignGranularity = StoryAlignGranularity.SENTENCE): EpubDocument {
        val containerBytes = zip.bytes("META-INF/container.xml")
            ?: throw StoryAlignParseException("Missing META-INF/container.xml")
        val opfPath = parseEpubContainer(containerBytes)
        val opfBytes = zip.bytes(opfPath) ?: throw StoryAlignParseException("Missing OPF at $opfPath")
        val opfDoc = parseXmlDocument(opfBytes)
        val opfDir = opfPath.deletingLastPathComponent()

        val metaInfo = parseEpubMetaInfo(opfDoc)
        val spine = parseEpubSpine(opfDoc)
        val manifestItems = parseEpubManifest(opfDoc)

        val nav = EpubOpfResolver.navManifestItem(manifestItems)?.let { navItem ->
            zip.bytes(resolvePath(opfDir, navItem.href))?.let { parseEpubNav(it, navItem.href) }
        }
        val ncx = EpubOpfResolver.ncxManifestItem(manifestItems, spine)?.let { ncxItem ->
            zip.bytes(resolvePath(opfDir, ncxItem.href))?.let { parseEpubNcx(it, ncxItem.href, ncxItem.id) }
        }

        val parseGranularity = if (granularity.useWordTokenizer) StoryAlignGranularity.SENTENCE else granularity
        val resources = LinkedHashSet<String>()

        val manifest = manifestItems.mapNotNull { item ->
            if (item.mediaType != EpubMediaTypes.XHTML_XML) return@mapNotNull null
            val path = resolvePath(opfDir, item.href)
            val bytes = zip.bytes(path)
                ?: throw StoryAlignParseException("Cannot find manifest item content: ${item.href}")
            val xhtml = String(bytes, Charsets.UTF_8)
            val (text, hasScript, itemResources) = EpubXhtmlTextParser.parseText(xhtml)
            val itemDir = path.deletingLastPathComponent()
            itemResources.forEach { resources.add(resolvePath(itemDir, it)) }
            val name = nav?.title(item.href) ?: ncx?.title(item.href) ?: item.id
            val sentences = EpubXhtmlTextParser.getXHtmlSentences(xhtml, parseGranularity)
            val spineIndex = spine.item(item.id)?.index ?: -1
            EpubManifestItem(
                id = item.id,
                href = item.href,
                mediaType = item.mediaType,
                properties = item.properties,
                spineItemIndex = spineIndex,
                text = text,
                hasScript = hasScript,
                xhtmlSentences = sentences,
                name = name,
                xhtml = xhtml,
            )
        }

        val guide = parseEpubGuide(opfDoc)
        return EpubDocument(
            opfPath = opfPath,
            metaInfo = metaInfo,
            guide = guide,
            manifest = manifest,
            spine = spine,
            nav = nav,
            ncx = ncx,
            resources = resources.toList(),
        )
    }

    fun chapterEntries(zip: EpubZip): List<EpubChapterEntry> {
        val containerBytes = zip.bytes("META-INF/container.xml") ?: return emptyList()
        val opfPath = parseEpubContainer(containerBytes)
        val opfBytes = zip.bytes(opfPath) ?: return emptyList()
        val opfDoc = parseXmlDocument(opfBytes)
        val opfDir = opfPath.deletingLastPathComponent()
        val spine = parseEpubSpine(opfDoc)
        val manifestItems = parseEpubManifest(opfDoc)
        val manifestById = manifestItems.associateBy { it.id }

        fun chapters(toc: EpubNavOrNcx): List<EpubChapterEntry> =
            spine.items.mapIndexedNotNull { index, spineItem ->
                val m = manifestById[spineItem.idref] ?: return@mapIndexedNotNull null
                val title = toc.title(m.href)
                val role = toc.role(m.href) ?: if (title == null) EpubChapterRole.UNLISTED else null
                EpubChapterEntry(
                    manifestId = spineItem.idref,
                    navLabel = title ?: spineItem.idref,
                    spineItemIndex = index,
                    role = role,
                )
            }

        EpubOpfResolver.navManifestItem(manifestItems)?.let { navItem ->
            zip.bytes(resolvePath(opfDir, navItem.href))?.let { return chapters(parseEpubNav(it, navItem.href)) }
        }
        EpubOpfResolver.ncxManifestItem(manifestItems, spine)?.let { ncxItem ->
            zip.bytes(resolvePath(opfDir, ncxItem.href))?.let { return chapters(parseEpubNcx(it, ncxItem.href, ncxItem.id)) }
        }
        return emptyList()
    }
}
