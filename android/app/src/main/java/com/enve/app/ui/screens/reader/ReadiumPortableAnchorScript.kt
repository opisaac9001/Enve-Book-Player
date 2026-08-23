package com.enve.app.ui.screens.reader

object ReadiumPortableAnchorScript {
    val selection: String = """
        (function() {
            const selection = window.getSelection();
            if (!selection || selection.rangeCount === 0 || selection.isCollapsed) return null;
            const range = selection.getRangeAt(0).cloneRange();
            const compact = value => String(value || '')
                .normalize('NFC')
                .replace(/\s+/g, ' ')
                .trim();
            const exact = compact(range.toString());
            if (!exact) return null;

            function cssPath(element) {
                if (!(element instanceof Element)) return null;
                const escape = value => globalThis.CSS?.escape
                    ? CSS.escape(value)
                    : value.replace(/[^a-zA-Z0-9_-]/g, character => '\\' + character);
                if (element.id) return '#' + escape(element.id);
                const parts = [];
                let current = element;
                while (current && current !== current.ownerDocument.body) {
                    const tag = current.localName;
                    if (!tag) break;
                    const siblings = Array.from(current.parentElement?.children || [])
                        .filter(item => item.localName === tag);
                    const suffix = siblings.length > 1
                        ? ':nth-of-type(' + (siblings.indexOf(current) + 1) + ')'
                        : '';
                    parts.unshift(tag + suffix);
                    current = current.parentElement;
                }
                parts.unshift('body');
                return parts.join(' > ');
            }

            function domPoint(container, offset) {
                if (!container) return null;
                if (container.nodeType !== Node.TEXT_NODE) return null;
                const element = container.parentElement;
                if (!element) return null;
                const walker = element.ownerDocument.createTreeWalker(
                    element,
                    NodeFilter.SHOW_TEXT
                );
                const textNodes = [];
                while (walker.nextNode()) textNodes.push(walker.currentNode);
                return {
                    cssSelector: cssPath(element),
                    textNodeIndex: Math.max(0, textNodes.indexOf(container)),
                    charOffset: Math.max(0, offset)
                };
            }

            function domRange(range) {
                const start = domPoint(range.startContainer, range.startOffset);
                if (!start?.cssSelector) return null;
                const end = domPoint(range.endContainer, range.endOffset);
                return { start, ...(end?.cssSelector ? { end } : {}) };
            }

            function cfiElementSteps(element) {
                const steps = [];
                let node = element;
                while (node && node !== node.ownerDocument.documentElement) {
                    const parent = node.parentElement;
                    if (!parent) return null;
                    let index = 0;
                    for (const child of parent.children) {
                        index += 1;
                        if (child === node) break;
                    }
                    const id = node.id && /^[A-Za-z0-9_.-]+$/.test(node.id) ? '[' + node.id + ']' : '';
                    steps.unshift('/' + (index * 2) + id);
                    node = parent;
                }
                return steps;
            }

            function cfiTextStep(container, offset) {
                const parent = container.parentNode;
                let elementCount = 0;
                let chunkOffset = 0;
                let step = 1;
                let inChunk = false;
                for (const child of parent.childNodes) {
                    if (child.nodeType === Node.ELEMENT_NODE) {
                        elementCount += 1;
                        inChunk = false;
                        continue;
                    }
                    if (!inChunk) {
                        step = elementCount * 2 + 1;
                        chunkOffset = 0;
                        inChunk = true;
                    }
                    if (child === container) {
                        return { step: '/' + step, offset: chunkOffset + offset };
                    }
                    chunkOffset += (child.data ?? '').length;
                }
                return null;
            }

            function cfiPoint(container, offset) {
                if (container.nodeType !== Node.TEXT_NODE || !container.parentElement) return null;
                const parentSteps = cfiElementSteps(container.parentElement);
                const text = cfiTextStep(container, offset);
                if (!parentSteps || !text) return null;
                return { steps: [...parentSteps, text.step], offset: text.offset };
            }

            function cfiRangeParts(range) {
                const start = cfiPoint(range.startContainer, range.startOffset);
                const end = cfiPoint(range.endContainer, range.endOffset);
                if (!start || !end) return null;
                let common = 0;
                while (common < start.steps.length - 1
                    && common < end.steps.length - 1
                    && start.steps[common] === end.steps[common]) common += 1;
                return {
                    parent: start.steps.slice(0, common).join(''),
                    start: start.steps.slice(common).join('') + ':' + start.offset,
                    end: end.steps.slice(common).join('') + ':' + end.offset
                };
            }

            const startElement = range.startContainer.nodeType === Node.ELEMENT_NODE
                ? range.startContainer
                : range.startContainer.parentElement;
            const scope = startElement?.closest?.('p,li,blockquote,dd,dt,figcaption,pre,div')
                ?? startElement
                ?? document.body;
            const context = compact(scope.textContent);
            const index = context.indexOf(exact);
            const cfi = cfiRangeParts(range);
            return JSON.stringify({
                cssSelector: cssPath(scope),
                domRange: domRange(range),
                cfiParent: cfi?.parent ?? null,
                cfiStart: cfi?.start ?? null,
                cfiEnd: cfi?.end ?? null,
                textQuote: {
                    exact,
                    prefix: index > 0 ? context.slice(Math.max(0, index - 64), index) : null,
                    suffix: index >= 0 ? context.slice(index + exact.length, index + exact.length + 64) : null
                }
            });
        })();
    """.trimIndent()

