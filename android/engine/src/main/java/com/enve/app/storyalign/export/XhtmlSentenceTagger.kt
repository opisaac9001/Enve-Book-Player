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

    private data class Range(val startNode: TextNode, val endNode: TextNode, val start: Int, val end: Int, val id: String)

    fun tag(xhtml: String, sentences: List<TaggedSentence>, allowInlineRanges: Boolean = false): Result {
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
        val ranges = ArrayList<Range>()

        for (sentence in sentences) {
            val cs = sentence.text.filterNot { it.isWhitespace() }
            if (cs.isEmpty()) { skipped++; continue }
            var idx = stream.indexOf(cs, cursor)
            if (idx < 0 && !allowInlineRanges) idx = stream.indexOf(cs)
            if (idx < 0) { skipped++; continue }
            val endI = idx + cs.length - 1
            val startNode = cNode[idx]
            val endNode = cNode[endI]
            cursor = idx + cs.length
            if (startNode !== endNode && !allowInlineRanges) { skipped++; continue }
            ranges.add(Range(startNode, endNode, cRaw[idx], cRaw[endI] + 1, sentence.id))
        }

        for (range in ranges.asReversed()) {
            if (wrap(range)) wrapped++ else skipped++
        }

        return Result(doc.outerHtml(), wrapped, skipped)
    }

    private fun wrap(range: Range): Boolean {
        var ancestor: Node = range.startNode.parent() ?: return false
        val endAncestors = generateSequence(range.endNode.parent()) { it.parent() }.toSet()
        while (ancestor !in endAncestors) ancestor = ancestor.parent() ?: return false
        val common = ancestor as? Element ?: return false
        if (range.startNode !== range.endNode) {
            for (boundary in listOf(range.startNode, range.endNode)) {
                var parent = boundary.parent()
                while (parent !== common) {
                    if (parent is Element && parent.tag().isBlock) return false
                    parent = parent?.parent() ?: return false
                }
            }
        }
        if (range.end < range.endNode.wholeText.length) range.endNode.splitText(range.end)
        val start = if (range.start == 0) range.startNode else range.startNode.splitText(range.start)
        val end = if (range.startNode === range.endNode) start else range.endNode
        var first: Node = start
        while (first.parent() !== common) {
            val parent = first.parent() as Element
            if (first.siblingIndex() > 0) {
                val right = parent.shallowClone().removeAttr("id")
                parent.after(right)
                parent.childNodes().drop(first.siblingIndex()).toList().forEach { right.appendChild(it) }
                first = right
            } else {
                first = parent
            }
        }
        var last: Node = end
        while (last.parent() !== common) {
            val parent = last.parent() as Element
            val following = parent.childNodes().drop(last.siblingIndex() + 1).toList()
            if (following.isNotEmpty()) {
                val right = parent.shallowClone().removeAttr("id")
                parent.after(right)
                following.forEach { right.appendChild(it) }
            }
            last = parent
        }
        val selected = common.childNodes().subList(first.siblingIndex(), last.siblingIndex() + 1).toList()
        val span = Element(Tag.valueOf("span"), "").attr("id", range.id)
        first.before(span)
        selected.forEach { span.appendChild(it) }
        return true
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
