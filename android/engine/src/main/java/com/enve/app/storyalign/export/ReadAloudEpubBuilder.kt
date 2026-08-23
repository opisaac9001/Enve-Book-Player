package com.enve.app.storyalign.export

import com.enve.app.storyalign.align.AlignedChapter
import com.enve.app.storyalign.epub.EpubDocument
import com.enve.app.storyalign.epub.EpubZip
import com.enve.app.storyalign.epub.parseXmlDocument
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.zip.CRC32
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

object ReadAloudEpubBuilder {

    private const val MEDIA_ACTIVE_CLASS = "-epub-media-overlay-active"

    class AudioClipFile(val name: String, val bytes: ByteArray)

    class AudioClipRef(val name: String, val file: File)

    fun build(
        original: EpubZip,
        doc: EpubDocument,
        alignedChapters: List<AlignedChapter>,
        audioClips: List<AudioClipFile>,
        modifiedIso: String,
    ): ByteArray {
        val (entries, opfDir) = prepareEntries(original, doc, alignedChapters, modifiedIso)
        for (clip in audioClips) entries[audioPath(opfDir, clip.name)] = clip.bytes
        return rezip(entries)
    }

    fun buildToFile(
        outFile: File,
        original: EpubZip,
        doc: EpubDocument,
        alignedChapters: List<AlignedChapter>,
        audioClips: List<AudioClipRef>,
        modifiedIso: String,
    ) {
        val (entries, opfDir) = prepareEntries(original, doc, alignedChapters, modifiedIso)
        BufferedOutputStream(FileOutputStream(outFile)).use { bos ->
            ZipOutputStream(bos).use { zos ->
                entries["mimetype"]?.let { writeStored(zos, "mimetype", it) }
                    ?: writeStored(zos, "mimetype", "application/epub+zip".toByteArray(Charsets.US_ASCII))
                zos.setLevel(Deflater.DEFAULT_COMPRESSION)
                for ((name, bytes) in entries) {
                    if (name == "mimetype") continue
                    val e = ZipEntry(name).apply { method = ZipEntry.DEFLATED }
                    zos.putNextEntry(e)
                    zos.write(bytes)
                    zos.closeEntry()
                }

                zos.setLevel(Deflater.NO_COMPRESSION)
                for (clip in audioClips) {
                    val e = ZipEntry(audioPath(opfDir, clip.name)).apply { method = ZipEntry.DEFLATED }
                    zos.putNextEntry(e)
                    clip.file.inputStream().buffered().use { it.copyTo(zos) }
                    zos.closeEntry()
                }
            }
        }
    }

    private fun audioPath(opfDir: String, name: String): String =
        if (opfDir.isEmpty()) "${AssetPaths.AUDIO}/$name" else "$opfDir/${AssetPaths.AUDIO}/$name"

    private fun prepareEntries(
        original: EpubZip,
        doc: EpubDocument,
        alignedChapters: List<AlignedChapter>,
        modifiedIso: String,
    ): Pair<LinkedHashMap<String, ByteArray>, String> {
        val entries = LinkedHashMap(original.entries())
        val opfDir = doc.opfPath.substringBeforeLast('/', "")
        fun underOpf(rel: String) = if (opfDir.isEmpty()) rel else "$opfDir/$rel"

        val overlays = ArrayList<MediaOverlay>()

        for (chapter in alignedChapters) {
            val ranges = chapter.allSentenceRanges.filter { it.duration > 0.0 }
            if (ranges.isEmpty()) continue
            val href = chapter.manifestItem.href
            val chapterPath = underOpf(href)
            val basename = href.substringAfterLast('/').substringBeforeLast('.')
            val manifestId = chapter.manifestItem.id

            val originalXhtml = chapter.manifestItem.xhtml
                ?: entries[chapterPath]?.toString(Charsets.UTF_8)
                ?: continue
            val tagged = XhtmlSentenceTagger().tag(
                originalXhtml,
                chapter.alignedSentences
                    .filter { it.sentenceRange.duration > 0.0 }
                    .map { XhtmlSentenceTagger.TaggedSentence("$manifestId-${AssetPaths.SENTENCE_PFX}${it.sentenceId}", it.xhtmlSentence) },
            )
            entries[chapterPath] = tagged.xhtml.toByteArray(Charsets.UTF_8)

            val overlay = MediaOverlay.fromChapter(manifestId, href, basename, ranges)
            entries[underOpf(overlay.href)] = overlay.overlayXml().toByteArray(Charsets.UTF_8)
            overlays.add(overlay)
        }

        val opfBytes = entries[doc.opfPath] ?: error("OPF missing")
        val opf = parseXmlDocument(opfBytes)
        updateOpf(opf, overlays, modifiedIso)
        opf.outputSettings().prettyPrint(false)
        entries[doc.opfPath] = opf.outerHtml().toByteArray(Charsets.UTF_8)

        return entries to opfDir
    }

