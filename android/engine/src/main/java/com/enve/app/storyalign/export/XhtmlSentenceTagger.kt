package com.enve.app.storyalign.export

import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode
import org.jsoup.parser.Parser
import org.jsoup.parser.Tag

class XhtmlSentenceTagger {

    data class TaggedSentence(val id: String, val text: String)

    data class Result(val xhtml: String, val wrapped: Int, val skipped: Int)

    fun tag(xhtml: String, sentences: List<TaggedSentence>): Result {
        val doc = Jsoup.parse(xhtml, "", Parser.xmlParser())
        doc.outputSettings().prettyPrint(false)
        val body = doc.selectFirst("body") ?: doc

        val textNodes = ArrayList<TextNode>()
        collectTextNodes(body, textNodes)

        val compact = StringBuilder()
        val cNode = ArrayList<TextNode>()
        val cRaw = ArrayList<Int>()
        for (node in textNodes) {
            val raw = node.wholeText
            for (i in raw.indices) {
                val c = raw[i]
                if (!c.isWhitespace()) {
                    compact.append(c)
                    cNode.add(node)
                    cRaw.add(i)
                }
            }
        }
        val stream = compact.toString()

        var cursor = 0
        var wrapped = 0
        var skipped = 0
        val perNode = LinkedHashMap<TextNode, MutableList<Triple<Int, Int, String>>>()

        for (sentence in sentences) {
            val cs = sentence.text.filterNot { it.isWhitespace() }
            if (cs.isEmpty()) { skipped++; continue }
            var idx = stream.indexOf(cs, cursor)
            if (idx < 0) idx = stream.indexOf(cs)
            if (idx < 0) { skipped++; continue }
            val endI = idx + cs.length - 1
            val startNode = cNode[idx]
            val endNode = cNode[endI]
            cursor = idx + cs.length
            if (startNode !== endNode) { skipped++; continue }
            perNode.getOrPut(startNode) { ArrayList() }.add(Triple(cRaw[idx], cRaw[endI] + 1, sentence.id))
            wrapped++
        }

        for ((node, spans) in perNode) {
            spans.sortBy { it.first }
            val raw = node.wholeText
            val replacements = ArrayList<Node>()
            var pos = 0
            for ((s, e, id) in spans) {
                if (s > pos) replacements.add(TextNode(raw.substring(pos, s)))
                val span = Element(Tag.valueOf("span"), "")
                span.attr("id", id)
                span.appendChild(TextNode(raw.substring(s, e)))
                replacements.add(span)
                pos = e
            }
            if (pos < raw.length) replacements.add(TextNode(raw.substring(pos)))
            val parent = node.parent() ?: continue
            val at = node.siblingIndex()
            node.remove()
            parent.insertChildren(at, replacements)
        }

        return Result(doc.outerHtml(), wrapped, skipped)
    }

    private fun collectTextNodes(node: Node, out: MutableList<TextNode>) {
        for (child in node.childNodes()) {
            when (child) {
                is TextNode -> out.add(child)
                is Element -> collectTextNodes(child, out)
            }
        }
    }
}
