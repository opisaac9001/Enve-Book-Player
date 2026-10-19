import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

enum ReadiumNoteLinkResolver {
    struct Note {
        let content: String
        let referrer: String?
    }

    static func note(
        for link: ReadiumShared.Link,
        publication: Publication,
        navigator: EPUBNavigatorViewController
    ) async -> Note? {
        guard let url = AnyURL(string: link.href),
            let fragment = url.fragment,
            !fragment.isEmpty,
            let resource = publication.get(url.removingFragment()),
            let markup = try? await resource.read().asString().get(),
            let script = script(href: link.href, fragment: fragment, markup: markup),
            case .success(let value) = await navigator.evaluateJavaScript(script),
            let result = value as? [String: Any],
            let content = result["content"] as? String,
            !content.isEmpty
        else {
            return nil
        }
        return Note(content: content, referrer: result["referrer"] as? String)
    }

    private static func script(href: String, fragment: String, markup: String) -> String? {
        let encoder = JSONEncoder()
        guard let hrefData = try? encoder.encode(href.removingPercentEncoding ?? href),
            let fragmentData = try? encoder.encode(fragment.removingPercentEncoding ?? fragment),
            let markupData = try? encoder.encode(markup),
            let encodedHref = String(data: hrefData, encoding: .utf8),
            let encodedFragment = String(data: fragmentData, encoding: .utf8),
            let encodedMarkup = String(data: markupData, encoding: .utf8)
        else {
            return nil
        }
        return """
            (() => {
                const href = \(encodedHref);
                const fragment = \(encodedFragment);
                const tokens = value => new Set((value ?? '').split(/\\s+/).filter(Boolean));
                const semantics = element => ({
                    types: tokens(element.getAttribute('epub:type')
                        ?? element.getAttributeNS?.('http://www.idpf.org/2007/ops', 'type')),
                    roles: tokens(element.getAttribute('role')),
                });
                const decoded = value => { try { return decodeURIComponent(value); } catch { return value; } };
                const anchor = Array.from(document.querySelectorAll('a[href]')).find(element => {
                    try {
                        const target = new URL(element.href);
                        return decoded(target.pathname + target.hash).endsWith('/' + href.replace(/^\\/+/, ''));
                    } catch {
                        return false;
                    }
                });
                const anchorSemantics = anchor ? semantics(anchor) : { types: new Set(), roles: new Set() };
                if (anchorSemantics.types.has('backlink') || anchorSemantics.roles.has('doc-backlink')) return null;
                const anchorIsNoteRef = ['noteref', 'biblioref', 'glossref'].some(type => anchorSemantics.types.has(type))
                    || ['doc-noteref', 'doc-biblioref', 'doc-glossref'].some(role => anchorSemantics.roles.has(role));

                const markup = \(encodedMarkup);
                let doc = new DOMParser().parseFromString(markup, 'application/xhtml+xml');
                if (doc.getElementsByTagName('parsererror').length) {
                    doc = new DOMParser().parseFromString(markup, 'text/html');
                }
                const target = doc.getElementById(fragment);
                if (!target) return null;
                const noteTypes = ['footnote', 'endnote', 'rearnote', 'note', 'footnotes', 'endnotes', 'rearnotes'];
                const noteRoles = ['doc-footnote', 'doc-endnote', 'doc-endnotes', 'note'];
                let targetIsNote = target.localName === 'aside';
                for (let element = target; element && !targetIsNote && element.localName !== 'body'; element = element.parentElement) {
                    const { types, roles } = semantics(element);
                    targetIsNote = noteTypes.some(type => types.has(type)) || noteRoles.some(role => roles.has(role));
                }
                if (!anchorIsNoteRef && !targetIsNote) return null;
                return { content: target.innerHTML, referrer: anchor ? anchor.innerHTML : null };
            })()
            """
    }
}
