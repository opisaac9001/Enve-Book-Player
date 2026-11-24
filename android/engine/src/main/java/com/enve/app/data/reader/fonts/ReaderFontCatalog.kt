package com.enve.app.data.reader.fonts

import com.enve.app.data.repository.CustomFontRepository.Variant
import okhttp3.HttpUrl

enum class ReaderFontCategory(val label: String) {
    SERIF("Serif"),
    SANS_SERIF("Sans serif"),
    MONOSPACE("Monospace"),
}

data class ReaderFontFamily(
    val name: String,
    val directory: String,
    val category: ReaderFontCategory,
) {
    val licenseUrl: String get() = ReaderFontCatalog.licenseUrl(this).toString()
}

internal data class ReaderFontFile(val style: String, val weight: Int, val filename: String) {
    val variable: Boolean get() = '[' in filename
}

internal data class ReaderFontAxis(val tag: String, val min: Float, val max: Float)

internal data class ReaderFontMetadata(val files: List<ReaderFontFile>, val axes: List<ReaderFontAxis>)

object ReaderFontCatalog {
    const val MAX_QUERY_LENGTH = 60

    val families: List<ReaderFontFamily> = listOf(
        ReaderFontFamily("Alegreya", "alegreya", ReaderFontCategory.SERIF),
        ReaderFontFamily("Bitter", "bitter", ReaderFontCategory.SERIF),
        ReaderFontFamily("Charis SIL", "charissil", ReaderFontCategory.SERIF),
        ReaderFontFamily("Cormorant Garamond", "cormorantgaramond", ReaderFontCategory.SERIF),
        ReaderFontFamily("Crimson Pro", "crimsonpro", ReaderFontCategory.SERIF),
        ReaderFontFamily("EB Garamond", "ebgaramond", ReaderFontCategory.SERIF),
        ReaderFontFamily("Gelasio", "gelasio", ReaderFontCategory.SERIF),
        ReaderFontFamily("Gentium Book Plus", "gentiumbookplus", ReaderFontCategory.SERIF),
        ReaderFontFamily("Libre Baskerville", "librebaskerville", ReaderFontCategory.SERIF),
        ReaderFontFamily("Libre Caslon Text", "librecaslontext", ReaderFontCategory.SERIF),
        ReaderFontFamily("Lora", "lora", ReaderFontCategory.SERIF),
        ReaderFontFamily("Merriweather", "merriweather", ReaderFontCategory.SERIF),
        ReaderFontFamily("Newsreader", "newsreader", ReaderFontCategory.SERIF),
        ReaderFontFamily("Noto Serif", "notoserif", ReaderFontCategory.SERIF),
        ReaderFontFamily("PT Serif", "ptserif", ReaderFontCategory.SERIF),
        ReaderFontFamily("Source Serif 4", "sourceserif4", ReaderFontCategory.SERIF),
        ReaderFontFamily("Spectral", "spectral", ReaderFontCategory.SERIF),
        ReaderFontFamily("Vollkorn", "vollkorn", ReaderFontCategory.SERIF),
        ReaderFontFamily("Zilla Slab", "zillaslab", ReaderFontCategory.SERIF),
        ReaderFontFamily("Andika", "andika", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Fira Sans", "firasans", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("IBM Plex Sans", "ibmplexsans", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Inter", "inter", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Lato", "lato", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Noto Sans", "notosans", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Nunito Sans", "nunitosans", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Open Sans", "opensans", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Source Sans 3", "sourcesans3", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Work Sans", "worksans", ReaderFontCategory.SANS_SERIF),
        ReaderFontFamily("Courier Prime", "courierprime", ReaderFontCategory.MONOSPACE),
        ReaderFontFamily("IBM Plex Mono", "ibmplexmono", ReaderFontCategory.MONOSPACE),
        ReaderFontFamily("JetBrains Mono", "jetbrainsmono", ReaderFontCategory.MONOSPACE),
    )

    private const val REPOSITORY_OWNER = "google"
    private const val REPOSITORY_NAME = "fonts"
    private const val REPOSITORY_BRANCH = "main"
    private const val LICENSE_DIRECTORY = "ofl"
    private const val METADATA_FILE = "METADATA.pb"
    private const val LICENSE_FILE = "OFL.txt"
    private val safeFilename = Regex("""[A-Za-z0-9][A-Za-z0-9._,\-\[\]]{0,127}\.(ttf|otf)""")

    fun search(query: String): List<ReaderFontFamily> {
        val needle = query.trim().take(MAX_QUERY_LENGTH)
        if (needle.isEmpty()) return families
        return families.filter {
            it.name.contains(needle, ignoreCase = true) || it.category.label.contains(needle, ignoreCase = true)
        }
    }

    internal fun metadataUrl(family: ReaderFontFamily): HttpUrl = rawUrl(family.directory, METADATA_FILE)