    private fun updateOpf(opf: Document, overlays: List<MediaOverlay>, modifiedIso: String) {
        val manifest = opf.selectFirst("manifest") ?: error("manifest missing")
        val metadata = opf.selectFirst("metadata") ?: error("metadata missing")

        val modified = opf.select("meta").firstOrNull { it.attr("property") == "dcterms:modified" }
        if (modified != null) modified.text(modifiedIso) else metadata.appendChild(meta(opf, "dcterms:modified", modifiedIso))

        var totalDuration = 0.0
        for (mo in overlays) {
            val item = manifest.select("item").firstOrNull { it.attr("id") == mo.manifestId } ?: continue
            item.attr("media-overlay", mo.itemId)
            val dur = mo.clips.sumOf { it.endSeconds - it.startSeconds }
            totalDuration += dur
            metadata.appendChild(metaRefines(opf, mo.itemId, "media:duration", formatDuration(dur)))
        }
        metadata.appendChild(meta(opf, "media:duration", formatDuration(totalDuration)))
        metadata.appendChild(meta(opf, "media:active-class", MEDIA_ACTIVE_CLASS))

        for (mo in overlays) {
            addItem(opf, manifest, mo.itemId, mo.href, "application/smil+xml")
        }

        val audioNames = overlays.flatMap { it.audioFileNames }.distinct().sorted()
        for (name in audioNames) {
            addItem(opf, manifest, "storyalign_audio_${sanitize(name)}", "${AssetPaths.AUDIO}/$name", audioMediaType(name))
        }
    }

    private fun meta(doc: Document, property: String, text: String): Element =
        Element(org.jsoup.parser.Tag.valueOf("meta"), "").attr("property", property).text(text)

    private fun metaRefines(doc: Document, refinesId: String, property: String, text: String): Element =
        Element(org.jsoup.parser.Tag.valueOf("meta"), "").attr("refines", "#$refinesId").attr("property", property).text(text)

    private fun addItem(doc: Document, manifest: Element, id: String, href: String, mediaType: String) {
        if (manifest.select("item").any { it.attr("id") == id || it.attr("href") == href }) return
        val item = Element(org.jsoup.parser.Tag.valueOf("item"), "")
        item.attr("id", id).attr("href", href).attr("media-type", mediaType)
        manifest.appendChild(item)
    }

    private fun audioMediaType(name: String): String = when (name.substringAfterLast('.').lowercase()) {
        "mp3" -> "audio/mpeg"
        "m4a", "mp4", "aac" -> "audio/mp4"
        "oga", "ogg" -> "audio/ogg"
        "wav" -> "audio/wav"
        else -> "audio/mpeg"
    }

    private fun sanitize(s: String): String = s.replace(Regex("[^A-Za-z0-9_-]"), "_")

    private fun rezip(entries: Map<String, ByteArray>): ByteArray {
        val bos = ByteArrayOutputStream()
        ZipOutputStream(bos).use { zos ->
            entries["mimetype"]?.let { writeStored(zos, "mimetype", it) }
                ?: writeStored(zos, "mimetype", "application/epub+zip".toByteArray(Charsets.US_ASCII))
            zos.setLevel(Deflater.DEFAULT_COMPRESSION)
            for ((name, bytes) in entries) {
                if (name == "mimetype") continue
                val e = ZipEntry(name)
                e.method = ZipEntry.DEFLATED
                zos.putNextEntry(e)
                zos.write(bytes)
                zos.closeEntry()
            }
        }
        return bos.toByteArray()
    }

    private fun writeStored(zos: ZipOutputStream, name: String, bytes: ByteArray) {
        val e = ZipEntry(name)
        e.method = ZipEntry.STORED
        e.size = bytes.size.toLong()
        e.compressedSize = bytes.size.toLong()
        val crc = CRC32()
        crc.update(bytes)
        e.crc = crc.value
        zos.putNextEntry(e)
        zos.write(bytes)
        zos.closeEntry()
    }
}
