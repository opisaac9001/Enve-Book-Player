package com.enve.app.ui.screens.reader

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class ReaderIllustrationHit(
    val src: String? = null,
    val resource: String? = null,
    val alt: String? = null,
    val caption: String? = null,
    val width: Int = 0,
    val height: Int = 0,
    val linked: Boolean = false,
)

object ReaderIllustrationProbe {
    const val MIN_RENDERED_CSS_PX = 64
    const val MIN_NATURAL_PX = 160

    val SCRIPT: String = """(function (doc, x, y) {
  var win = doc && doc.defaultView;
  if (!win || !doc.body) return null;
  var selection = win.getSelection ? win.getSelection() : null;
  if (selection && selection.rangeCount > 0 && !selection.isCollapsed) return null;
  var hit = doc.elementFromPoint(x, y);
  if (!hit || !hit.closest) return null;
  var image = hit.closest("img, image, svg");
  if (!image) return null;
  if (image.closest("a[href]")) return { linked: true };
  var target = image;
  if (image.localName === "svg") {
    var references = image.querySelectorAll("image");
    if (references.length !== 1) return null;
    target = references[0];
  }
  var rect = target.getBoundingClientRect();
  if (rect.width < $MIN_RENDERED_CSS_PX || rect.height < $MIN_RENDERED_CSS_PX) return null;
  var isImg = target.localName === "img";
  var width = isImg ? target.naturalWidth : Math.round(rect.width);
  var height = isImg ? target.naturalHeight : Math.round(rect.height);
  if (Math.max(width, height) < $MIN_NATURAL_PX) return null;
  var resource = target.getAttribute("data-enve-resource");
  var src = isImg
    ? target.getAttribute("src")
    : (target.getAttribute("href") || target.getAttributeNS("http://www.w3.org/1999/xlink", "href"));
  if (!resource && (!src || /^(data|blob):/i.test(src))) return null;
  var compact = function (value) {
    var text = String(value == null ? "" : value).replace(/\s+/g, " ").trim();
    return text || null;
  };
  var figure = target.closest("figure");
  var captionEl = figure ? figure.querySelector("figcaption") : null;
  var svgTitle = image.localName === "svg" ? image.querySelector("title") : null;
  var alt = isImg
    ? target.getAttribute("alt")
    : (image.getAttribute("aria-label") || (svgTitle ? svgTitle.textContent : null));
  return {
    src: src || null,
    resource: resource || null,
    alt: compact(alt),
    caption: compact(captionEl ? captionEl.textContent : null),
    width: width,
    height: height,
    linked: false
  };
})"""

    private val json = Json { ignoreUnknownKeys = true }

    fun readiumScript(cssX: Float, cssY: Float): String = "($SCRIPT)(document, $cssX, $cssY);"

    fun foliateScript(cssX: Float, cssY: Float): String =
        "window.enveReader.illustrationAt($cssX, $cssY, $SCRIPT);"

    fun parse(result: String?): ReaderIllustrationHit? {
        val raw = result?.trim().orEmpty()
        if (raw.isEmpty() || raw == "null" || raw == "undefined") return null
        val text = if (raw.startsWith("\"")) {
            runCatching { json.decodeFromString<String>(raw) }.getOrNull() ?: return null
        } else {
            raw
        }
        val hit = runCatching { json.decodeFromString<ReaderIllustrationHit>(text) }.getOrNull() ?: return null
        return hit.takeIf { it.linked || !it.src.isNullOrBlank() || !it.resource.isNullOrBlank() }
    }
}
