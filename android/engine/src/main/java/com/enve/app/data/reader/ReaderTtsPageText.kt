package com.enve.app.data.reader

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive

object ReaderTtsPageText {
    private const val DEFAULT_MAX_CHARS = 4_000

    fun visibleTextScript(maxChars: Int = DEFAULT_MAX_CHARS): String {
        val cappedMaxChars = maxChars.coerceIn(256, 20_000)
        return """
            (function() {
                const root = document.body || document.documentElement;
                if (!root) return "";
                const maxChars = $cappedMaxChars;
                const viewportWidth = window.innerWidth || document.documentElement.clientWidth || 0;
                const viewportHeight = window.innerHeight || document.documentElement.clientHeight || 0;
                const chunks = [];
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);

                function hasVisibleRect(node) {
                    const parent = node.parentElement;
                    if (!parent) return false;
                    const style = window.getComputedStyle(parent);
                    if (!style || style.display === "none" || style.visibility === "hidden") return false;
                    const range = document.createRange();
                    range.selectNodeContents(node);
                    const rects = Array.from(range.getClientRects());
                    if (range.detach) range.detach();
                    return rects.some((rect) =>
                        rect.bottom > 0 &&
                        rect.top < viewportHeight &&
                        rect.right > 0 &&
                        rect.left < viewportWidth &&
                        (rect.width > 0 || rect.height > 0)
                    );
                }

                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    const text = (node.nodeValue || "").replace(/\s+/g, " ").trim();
                    if (!text || !hasVisibleRect(node)) continue;
                    chunks.push(text);
                    if (chunks.join(" ").length >= maxChars) break;
                }
                return chunks.join(" ").replace(/\s+/g, " ").trim().slice(0, maxChars);
            })();
        """.trimIndent()
    }

    fun decodeStringResult(result: String?): String? {
        if (result.isNullOrBlank() || result == "null") return null
        return runCatching {
            Json.parseToJsonElement(result).jsonPrimitive
        }.getOrNull()
            ?.takeIf { it.isString }
            ?.contentOrNull
            ?.trim()
            ?.takeIf { it.isNotBlank() }
    }
}
