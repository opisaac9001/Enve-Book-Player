package com.enve.app.ui.screens.reader

import com.enve.app.data.reader.ReaderPreferences

fun ReaderPreferences.reflowSignature(): List<Any?> = listOf(
    font,
    customFontName,
    fontSize,
    lineHeight,
    pageMargins,
    verticalMargins,
    wordSpacing,
    letterSpacing,
    fontWeight,
    paragraphSpacing,
    paragraphIndent,
    scroll,
    publisherStyles,
    justified,
    columns,
)

object ReaderWideContentFit {
    enum class Result { CHANGED, STABLE, BLOCKED, FAILED }

    const val SCRIPT: String = """(function (doc) {
  var win = doc && doc.defaultView;
  if (!win || !doc.body) return "failed";
  var state = win.__enveWideFit || (win.__enveWideFit = {});
  var token = state.token || (state.token = "w" + Math.random().toString(36).slice(2, 10));
  var ATTR = "data-enve-fit-" + token;
  var SEL = "[" + ATTR + "]";
  if (!state.styleEl || !state.styleEl.isConnected) {
    var css = doc.createElement("style");
    css.textContent =
      "table" + SEL + "{table-layout:fixed !important;width:100% !important;max-width:100% !important;margin-left:0 !important;margin-right:0 !important}" +
      "table" + SEL + " td,table" + SEL + " th{overflow-wrap:anywhere !important}" +
      "pre" + SEL + "{white-space:pre-wrap !important;overflow-wrap:anywhere !important;max-width:100% !important}";
    (doc.head || doc.documentElement).appendChild(css);
    state.styleEl = css;
    if (!css.sheet) return "blocked";
  }
  function availableWidth(el) {
    var parent = el.parentElement;
    if (!parent) return 0;
    var style = win.getComputedStyle(parent);
    return parent.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
  }
  function paintedWidth(el) {
    var rects = el.getClientRects(), widest = 0, j;
    for (j = 0; j < rects.length; j++) if (rects[j].width > widest) widest = rects[j].width;
    if (el.localName === "pre") {
      var range = doc.createRange();
      range.selectNodeContents(el);
      var lines = range.getClientRects();
      for (j = 0; j < lines.length; j++) if (lines[j].width > widest) widest = lines[j].width;
    }
    return widest;
  }
  var changed = false;
  for (var pass = 0; pass < 3; pass++) {
    var els = doc.querySelectorAll("table,pre");
    var had = [], i;
    for (i = 0; i < els.length; i++) {
      had.push(els[i].hasAttribute(ATTR));
      if (had[i]) els[i].removeAttribute(ATTR);
    }
    var passChanged = false;
    for (i = 0; i < els.length; i++) {
      var el = els[i];
      var avail = availableWidth(el);
      var want = avail > 0 && paintedWidth(el) > avail + 1;
      if (want) el.setAttribute(ATTR, "");
      if (want !== had[i]) passChanged = true;
    }
    if (!passChanged) break;
    changed = true;
  }
  return changed ? "changed" : "stable";
})"""

    fun readiumScript(): String = "($SCRIPT)(document);"

    fun foliateInstallScript(): String = "window.enveReader.installWideContentFit($SCRIPT);"

    fun parse(result: String?): Result =
        when (result?.trim()?.removeSurrounding("\"")?.trim()) {
            "changed" -> Result.CHANGED
            "stable" -> Result.STABLE
            "blocked" -> Result.BLOCKED
            else -> Result.FAILED
        }
}