    internal fun fileUrl(family: ReaderFontFamily, filename: String): HttpUrl {
        require(isSafeFilename(filename)) { "Unexpected font file name" }
        return rawUrl(family.directory, filename)
    }

    internal fun isSafeFilename(filename: String): Boolean =
        safeFilename.matches(filename) && ".." !in filename

    internal fun licenseUrl(family: ReaderFontFamily): HttpUrl = HttpUrl.Builder()
        .scheme("https")
        .host("github.com")
        .addPathSegment(REPOSITORY_OWNER)
        .addPathSegment(REPOSITORY_NAME)
        .addPathSegment("blob")
        .addPathSegment(REPOSITORY_BRANCH)
        .addPathSegment(LICENSE_DIRECTORY)
        .addPathSegment(family.directory)
        .addPathSegment(LICENSE_FILE)
        .build()

    private fun rawUrl(directory: String, file: String): HttpUrl = HttpUrl.Builder()
        .scheme("https")
        .host("raw.githubusercontent.com")
        .addPathSegment(REPOSITORY_OWNER)
        .addPathSegment(REPOSITORY_NAME)
        .addPathSegment(REPOSITORY_BRANCH)
        .addPathSegment(LICENSE_DIRECTORY)
        .addPathSegment(directory)
        .addPathSegment(file)
        .build()

    internal fun parseMetadata(text: String): ReaderFontMetadata {
        val files = mutableListOf<ReaderFontFile>()
        val axes = mutableListOf<ReaderFontAxis>()
        val blocks = ArrayDeque<String>()
        var fields = mutableMapOf<String, String>()
        text.lineSequence().map(String::trim).filter(String::isNotEmpty).forEach { line ->
            when {
                line.endsWith("{") -> {
                    blocks.addLast(line.removeSuffix("{").trim())
                    if (blocks.size == 1) fields = mutableMapOf()
                }
                line == "}" -> {
                    val closed = blocks.removeLastOrNull()
                    if (blocks.isEmpty()) when (closed) {
                        "fonts" -> fontFile(fields)?.let(files::add)
                        "axes" -> axis(fields)?.let(axes::add)
                    }
                }
                blocks.size == 1 -> {
                    val key = line.substringBefore(':', "").trim()
                    if (key.isNotEmpty()) fields[key] = line.substringAfter(':').trim().unquoted()
                }
            }
        }
        return ReaderFontMetadata(files, axes)
    }

    internal fun resolveFaces(metadata: ReaderFontMetadata): Map<Variant, String> {
        val weightAxis = metadata.axes.firstOrNull { it.tag == "wght" }
        fun pick(style: String, weight: Int): String? {
            val candidates = metadata.files.filter { it.style == style }
            return candidates.firstOrNull { !it.variable && it.weight == weight }?.filename
                ?: candidates.firstOrNull { file ->
                    file.variable && weightAxis != null && weight.toFloat() in weightAxis.min..weightAxis.max
                }?.filename
                ?: candidates.firstOrNull { it.weight == weight }?.filename
        }
        val regular = pick(NORMAL, REGULAR_WEIGHT)
            ?: metadata.files.filter { it.style == NORMAL }.minByOrNull { kotlin.math.abs(it.weight - REGULAR_WEIGHT) }?.filename
            ?: return emptyMap()
        return buildMap {
            put(Variant.REGULAR, regular)
            pick(NORMAL, BOLD_WEIGHT)?.let { put(Variant.BOLD, it) }
            pick(ITALIC, REGULAR_WEIGHT)?.let { put(Variant.ITALIC, it) }
            pick(ITALIC, BOLD_WEIGHT)?.let { put(Variant.BOLD_ITALIC, it) }
        }
    }

    private fun fontFile(fields: Map<String, String>): ReaderFontFile? {
        val filename = fields["filename"]?.takeIf(::isSafeFilename) ?: return null
        val style = fields["style"]?.takeIf { it == NORMAL || it == ITALIC } ?: return null
        val weight = fields["weight"]?.toIntOrNull()?.takeIf { it in 1..1000 } ?: return null
        return ReaderFontFile(style, weight, filename)
    }

    private fun axis(fields: Map<String, String>): ReaderFontAxis? {
        val tag = fields["tag"] ?: return null
        val min = fields["min_value"]?.toFloatOrNull() ?: return null
        val max = fields["max_value"]?.toFloatOrNull()?.takeIf { it >= min } ?: return null
        return ReaderFontAxis(tag, min, max)
    }

    private fun String.unquoted(): String =
        if (length >= 2 && startsWith('"') && endsWith('"')) substring(1, length - 1) else this

    private const val NORMAL = "normal"
    private const val ITALIC = "italic"
    private const val REGULAR_WEIGHT = 400
    private const val BOLD_WEIGHT = 700
}
