#if !os(tvOS)
import Foundation

nonisolated struct WebStoryChapter: Codable, Hashable, Identifiable, Sendable {
    let title: String
    let url: URL

    var id: String {
        if let chapter = url.path.range(of: #"/chapter/(\d+)"#, options: .regularExpression) {
            return "\(url.host ?? ""):\(url.path[chapter])"
        }
        return url.absoluteString
    }
}

nonisolated struct WebStoryPreview: Sendable {
    let title: String
    let author: String?
    let siteName: String
    let sourceURL: URL
    let excerpt: String
    let wordCount: Int
    let chapters: [WebStoryChapter]
    let currentChapterIndex: Int
    let isStoryIndex: Bool
    let isDirectFile: Bool
}

nonisolated struct WebStoryPage: Codable, Sendable {
    let url: URL
    let title: String
    let storyTitle: String
    let author: String?
    let siteName: String
    let language: String
    let excerpt: String
    let html: String
    let wordCount: Int
    let storyURL: URL?
    let chapters: [WebStoryChapter]

    var chapter: WebStoryChapter { WebStoryChapter(title: title, url: url) }
}

nonisolated enum WebStoryExtraction {
    static let script = #"""
    return await (async () => {
        const pageURL = new URL(location.href);
        const royalRoad = /(^|\.)royalroad\.com$/i.test(pageURL.hostname);
        const fictionID = pageURL.pathname.match(/^\/fiction\/(\d+)(?:\/|$)/)?.[1];
        const clean = value => (value || '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '').replace(/\s+/g, ' ').trim();
        const meta = (...names) => {
            for (const name of names) {
                const element = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`);
                if (element?.content) return clean(element.content);
            }
            return '';
        };
        const absolute = value => {
            try {
                const url = new URL(value, document.baseURI);
                if (!/^https?:$/.test(url.protocol) || url.username || url.password) return null;
                url.hash = '';
                return url;
            } catch { return null; }
        };
        const text = selector => clean(document.querySelector(selector)?.textContent);
        const storyLink = royalRoad ? [...document.querySelectorAll('a[href*="/fiction/"]')].find(a => {
            const url = absolute(a.getAttribute('href'));
            const match = url?.pathname.match(/^\/fiction\/(\d+)(?:\/[^/]+)?\/?$/);
            return url?.origin === pageURL.origin && match && (!fictionID || match[1] === fictionID) && clean(a.textContent) && !/fiction page/i.test(a.textContent);
        }) : document.querySelector('a[rel~="up"][href]');
        const linkedStory = storyLink ? absolute(storyLink.getAttribute('href')) : null;
        const storyURL = linkedStory?.origin === pageURL.origin ? linkedStory : null;
        const isStoryIndex = royalRoad && !/\/chapter\/\d+/.test(pageURL.pathname);
        const heading = text('.chapter-title, .fic-header h1, h1');
        const title = heading || meta('og:title', 'twitter:title') || clean(document.title) || clean(pageURL.pathname.split('/').pop()) || pageURL.hostname;
        const storyTitle = royalRoad ? (isStoryIndex ? text('.fic-title h1, h1') : clean(storyLink?.textContent)) || title : title;
        const author = text('.fic-title h4 a, .fic-title a[href*="/profile/"], .fic-header a[href*="/profile/"]') || meta('author', 'article:author') || null;
        const chapters = [];
        const visited = new Set();
        const collectChapters = () => {
            for (const a of document.querySelectorAll('#chapters a[href*="/chapter/"], .chapter-row a[href*="/chapter/"]')) {
                const url = absolute(a.getAttribute('href'));
                const match = url?.pathname.match(/\/chapter\/(\d+)/);
                const linkedFiction = url?.pathname.match(/^\/fiction\/(\d+)(?:\/|$)/)?.[1];
                if (!match || url.origin !== pageURL.origin || visited.has(match[1]) || (fictionID && linkedFiction && fictionID !== linkedFiction)) continue;
                visited.add(match[1]);
                chapters.push({ title: clean(a.textContent) || `Chapter ${chapters.length + 1}`, url: url.href });
            }
        };
        const chapterContainer = royalRoad ? document.querySelector('#chapters')?.parentElement : null;
        const pagination = () => chapterContainer?.querySelector('ul.pagination-small');
        const activePage = () => Number(clean(pagination()?.querySelector('.page-active a')?.textContent));
        const pageSignature = () => [...(chapterContainer?.querySelectorAll('#chapters a[href*="/chapter/"]') || [])].map(a => a.getAttribute('href')).join('|');
        const turnPage = (link, target) => new Promise((resolve, reject) => {
            const previous = pageSignature();
            const observer = new MutationObserver(() => {
                if (activePage() === target && pageSignature() && pageSignature() !== previous) {
                    observer.disconnect();
                    clearTimeout(timeout);
                    resolve();
                }
            });
            const timeout = setTimeout(() => {
                observer.disconnect();
                reject(new Error('The chapter list could not be loaded.'));
            }, 5000);
            observer.observe(chapterContainer, { childList: true, subtree: true });
            link.click();
        });
        if (pagination() && activePage() > 1) {
            const first = [...pagination().querySelectorAll('a')].find(a => clean(a.textContent) === '1');
            if (!first) throw new Error('The first chapter page is unavailable.');
            await turnPage(first, 1);
        }
        for (let page = 0; page < 1000; page++) {
            collectChapters();
            const next = pagination()?.querySelector('.nav-arrow:not(.disabled) a:has(.fa-chevron-right)');
            if (!next) break;
            if (page === 999) throw new Error('The chapter list is too large to import.');
            await turnPage(next, activePage() + 1);
        }
        const candidates = royalRoad
            ? [...document.querySelectorAll('.chapter-content')]
            : [...document.querySelectorAll('article, [itemprop="articleBody"], .entry-content, .post-content, main, [role="main"]')];
        const excluded = /(^|[\s_-])(comments?|advertisements?|ads|social|related|recommendations?|sidebar|cookie|newsletter|menu|modal|navigation)([\s_-]|$)/i;
        const drop = new Set(['script', 'style', 'noscript', 'iframe', 'object', 'embed', 'form', 'input', 'button', 'select', 'textarea', 'svg', 'canvas', 'video', 'audio', 'template', 'link', 'meta', 'nav', 'aside', 'footer']);
        const keep = new Set(['p', 'br', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'blockquote', 'pre', 'code', 'em', 'strong', 'b', 'i', 'u', 's', 'sub', 'sup', 'small', 'a', 'ul', 'ol', 'li', 'dl', 'dt', 'dd', 'figure', 'figcaption', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'th', 'td', 'caption', 'abbr', 'cite', 'q', 'span', 'div', 'section']);
        const styles = new WeakMap();
        const hidden = element => {
            if (styles.has(element)) return styles.get(element);
            const style = getComputedStyle(element);
            const value = element.hidden || element.getAttribute('aria-hidden') === 'true' ||
                style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' || style.opacity === '0' ||
                (element.parentElement ? hidden(element.parentElement) : false);
            styles.set(element, value);
            return value;
        };
        const namespace = 'http://www.w3.org/1999/xhtml';
        let nodeCount = 0;
        const copy = (node, parent) => {
            if (++nodeCount > 100000) throw new Error('This page is too large to import.');
            if (node.nodeType === Node.TEXT_NODE) {
                parent.appendChild(document.createTextNode((node.nodeValue || '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, '')));
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            const tag = node.localName.toLowerCase();
            if (drop.has(tag) || hidden(node) || excluded.test(`${node.id} ${typeof node.className === 'string' ? node.className : ''}`)) return;
            if (tag === 'h1' && clean(node.textContent) === title) return;
            if (tag === 'img') {
                const alt = clean(node.getAttribute('alt'));
                if (alt) parent.appendChild(document.createTextNode(alt));
                return;
            }
            let destination = parent;
            if (keep.has(tag)) {
                destination = document.createElementNS(namespace, tag === 'section' ? 'div' : tag);
                if (node.id) destination.setAttribute('id', node.id);
                if (tag === 'a') {
                    const href = absolute(node.getAttribute('href'));
                    if (href) destination.setAttribute('href', href.href);
                }
                for (const attribute of ['colspan', 'rowspan', 'start']) {
                    const value = node.getAttribute(attribute);
                    if (value && /^\d{1,4}$/.test(value)) destination.setAttribute(attribute, value);
                }
                parent.appendChild(destination);
            }
            for (const child of node.childNodes) copy(child, destination);
        };
        let best = null;
        let bestScore = 0;
        for (const candidate of candidates) {
            if (hidden(candidate)) continue;
            const length = clean(candidate.textContent).length;
            const links = [...candidate.querySelectorAll('a')].reduce((sum, a) => sum + clean(a.textContent).length, 0);
            const score = length - links * 2;
            if (score > bestScore) { best = candidate; bestScore = score; }
        }
        if (!best && !royalRoad && document.body?.querySelectorAll('p').length >= 2) best = document.body;
        if (!best && document.contentType === 'text/plain') best = document.querySelector('pre') || document.body;
        const result = document.createElementNS(namespace, 'div');
        if (best) copy(best, result);
        const readable = clean(result.textContent);
        const html = readable.length >= 40 ? new XMLSerializer().serializeToString(result) : '';
        return JSON.stringify({
            url: pageURL.href,
            title,
            storyTitle,
            author,
            siteName: royalRoad ? 'Royal Road' : meta('og:site_name') || pageURL.hostname.replace(/^www\./, ''),
            language: document.documentElement.lang || 'en',
            excerpt: royalRoad && isStoryIndex ? text('.description') || meta('og:description', 'description') : readable.slice(0, 500),
            html,
            wordCount: readable ? readable.split(/\s+/).length : 0,
            storyURL: storyURL?.href || null,
            chapters
        });
    })()
    """#
}
#endif
