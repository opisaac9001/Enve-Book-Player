package com.enve.app.ui.screens.reader

internal object ReaderSelectionHandleFix {
    enum class Result { CHANGED, STABLE, BLOCKED, FAILED }

    const val SCRIPT: String = """
(function (doc, paginated) {
          var win = doc && doc.defaultView;
          if (!win || !doc.body || !doc.head) return "failed";
          var state = win.__enveSelectionLead || (win.__enveSelectionLead = {});
          state.paginated = paginated === true;
          if (!state.paginated) state.selectionX = null;
          if (!state.scrollGuardInstalled) {
            state.scrollGuardInstalled = true;
            state.selectionX = null;
            doc.addEventListener("selectionchange", function () {
              var selection = win.getSelection();
              if (!selection || selection.isCollapsed) {
                state.selectionX = null;
                return;
              }
              var root = doc.documentElement;
              if (!state.paginated ||
                  win.getComputedStyle(root).writingMode.indexOf("vertical") === 0) {
                state.selectionX = null;
                return;
              }
              if (state.selectionX === null) state.selectionX = win.scrollX;
            }, true);
            win.addEventListener("scroll", function () {
              if (!state.paginated || win.getComputedStyle(doc.documentElement).writingMode.indexOf("vertical") === 0) {
                state.selectionX = null;
                return;
              }
              if (state.selectionX !== null && win.scrollX !== state.selectionX) {
                doc.scrollingElement.scrollLeft = state.selectionX;
              }
            });
          }
          var installed = false;
          var tok = state.token ||
                    (state.token = "l" + Math.random().toString(36).slice(2, 10));
          var ATTR = state.attr || (state.attr = "data-enve-selection-lead-" + tok);
          var SEL = '[' + ATTR + ']';

          if (!state.styleEl || !state.styleEl.isConnected) {
            var css = doc.createElement("style");
            var content = 'content:"\u00a0\u00a0"';
            if (win.CSS && win.CSS.supports &&
                win.CSS.supports("content", '"x" / ""')) {
              content += ' / ""';
            }
            css.textContent =
              SEL + '::before{' + content + ' !important;' +
              'font-size:0!important;line-height:0!important;' +
              'letter-spacing:0!important;word-spacing:0!important;' +
              'display:inline!important;position:static!important;' +
              'float:none!important;margin:0!important;padding:0!important;' +
              'border:0!important;background:none!important;' +
              'box-shadow:none!important;outline:none!important;' +
              'width:auto!important;height:auto!important;' +
              'vertical-align:baseline!important;' +
              'counter-increment:none!important;counter-reset:none!important;' +
              'counter-set:none!important}';
            doc.head.appendChild(css);
            state.styleEl = css;
            installed = true;
          }
          if (!state.styleEl.sheet) return "blocked";

          var old = doc.querySelectorAll(SEL);
          var had = new Set(), i;
          for (i = 0; i < old.length; i++) {
            had.add(old[i]);
            old[i].removeAttribute(ATTR);
          }
          var kept = 0;

          var BLOCK = {
            "block": 1, "list-item": 1, "flow-root": 1, "inline-block": 1,
            "table-cell": 1, "table-caption": 1
          };

          function outOfFlow(s) {
            return s.getPropertyValue("float") !== "none" ||
                   s.position === "absolute" || s.position === "fixed" ||
                   s.display === "none";
          }

          var ATOMIC = {
            "img": 1, "svg": 1, "math": 1, "video": 1, "audio": 1, "canvas": 1,
            "iframe": 1, "object": 1, "embed": 1, "input": 1, "select": 1,
            "textarea": 1, "button": 1, "br": 1
          };

          function inlineStart(node) {
            if (node.nodeType === 3) {
              return /\S/.test(node.data) ? true : null;
            }
            if (node.nodeType !== 1) return null;
            var s = win.getComputedStyle(node);
            if (outOfFlow(s)) return null;
            var d = s.display;
            if (d === "contents") return startsInline(node);
            if (d.indexOf("inline") !== 0 && d.indexOf("ruby") !== 0) return false;
            if (d === "inline" && !ATOMIC[node.localName]) return startsInline(node);
            return true;
          }

          function startsInline(el) {
            var nodes = el.childNodes, answer;
            for (var i = 0; i < nodes.length; i++) {
              answer = inlineStart(nodes[i]);
              if (answer !== null) return answer;
            }
            return null;
          }

          function zero(value) {
            return value === "0" || value === "0px";
          }

          function autoOrZero(value) {
            return value === "auto" || zero(value);
          }

          function neutralCounter(style, name) {
            var value = style.getPropertyValue(name);
            return value === "" || value === "none";
          }

          function safePseudo(style) {
            var transparent = style.backgroundColor === "transparent" ||
                             style.backgroundColor === "rgba(0, 0, 0, 0)";
            return style.content !== "none" && style.content !== "normal" &&
                   style.content !== "\"\"" &&
                   style.display === "inline" &&
                   style.position === "static" &&
                   style.getPropertyValue("float") === "none" &&
                   zero(style.fontSize) && zero(style.lineHeight) &&
                   (style.letterSpacing === "normal" || zero(style.letterSpacing)) && zero(style.wordSpacing) &&
                   zero(style.marginTop) && zero(style.marginRight) &&
                   zero(style.marginBottom) && zero(style.marginLeft) &&
                   zero(style.paddingTop) && zero(style.paddingRight) &&
                   zero(style.paddingBottom) && zero(style.paddingLeft) &&
                   zero(style.borderTopWidth) && zero(style.borderRightWidth) &&
                   zero(style.borderBottomWidth) && zero(style.borderLeftWidth) &&
                   style.backgroundImage === "none" && transparent &&
                   style.boxShadow === "none" &&
                   (style.outlineStyle === "none" || zero(style.outlineWidth)) &&
                   autoOrZero(style.width) && autoOrZero(style.height) &&
                   style.verticalAlign === "baseline" &&
                   neutralCounter(style, "counter-increment") &&
                   neutralCounter(style, "counter-reset") &&
                   neutralCounter(style, "counter-set");
          }

          var els = doc.getElementsByTagName("*");
          var changed = installed;
          for (i = 0; i < els.length; i++) {
            var el = els[i];
            if (!BLOCK[win.getComputedStyle(el).display]) continue;
            var before = win.getComputedStyle(el, "::before").content;
            if (before !== "none" && before !== "normal") continue;
            if (startsInline(el) !== true) continue;
            el.setAttribute(ATTR, "");
            if (!safePseudo(win.getComputedStyle(el, "::before"))) {
              el.removeAttribute(ATTR);
              continue;
            }
            if (!had.has(el)) {
              changed = true;
            } else {
              kept++;
            }
          }
          if (kept !== had.size) changed = true;
          return changed ? "changed" : "stable";
        })
    """

    fun readiumScript(paginated: Boolean): String = "($SCRIPT)(document, $paginated);"

    fun foliateInstallScript(): String = "window.enveReader.installSelectionHandleFix($SCRIPT);"

    fun parse(result: String?): Result = when (result?.trim()?.removeSurrounding("\"")?.trim()) {
        "changed" -> Result.CHANGED
        "stable" -> Result.STABLE
        "blocked" -> Result.BLOCKED
        else -> Result.FAILED
    }
}
