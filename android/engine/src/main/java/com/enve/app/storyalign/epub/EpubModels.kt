package com.enve.app.storyalign.epub

object EpubMediaTypes {
    const val XHTML_XML = "application/xhtml+xml"
    const val NCX_XML = "application/x-dtbncx+xml"
}

object AssetPaths {
    const val ROOT = "storyalign"
    const val STYLES = "$ROOT/Styles"
    const val AUDIO = "$ROOT/Audio"
    const val MEDIA_OVERLAYS = "$ROOT/MediaOverlays"
    const val NAV = "$ROOT/nav.xhtml"
}

enum class EpubChapterRole(val raw: String) {
    FRONTMATTER("frontmatter"),
    BODYMATTER("bodymatter"),
    BACKMATTER("backmatter"),
    COVER("cover"),
    TITLEPAGE("titlepage"),
    COPYRIGHTPAGE("copyright-page"),
    TOC("toc"),
    UNLISTED("unlisted");

    companion object {
        fun fromRaw(raw: String): EpubChapterRole? = entries.firstOrNull { it.raw == raw }
    }
}

data class EpubMetaInfo(
    var title: String? = null,
    var creator: String? = null,
    var language: String? = null,
    var identifier: String? = null,
    var date: String? = null,
    var publisher: String? = null,
    var subject: String? = null,
    var version: String? = null,
) {
    val isEpub2: Boolean
        get() = version?.trim()?.startsWith("2.") == true
}

data class OpfManifestItem(
    val id: String,
    val href: String,
    val mediaType: String?,
    val properties: List<String>?,
)

data class EpubSpineItem(
    val idref: String,
    val id: String?,
    val index: Int,
)

class EpubSpine(
    val toc: String,
    val items: List<EpubSpineItem>,
) {
    private val itemsByIdref: Map<String, EpubSpineItem> = items.associateBy { it.idref }
    fun contains(manifestItemId: String): Boolean = itemsByIdref.containsKey(manifestItemId)
    fun item(forIdRef: String): EpubSpineItem? = itemsByIdref[forIdRef]
    fun index(forIdRef: String): Int? = itemsByIdref[forIdRef]?.index
}

data class EpubGuideItem(
    val type: String,
    val title: String?,
    val href: String,
)

data class EpubTocEntry(
    val href: String,
    val title: String,
)

data class EpubLandmark(
    val href: String,
    val role: EpubChapterRole,
)

data class NcxNavPoint(
    var label: String = "",
    var src: String? = null,
    val children: MutableList<NcxNavPoint> = mutableListOf(),
)

data class EpubChapterEntry(
    val manifestId: String,
    val navLabel: String,
    val spineItemIndex: Int,
    val role: EpubChapterRole?,
)

interface EpubNavOrNcx {
    val toc: List<EpubTocEntry>
    val tocFileHref: String
    val tocDict: Map<String, String>
    val landmarks: List<EpubLandmark>

    fun title(forHref: String): String? {
        tocDict[forHref]?.let { return it }
        if (forHref.deletingLastPathComponent() == tocFileHref.deletingLastPathComponent()) {
            val last = forHref.lastPathComponent()
            tocDict[last]?.let { return it }
            tocDict[last.removingFragment()]?.let { return it }
        }
        return null
    }

    fun role(forHref: String): EpubChapterRole? =
        landmarks.firstOrNull { it.href == forHref }?.role

    companion object {
        fun buildTocDict(toc: List<EpubTocEntry>): Map<String, String> {
            val result = LinkedHashMap<String, String>()
            for (entry in toc) {
                if (!result.containsKey(entry.href)) result[entry.href] = entry.title
                val fragless = entry.href.removingFragment()
                if (fragless != entry.href && !result.containsKey(fragless)) result[fragless] = entry.title
            }
            return result
        }
    }
}

class EpubNav(
    override val tocFileHref: String,
    override val landmarks: List<EpubLandmark>,
    override val toc: List<EpubTocEntry>,
) : EpubNavOrNcx {
    override val tocDict: Map<String, String> = EpubNavOrNcx.buildTocDict(toc)
}

class Epub2Ncx(
    val docTitle: String,
    val navPoints: List<NcxNavPoint>,
    override val tocFileHref: String,
    val ncxId: String,
) : EpubNavOrNcx {
    override val toc: List<EpubTocEntry> = navPoints.mapNotNull { np ->
        np.src?.let { EpubTocEntry(href = it, title = np.label) }
    }
    override val tocDict: Map<String, String> = EpubNavOrNcx.buildTocDict(toc)
    override val landmarks: List<EpubLandmark> = emptyList()
}

data class EpubManifestItem(
    val id: String,
    val href: String,
    val mediaType: String?,
    val properties: List<String>?,
    val spineItemIndex: Int,
    val text: String?,
    val hasScript: Boolean,
    val xhtmlSentences: List<String>,
    val name: String,
    val xhtml: String?,
)

class EpubDocument(
    val opfPath: String,
    val metaInfo: EpubMetaInfo,
    val guide: List<EpubGuideItem>,
    val manifest: List<EpubManifestItem>,
    val spine: EpubSpine,
    val nav: EpubNav?,
    val ncx: Epub2Ncx?,
    val resources: List<String>,
) {
    val isEpub2: Boolean get() = metaInfo.isEpub2

    val spineOrderedManifest: List<EpubManifestItem>
        get() = manifest.filter { it.spineItemIndex >= 0 }.sortedBy { it.spineItemIndex }

    fun bodymatterHrefs(): List<String> =
        nav?.landmarks.orEmpty().filter { it.role == EpubChapterRole.BODYMATTER }.map { it.href }
}
