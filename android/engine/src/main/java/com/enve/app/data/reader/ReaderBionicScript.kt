package com.enve.app.data.reader

object ReaderBionicScript {

    fun makeScript(enabled: Boolean): String = """
        (function() {
            var FLAG_CLASS = 'br-bionic-word';
            var FOCUS_CLASS = 'br-bionic-focus';
            var STYLE_ID = 'enve-bionic-style';

            function focusLength(len) {
                if (len === 0) return 0;
                if (len === 1) return 1;
                var f = Math.ceil(len * 0.4) + (len < 5 ? 1 : 0);
                return Math.min(f, len - 1);
            }

            function ensureStyle() {
                if (document.getElementById(STYLE_ID)) return;
                var s = document.createElement('style');
                s.id = STYLE_ID;
                s.textContent = '.' + FOCUS_CLASS + ' { font-weight: 700; }';
                document.head.appendChild(s);
            }

            function isWordCore(token) {
                return /^[\p{L}\p{N}][\p{L}\p{N}'’-]*${'$'}/u.test(token);
            }

            function splitTokenPunctuation(token) {
                var m = token.match(/^([^\p{L}\p{N}'’-]*)([\p{L}\p{N}'’-]+)([^\p{L}\p{N}'’-]*)${'$'}/u);
                if (!m) return { prefix: '', core: token, suffix: '' };
                return { prefix: m[1] || '', core: m[2] || '', suffix: m[3] || '' };
            }

            function shouldSkip(node) {
                if (!node || !node.parentElement) return true;
                if (!node.nodeValue || !node.nodeValue.trim()) return true;
                var p = node.parentElement;
                if (p.closest('script,style,pre,code,kbd,samp,math,ruby,rt,rp,textarea,select,option')) return true;
                if (p.closest('.' + FLAG_CLASS)) return true;
                return false;
            }

            function strip() {
                var nodes = document.querySelectorAll('.' + FLAG_CLASS);
                for (var i = 0; i < nodes.length; i++) {
                    var span = nodes[i];
                    var text = span.textContent;
                    var parent = span.parentNode;
                    if (parent) {
                        parent.replaceChild(document.createTextNode(text), span);
                    }
                }
                var style = document.getElementById(STYLE_ID);
                if (style && style.parentNode) style.parentNode.removeChild(style);
            }

            function appendBionic(doc, fragment, text) {
                var parts = text.split(/(\s+)/);
                for (var i = 0; i < parts.length; i++) {
                    var part = parts[i];
                    if (!part) continue;
                    if (/^\s+${'$'}/u.test(part)) {
                        fragment.appendChild(doc.createTextNode(part));
                        continue;
                    }
                    var split = splitTokenPunctuation(part);
                    var coreLetters = split.core.replace(/[^\p{L}\p{N}]/gu, '');
                    if (coreLetters.length < 3 || !isWordCore(split.core)) {
                        fragment.appendChild(doc.createTextNode(part));
                        continue;
                    }
                    var f = Math.min(split.core.length, focusLength(split.core.length));
                    var lead = split.core.slice(0, f);
                    var tail = split.core.slice(f);
                    if (split.prefix) fragment.appendChild(doc.createTextNode(split.prefix));
                    var wrap = doc.createElement('span');
                    wrap.className = FLAG_CLASS;
                    var focus = doc.createElement('span');
                    focus.className = FOCUS_CLASS;
                    focus.textContent = lead;
                    wrap.appendChild(focus);
                    if (tail) wrap.appendChild(doc.createTextNode(tail));
                    fragment.appendChild(wrap);
                    if (split.suffix) fragment.appendChild(doc.createTextNode(split.suffix));
                }
            }

            function apply() {
                ensureStyle();
                var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                    acceptNode: function(node) {
                        return shouldSkip(node) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT;
                    }
                });
                var batch = [];
                while (walker.nextNode()) batch.push(walker.currentNode);
                for (var i = 0; i < batch.length; i++) {
                    var node = batch[i];
                    if (!node.parentNode || shouldSkip(node)) continue;
                    var frag = document.createDocumentFragment();
                    appendBionic(document, frag, node.nodeValue);
                    node.parentNode.replaceChild(frag, node);
                }
            }

            try {
                if (${if (enabled) "true" else "false"}) {
                    apply();
                } else {
                    strip();
                }
            } catch (e) {
                console.error('[bionic] error', e);
            }
        })();
    """.trimIndent()
}
