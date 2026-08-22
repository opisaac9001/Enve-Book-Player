import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import UIKit

struct ReaderSelectionSnapshot: Equatable {
    let locator: Locator
    let locatorJSON: String
    let frame: CGRect?
    let epubCFI: String?

    init(
        locator: Locator,
        locatorJSON: String? = nil,
        frame: CGRect?,
        epubCFI: String? = nil
    ) {
        self.locator = locator
        self.locatorJSON = locatorJSON ?? (try? locator.jsonString()) ?? ""
        self.frame = frame
        self.epubCFI = epubCFI ?? EpubLocationBridge.epubCFI(from: self.locatorJSON)
    }

    init(_ selection: Selection) {
        self.init(locator: selection.locator, frame: selection.frame)
    }
}

struct ReaderEngineRelocation: Equatable {
    let locator: Locator
    let locatorJSON: String
    let visiblePageRange: ClosedRange<Int>?
    let isUserInitiated: Bool

    init(
        locator: Locator,
        locatorJSON: String,
        visiblePageRange: ClosedRange<Int>?,
        isUserInitiated: Bool = false
    ) {
        self.locator = locator
        self.locatorJSON = locatorJSON
        self.visiblePageRange = visiblePageRange
        self.isUserInitiated = isUserInitiated
    }
}

enum ReaderEngineCapability: String, CaseIterable, Hashable, Sendable {
    case annotations
    case autoScroll
    case bionic
    case externalLinks
    case location
    case navigation
    case pageText
    case preferences
    case progressFlush
    case search
    case selection
    case toc
}

@MainActor
protocol ReaderEngineAdapter: AnyObject {
    var kind: ReaderEngineKind { get }
    var viewController: UIViewController { get }
    var capabilities: Set<ReaderEngineCapability> { get }
    var currentLocatorJSON: String? { get }
    var currentSelection: ReaderSelectionSnapshot? { get }

    var onRelocation: ((ReaderEngineRelocation) -> Void)? { get set }
    var onSelectionChange: ((ReaderSelectionSnapshot?) -> Void)? { get set }
    var onAnnotationActivated: ((String) -> Void)? { get set }
    var onTap: ((CGPoint, CGSize) -> Void)? { get set }
    var onExternalLink: ((URL) -> Void)? { get set }

    func restore(locatorJSON: String, animated: Bool) async -> Bool
    func navigate(to locator: Locator, animated: Bool) async -> Bool
    func navigate(toHref href: String, animated: Bool) async -> Bool
    func navigate(toFraction fraction: Double, animated: Bool) async -> Bool
    func pageForward(animated: Bool) async -> Bool
    func pageBackward(animated: Bool) async -> Bool
    func clearSelection()
    func applyAppearance(_ appearance: ClassicReaderAppearance) async
    func updateAnnotations(_ annotations: [ReaderAnnotation]) async
    func search(query: String) async -> [EbookSearchResult]
    func clearSearch() async
    func setAutoScroll(pointsPerSecond: Double) async
    func currentPageText() async -> String?
    func flushPosition() async -> String?
    func ttsLocator(at point: CGPoint?) async -> Locator?
    func applyTTSDecoration(locatorJSON: String?) async
    func followTTS(locatorJSON: String) async
    func tearDown()
}

