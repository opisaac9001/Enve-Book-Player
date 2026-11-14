package com.enve.app.webimport

import java.io.File
import java.io.StringReader
import java.util.zip.ZipFile
import javax.xml.parsers.DocumentBuilderFactory
import org.xml.sax.InputSource

internal fun parseXml(xml: String): org.w3c.dom.Document =
    DocumentBuilderFactory.newInstance()
        .apply { isNamespaceAware = true }
        .newDocumentBuilder()
        .parse(InputSource(StringReader(xml)))

internal fun epubEntries(file: File): Map<String, ByteArray> = ZipFile(file).use { zip ->
    zip.entries().asSequence().associate { entry -> entry.name to zip.getInputStream(entry).readBytes() }
}

internal fun Map<String, ByteArray>.text(name: String): String =
    getValue(name).toString(Charsets.UTF_8)