    val capture: String = """
        (function() {
            const SKIP = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'LINK', 'META']);
            const BLOCK_SELECTOR = 'p,li,blockquote,dd,dt,figcaption,pre';

            function cssPath(element) {
                if (!(element instanceof Element)) return null;
                const escape = value => globalThis.CSS?.escape
                    ? CSS.escape(value)
                    : value.replace(/[^a-zA-Z0-9_-]/g, character => '\\' + character);
                if (element.id) return '#' + escape(element.id);
                const parts = [];
                let current = element;
                while (current && current !== current.ownerDocument.body) {
                    const tag = current.localName;
                    if (!tag) break;
                    const siblings = Array.from(current.parentElement?.children || [])
                        .filter(item => item.localName === tag);
                    const suffix = siblings.length > 1
                        ? ':nth-of-type(' + (siblings.indexOf(current) + 1) + ')'
                        : '';
                    parts.unshift(tag + suffix);
                    current = current.parentElement;
                }
                parts.unshift('body');
                return parts.join(' > ');
            }

            function textMap(root) {
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                    acceptNode(node) {
                        return node.parentElement?.closest('script,style,noscript,template')
                            ? NodeFilter.FILTER_REJECT
                            : NodeFilter.FILTER_ACCEPT;
                    }
                });
                const chars = [];
                const points = [];
                let pendingSpace = null;
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    for (const match of node.data.matchAll(/\P{M}\p{M}*|\p{M}+/gu)) {
                        const source = match[0];
                        const normalized = source.normalize('NFC');
                        const startOffset = match.index;
                        const endOffset = startOffset + source.length;
                        if (/^\s+$/u.test(normalized)) {
                            if (chars.length && chars[chars.length - 1] !== ' ' && !pendingSpace) {
                                pendingSpace = { node, offset: startOffset, endOffset };
                            }
                        } else {
                            if (pendingSpace) {
                                chars.push(' ');
                                points.push(pendingSpace);
                                pendingSpace = null;
                            }
                            for (let index = 0; index < normalized.length; index += 1) {
                                chars.push(normalized[index]);
                                points.push({ node, offset: startOffset, endOffset });
                            }
                        }
                    }
                }
                return { text: chars.join(''), points };
            }

            function makeRange(mapped, start, end) {
                const first = mapped.points[start];
                const last = mapped.points[end - 1];
                if (!first || !last) return null;
                try {
                    const range = document.createRange();
                    range.setStart(first.node, first.offset);
                    range.setEnd(last.node, Math.min(last.node.data.length, last.endOffset));
                    return range;
                } catch {
                    return null;
                }
            }

            function domPoint(container, offset) {
                if (!container) return null;
                if (container.nodeType === Node.TEXT_NODE) {
                    const element = container.parentElement;
                    if (!element) return null;
                    const walker = element.ownerDocument.createTreeWalker(
                        element,
                        NodeFilter.SHOW_TEXT
                    );
                    const textNodes = [];
                    while (walker.nextNode()) textNodes.push(walker.currentNode);
                    return {
                        cssSelector: cssPath(element),
                        textNodeIndex: Math.max(0, textNodes.indexOf(container)),
                        charOffset: Math.max(0, offset)
                    };
                }
                return null;
            }

            function domRange(range) {
                const start = domPoint(range?.startContainer, range?.startOffset);
                if (!start?.cssSelector) return null;
                const end = domPoint(range.endContainer, range.endOffset);
                return { start, ...(end?.cssSelector ? { end } : {}) };
            }

            function segments(text) {
                const output = [];
                const pattern = /[^.!?]+(?:[.!?]+(?=\s|$)|$)/g;
                let match;
                while ((match = pattern.exec(text))) {
                    const leading = match[0].search(/\S/);
                    if (leading < 0) continue;
                    const trimmed = match[0].trimEnd();
                    let start = match.index + leading;
                    const finish = match.index + trimmed.length;
                    while (finish - start > 240) {
                        const limit = start + 220;
                        const split = text.lastIndexOf(' ', limit);
                        const end = split > start + 80 ? split : limit;
                        output.push({ start, end });
                        start = end;
                        while (text[start] === ' ') start += 1;
                    }
                    if (finish - start >= 20) output.push({ start, end: finish });
                }
                return output;
            }

            const viewportX = window.innerWidth / 2;
            const viewportY = window.innerHeight / 2;
            let best = null;
            const blocks = Array.from(document.querySelectorAll(BLOCK_SELECTOR));
            for (const element of blocks) {
                if (SKIP.has(element.tagName)) continue;
                const mapped = textMap(element);
                if (mapped.text.length < 20) continue;
                for (const segment of segments(mapped.text)) {
                    const range = makeRange(mapped, segment.start, segment.end);
                    if (!range) continue;
                    for (const rect of Array.from(range.getClientRects())) {
                        if (rect.width <= 0 || rect.height <= 0) continue;
                        if (rect.bottom <= 0 || rect.top >= window.innerHeight ||
                            rect.right <= 0 || rect.left >= window.innerWidth) continue;
                        const x = (Math.max(0, rect.left) + Math.min(window.innerWidth, rect.right)) / 2;
                        const y = (Math.max(0, rect.top) + Math.min(window.innerHeight, rect.bottom)) / 2;
                        const distance = Math.hypot(x - viewportX, y - viewportY);
                        if (!best || distance < best.distance) {
                            best = { element, mapped, segment, range, distance };
                        }
                    }
                }
            }
            if (!best) return null;

            const exact = best.mapped.text.slice(best.segment.start, best.segment.end).trim();
            if (exact.length < 20) return null;
            const prefix = best.mapped.text
                .slice(Math.max(0, best.segment.start - 64), best.segment.start)
                .trim();
            const suffix = best.mapped.text
                .slice(best.segment.end, Math.min(best.mapped.text.length, best.segment.end + 64))
                .trim();
            return JSON.stringify({
                cssSelector: cssPath(best.element),
                domRange: domRange(best.range),
                textQuote: {
                    exact,
                    prefix: prefix || null,
                    suffix: suffix || null
                }
            });
        })();
    """.trimIndent()