enum ReadiumPortableAnchorScript {
    static func restore(locatorJSON: String) -> String? {
        guard let data = locatorJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let canonicalData = try? JSONSerialization.data(withJSONObject: object),
            let canonicalJSON = String(data: canonicalData, encoding: .utf8)
        else {
            return nil
        }
        return #"""
            (function() {
                const target = \#(canonicalJSON);
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
                    let element = null;
                    try {
                        element = document.querySelector(point.cssSelector);
                    } catch {}
                    if (!element) return null;
                    const node = element.childNodes?.[point.textNodeIndex];
                    if (node?.nodeType !== Node.TEXT_NODE) return null;
                    return {
                        node,
                        offset: Math.max(0, Math.min(node.data.length, point.charOffset || 0))
                    };
                }

                function rangeFromDOM() {
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

                const range = rangeFromTextQuote() || rangeFromDOM();
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
                let element = null;
                if (locations.cssSelector) {
                    try {
                        element = document.querySelector(locations.cssSelector);
                    } catch {}
                }
                if (!element) return 'false';
                element.scrollIntoView({ block: 'center', inline: 'center' });
                return 'true';
            })();
            """#
    }
}

enum ReadiumTTSLocatorScript {
    static func make(point: CGPoint?) -> String {
        let requestedPoint = point.map { "{ x: \($0.x), y: \($0.y) }" } ?? "null"
        return """
            (() => {
                const requestedPoint = \(requestedPoint);
                const blockTags = new Set([
                    'article', 'aside', 'blockquote', 'caption', 'details', 'dialog', 'div',
                    'dl', 'dt', 'dd', 'figure', 'footer', 'form', 'figcaption', 'h1', 'h2',
                    'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'li', 'main', 'nav', 'ol',
                    'p', 'pre', 'section', 'tr'
                ]);
                const cssPath = element => {
                    if (!(element instanceof Element)) return null;
                    if (element.id) return `#${CSS.escape(element.id)}`;
                    const parts = [];
                    for (let current = element; current && current.nodeType === Node.ELEMENT_NODE; current = current.parentElement) {
                        const name = current.localName;
                        if (!name) return null;
                        const parent = current.parentElement;
                        if (!parent) { parts.unshift(name); break; }
                        const siblings = Array.from(parent.children).filter(item => item.localName === name);
                        const suffix = siblings.length > 1 ? `:nth-of-type(${siblings.indexOf(current) + 1})` : '';
                        parts.unshift(`${name}${suffix}`);
                    }
                    return parts.join(' > ');
                };
                const nearestBlock = node => {
                    let element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
                    const fallback = element;
                    while (element && element !== document.body) {
                        if (blockTags.has(element.localName?.toLowerCase())) return element;
                        element = element.parentElement;
                    }
                    return fallback;
                };
                const isVisible = rect => rect.right > 0 && rect.left < innerWidth && rect.bottom > 0 && rect.top < innerHeight;
                const firstVisiblePoint = () => {
                    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                    while (walker.nextNode()) {
                        const node = walker.currentNode;
                        if (!node.data.trim()) continue;
                        const whole = document.createRange();
                        whole.selectNodeContents(node);
                        if (!Array.from(whole.getClientRects()).some(isVisible)) continue;
                        for (let offset = 0; offset < node.data.length; offset += 1) {
                            if (/\\s/u.test(node.data[offset])) continue;
                            const character = document.createRange();
                            character.setStart(node, offset);
                            character.setEnd(node, offset + 1);
                            if (Array.from(character.getClientRects()).some(isVisible)) return { node, offset };
                        }
                    }
                    return null;
                };
                const caretPoint = point => {
                    const position = document.caretPositionFromPoint?.(point.x, point.y);
                    if (position) return { node: position.offsetNode, offset: position.offset };
                    const range = document.caretRangeFromPoint?.(point.x, point.y);
                    return range ? { node: range.startContainer, offset: range.startOffset } : null;
                };
                const pointAtOffset = (element, target) => {
                    const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
                    let consumed = 0;
                    while (walker.nextNode()) {
                        const node = walker.currentNode;
                        if (consumed + node.data.length >= target) return { node, offset: target - consumed };
                        consumed += node.data.length;
                    }
                    return null;
                };
                let point = requestedPoint ? caretPoint(requestedPoint) : firstVisiblePoint();
                if (!point) return null;
                let block = nearestBlock(point.node);
                if (!block) return null;
                if (requestedPoint) {
                    const before = document.createRange();
                    before.selectNodeContents(block);
                    try { before.setEnd(point.node, point.offset); } catch { return null; }
                    const offset = before.toString().length;
                    const text = block.textContent ?? '';
                    const language = block.lang || document.documentElement.lang || 'en';
                    const segments = Array.from(new Intl.Segmenter(language, { granularity: 'sentence' }).segment(text));
                    const sentence = segments.find(item => offset >= item.index && offset <= item.index + item.segment.length);
                    const sentencePoint = sentence ? pointAtOffset(block, sentence.index) : null;
                    if (sentencePoint) point = sentencePoint;
                }
                const marker = document.createRange();
                marker.setStart(point.node, point.offset);
                marker.selectNodeContents(block);
                marker.setStart(point.node, point.offset);
                const exact = marker.toString().replace(/\\s+/gu, ' ').trim().slice(0, 160);
                const cssSelector = cssPath(block);
                return cssSelector && exact ? { cssSelector, exact } : null;
            })()
            """
    }
}

@MainActor
final class ReadiumReaderEngineAdapter: ReaderEngineAdapter {
    let navigator: EPUBNavigatorViewController
    let publication: Publication

    var onRelocation: ((ReaderEngineRelocation) -> Void)?
    var onSelectionChange: ((ReaderSelectionSnapshot?) -> Void)?
    var onAnnotationActivated: ((String) -> Void)?
    var onTap: ((CGPoint, CGSize) -> Void)?
    var onExternalLink: ((URL) -> Void)?

    private let keyboardNavigation = DirectionalNavigationAdapter(pointerPolicy: .init(types: []))

    init(navigator: EPUBNavigatorViewController, publication: Publication) {
        self.navigator = navigator
        self.publication = publication
        keyboardNavigation.bind(to: navigator)
    }

    var kind: ReaderEngineKind { .readium }
    var viewController: UIViewController { navigator }
    var capabilities: Set<ReaderEngineCapability> { Set(ReaderEngineCapability.allCases) }
    var currentLocatorJSON: String? {
        navigator.currentLocation.flatMap { try? $0.jsonString() }
    }
    var currentSelection: ReaderSelectionSnapshot? {
        navigator.currentSelection.map(ReaderSelectionSnapshot.init)
    }

    func restore(locatorJSON: String, animated: Bool) async -> Bool {
        guard let safeLocatorJSON = EpubLocationBridge.locatorForReadiumRestore(locatorJSON),
            let locator = try? Locator(jsonString: safeLocatorJSON)
        else {
            return false
        }
        return await navigator.go(to: locator, options: .init(animated: animated))
    }

    func navigate(to locator: Locator, animated: Bool) async -> Bool {
        await navigator.go(to: locator, options: .init(animated: animated))
    }

    func navigate(toHref href: String, animated: Bool) async -> Bool {
        await navigator.go(to: Link(href: href), options: .init(animated: animated))
    }

    func navigate(toFraction fraction: Double, animated: Bool) async -> Bool {
        let bounded = min(max(fraction, 0), 1)
        guard let positions = try? await publication.positions().get(),
            let locator = positions.last(where: {
                ($0.locations.totalProgression ?? 0) <= bounded
            })
        else {
            return false
        }
        return await navigator.go(to: locator, options: .init(animated: animated))
    }

    func pageForward(animated: Bool) async -> Bool {
        await navigator.goForward(options: .init(animated: animated))
    }

    func pageBackward(animated: Bool) async -> Bool {
        await navigator.goBackward(options: .init(animated: animated))
    }

    func clearSelection() {
        navigator.clearSelection()
        onSelectionChange?(nil)
    }

    func applyAppearance(_ appearance: ClassicReaderAppearance) async {
        navigator.submitPreferences(appearance.readiumPreferences)
    }

    func updateAnnotations(_ annotations: [ReaderAnnotation]) async {}

    func search(query: String) async -> [EbookSearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let service = publication.findService(SearchService.self),
            let iterator = try? await service.search(query: query, options: nil).get()
        else {
            return []
        }
        var results: [EbookSearchResult] = []
        do {
            while let collection = try await iterator.next().get() {
                results.append(
                    contentsOf: collection.locators.map { locator in
                        EbookSearchResult(
                            text: locator.text.highlight ?? query,
                            locator: locator,
                            chapterTitle: locator.title,
                            contextBefore: locator.text.before ?? "",
                            contextAfter: locator.text.after ?? ""
                        )
                    }
                )
            }
        } catch {
            return results
        }
        return results
    }

    func clearSearch() async {}

    func setAutoScroll(pointsPerSecond: Double) async {}

    func currentPageText() async -> String? {
        let script = "document.body?.innerText?.replace(/\\s+/g, ' ').trim().slice(0, 10000) ?? ''"
        guard case .success(let result) = await navigator.evaluateJavaScript(script) else {
            return nil
        }
        return result as? String
    }

    func flushPosition() async -> String? {
        currentLocatorJSON
    }

    func ttsLocator(at point: CGPoint?) async -> Locator? {
        guard let base = navigator.currentLocation,
            case .success(let value) = await navigator.evaluateJavaScript(
                ReadiumTTSLocatorScript.make(point: point)
            ),
            let result = value as? [String: Any],
            Set(result.keys) == ["cssSelector", "exact"],
            let selector = result["cssSelector"] as? String,
            let exact = result["exact"] as? String,
            !selector.isEmpty,
            !exact.isEmpty
        else {
            return await navigator.firstVisibleElementLocator() ?? navigator.currentLocation
        }
        return base.copy(
            locations: { $0.otherLocations["cssSelector"] = .string(selector) },
            text: { $0 = Locator.Text(highlight: exact) }
        )
    }

    func applyTTSDecoration(locatorJSON: String?) async {
        guard let locatorJSON,
            let locator = try? Locator(jsonString: locatorJSON)
        else {
            navigator.apply(decorations: [], in: "tts-highlight")
            return
        }
        let style = Decoration.Style.highlight(
            tint: UIColor.systemBlue.withAlphaComponent(0.4),
            isActive: true
        )
        navigator.apply(
            decorations: [Decoration(id: "tts-current", locator: locator, style: style)],
            in: "tts-highlight"
        )
    }

    func followTTS(locatorJSON: String) async {
        guard let locator = try? Locator(jsonString: locatorJSON) else { return }
        if navigator.currentLocation?.href == locator.href,
            let selector = locator.locations["cssSelector"]?.string,
            let data = try? JSONEncoder().encode(selector),
            let encodedSelector = String(data: data, encoding: .utf8),
            let quoteData = try? JSONEncoder().encode(locator.text.highlight ?? ""),
            let encodedQuote = String(data: quoteData, encoding: .utf8)
        {
            let script = """
                (() => {
                    let element;
                    try { element = document.querySelector(\(encodedSelector)); }
                    catch { return false; }
                    if (!element) return false;
                    const quote = \(encodedQuote);
                    let target = element;
                    if (quote) {
                        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
                        const entries = [];
                        let text = '';
                        while (walker.nextNode()) {
                            const node = walker.currentNode;
                            entries.push({ node, start: text.length, end: text.length + node.data.length });
                            text += node.data;
                        }
                        const start = text.indexOf(quote);
                        const end = start + quote.length;
                        const first = entries.find(entry => start >= entry.start && start < entry.end);
                        const last = entries.find(entry => end > entry.start && end <= entry.end);
                        if (start >= 0 && first && last) {
                            const range = document.createRange();
                            range.setStart(first.node, start - first.start);
                            range.setEnd(last.node, end - last.start);
                            target = range;
                        }
                    }
                    return Array.from(target.getClientRects()).some(rect =>
                        rect.right > 0 && rect.left < innerWidth &&
                        rect.bottom > 0 && rect.top < innerHeight
                    );
                })()
                """
            if case .success(let value) = await navigator.evaluateJavaScript(script),
                value as? Bool == true
            {
                return
            }
        }
        _ = await navigator.go(to: locator, options: .init(animated: false))
    }

    func tearDown() {}
}