    fun restore(locatorJson: String): String = """
        (function() {
            const target = $locatorJson;
            const locations = target?.locations || {};
            const compact = value => String(value || '')
                .normalize('NFC')
                .replace(/\s+/g, ' ')
                .trim();

            function textMap(root) {
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                    acceptNode(node) {
                        return node.parentElement?.closest('script,style,noscript,template')
                            ? NodeFilter.FILTER_REJECT
                            : NodeFilter.FILTER_ACCEPT;
                    }
                });
                const chars = [];
                const points = [];
                let pendingSpace = null;
                while (walker.nextNode()) {
                    const node = walker.currentNode;
                    for (const match of node.data.matchAll(/\P{M}\p{M}*|\p{M}+/gu)) {
                        const source = match[0];
                        const normalized = source.normalize('NFC');
                        const startOffset = match.index;
                        const endOffset = startOffset + source.length;
                        if (/^\s+$/u.test(normalized)) {
                            if (chars.length && chars[chars.length - 1] !== ' ' && !pendingSpace) {
                                pendingSpace = { node, offset: startOffset, endOffset };
                            }
                        } else {
                            if (pendingSpace) {
                                chars.push(' ');
                                points.push(pendingSpace);
                                pendingSpace = null;
                            }
                            for (let index = 0; index < normalized.length; index += 1) {
                                chars.push(normalized[index]);
                                points.push({ node, offset: startOffset, endOffset });
                            }
                        }
                    }
                }
                return { text: chars.join(''), points };
            }

            function rangeFromTextQuote() {
                const exact = compact(target?.text?.highlight);
                if (!exact) return null;
                let selectedScope = null;
                if (locations.cssSelector) {
                    try {
                        selectedScope = document.querySelector(locations.cssSelector);
                    } catch {}
                }
                function findInScope(scope) {
                    const mapped = textMap(scope);
                    const haystack = mapped.text.toLocaleLowerCase();
                    const needle = exact.toLocaleLowerCase();
                    const prefix = compact(target?.text?.before).toLocaleLowerCase();
                    const suffix = compact(target?.text?.after).toLocaleLowerCase();
                    const matches = [];
                    let cursor = 0;
                    while (cursor <= haystack.length - needle.length) {
                        const offset = haystack.indexOf(needle, cursor);
                        if (offset < 0) break;
                        let score = 0;
                        if (
                            prefix &&
                            haystack.slice(Math.max(0, offset - prefix.length), offset) === prefix
                        ) {
                            score += 2;
                        }
                        if (
                            suffix &&
                            haystack.slice(
                                offset + needle.length,
                                offset + needle.length + suffix.length
                            ) === suffix
                        ) {
                            score += 2;
                        }
                        matches.push({ offset, score });
                        cursor = offset + Math.max(1, needle.length);
                    }
                    const offset = matches.sort((a, b) => b.score - a.score)[0]?.offset ?? -1;
                    if (offset < 0) return null;
                    const first = mapped.points[offset];
                    const last = mapped.points[offset + exact.length - 1];
                    if (!first || !last) return null;
                    const range = document.createRange();
                    range.setStart(first.node, first.offset);
                    range.setEnd(last.node, Math.min(last.node.data.length, last.endOffset));
                    return range;
                }
                return selectedScope
                    ? findInScope(selectedScope) || findInScope(document.body)
                    : findInScope(document.body);
            }

            function domPoint(point) {
                if (!point?.cssSelector) return null;
                const element = document.querySelector(point.cssSelector);
                if (!element) return null;
                const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
                const textNodes = [];
                while (walker.nextNode()) textNodes.push(walker.currentNode);
                const node = textNodes[point.textNodeIndex];
                if (!node) return null;
                const maxOffset = node.data.length;
                return {
                    node,
                    offset: Math.max(0, Math.min(maxOffset, point.charOffset || 0))
                };
            }

            function rangeFromDom() {
                const start = domPoint(locations.domRange?.start);
                if (!start) return null;
                const end = domPoint(locations.domRange?.end) || start;
                try {
                    const range = document.createRange();
                    range.setStart(start.node, start.offset);
                    range.setEnd(end.node, end.offset);
                    return range;
                } catch {
                    return null;
                }
            }

            const range = rangeFromTextQuote() || rangeFromDom();
            if (range) {
                const marker = document.createElement('span');
                marker.setAttribute('aria-hidden', 'true');
                marker.style.cssText = 'display:inline-block;width:0;height:0;overflow:hidden';
                const insertion = range.cloneRange();
                insertion.collapse(true);
                insertion.insertNode(marker);
                const parent = marker.parentNode;
                marker.scrollIntoView({ block: 'center', inline: 'center' });
                marker.remove();
                parent?.normalize();
                return 'true';
            }
            const element = locations.cssSelector
                ? document.querySelector(locations.cssSelector)
                : null;
            if (!element) return 'false';
            element.scrollIntoView({ block: 'center', inline: 'center' });
            return 'true';
        })();
    """.trimIndent()
}
