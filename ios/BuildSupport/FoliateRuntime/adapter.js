import { makeBook } from './foliate/view.js'
import { EPUB } from './foliate/epub.js'
import { Overlayer } from './foliate/overlayer.js'
import { FootnoteHandler } from './foliate/footnotes.js'

const BRIDGE_VERSION = 1
const REQUIRED_CAPABILITIES = Object.freeze([
    'annotations',
    'autoScroll',
    'bionic',
    'externalLinks',
    'location',
    'navigation',
    'pageText',
    'preferences',
    'progressFlush',
    'search',
    'selection',
    'toc',
])
const params = new URLSearchParams(location.search)
const capability = params.get('capability') ?? ''
const handlerName = params.get('handler') ?? ''
const nativeHandler = globalThis.webkit?.messageHandlers?.[handlerName]

let outgoingSequence = 0
let incomingSequence = 0
let view = null
let book = null
let preferences = null
let lastPosition = null
let lastRelocationReason = null
let pendingRendererRelocationReason = null
let lastSelection = null
let lastVisibleRange = null
let autoScrollFrame = 0
let autoScrollSpeed = 0
let autoScrollPreviousTime = 0
let selectionTimer = 0
let initialized = false
let activeFootnote = null
const ttsAnnotationKey = 'enve-tts-current'
const annotationByCFI = new Map()
const drawnAnnotationCFIs = new Set()
const selectionCleanups = []
const ttsBlockTags = new Set([
    'article', 'aside', 'audio', 'blockquote', 'caption',
    'details', 'dialog', 'div', 'dl', 'dt', 'dd',
    'figure', 'footer', 'form', 'figcaption',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hgroup', 'hr', 'li',
    'main', 'math', 'nav', 'ol', 'p', 'pre', 'section', 'tr',
])

const isRecord = value =>
    value !== null && typeof value === 'object' && !Array.isArray(value)

const hasExactKeys = (value, keys) =>
    isRecord(value)
    && Object.keys(value).length === keys.length
    && keys.every(key => Object.hasOwn(value, key))

const boundedNumber = (value, minimum, maximum) => {
    if (typeof value !== 'number' || !Number.isFinite(value)) {
        throw new TypeError('Expected a finite number')
    }
    return Math.min(maximum, Math.max(minimum, value))
}

const optionalString = value => {
    if (value === null) return null
    if (typeof value !== 'string') throw new TypeError('Expected a string or null')
    return value
}

const post = (type, payload) => {
    if (!nativeHandler || !capability || !handlerName) return
    nativeHandler.postMessage({
        version: BRIDGE_VERSION,
        capability,
        sequence: ++outgoingSequence,
        type,
        payload,
    })
}

const postError = error => {
    const message = error instanceof Error ? error.message : String(error)
    post('error', { message: message.slice(0, 500) })
}

const normalizeHref = href => {
    const path = String(href ?? '').split('#', 1)[0]
    const relative = path.startsWith('./') ? path.slice(2) : path
    try {
        return decodeURIComponent(relative)
    } catch {
        return relative
    }
}

const htmlIDFromFragment = value => {
    if (typeof value !== 'string') return null
    const trimmed = value.trim()
    if (!trimmed || trimmed.startsWith('epubcfi(')) return null
    const fragment = trimmed.startsWith('#') ? trimmed.slice(1) : trimmed
    if (!fragment || /[\s=]/u.test(fragment)) return null
    try {
        return decodeURIComponent(fragment)
    } catch {
        return fragment
    }
}

const cssPath = element => {
    if (!element || element.nodeType !== Node.ELEMENT_NODE) return null
    if (element.id) return `#${CSS.escape(element.id)}`
    const parts = []
    let current = element
    while (current && current.nodeType === Node.ELEMENT_NODE) {
        const name = current.localName
        if (!name) return null
        const parent = current.parentElement
        if (!parent) {
            parts.unshift(name)
            break
        }
        const siblings = Array.from(parent.children)
            .filter(sibling => sibling.localName === name)
        const suffix = siblings.length > 1
            ? `:nth-of-type(${siblings.indexOf(current) + 1})`
            : ''
        parts.unshift(`${name}${suffix}`)
        current = parent
    }
    return parts.join(' > ')
}

const nearestTTSBlock = node => {
    let element = node?.nodeType === Node.ELEMENT_NODE
        ? node
        : node?.parentElement
    const fallback = element
    while (element && element !== element.ownerDocument?.body) {
        if (ttsBlockTags.has(element.localName?.toLowerCase())) return element
        element = element.parentElement
    }
    return fallback
}

const domPoint = (container, offset) => {
    if (container?.nodeType !== Node.TEXT_NODE) return null
    const parent = container.parentElement
    const selector = cssPath(parent)
    if (!parent || !selector) return null
    const textNodeIndex = Array.from(parent.childNodes).indexOf(container)
    if (textNodeIndex < 0) return null
    return {
        cssSelector: selector,
        textNodeIndex,
        charOffset: Math.max(0, Math.min(container.data.length, offset)),
    }
}

const contextForRange = range => {
    const body = range?.startContainer?.ownerDocument?.body
    if (!body || !range || range.collapsed) {
        return { exact: null, prefix: null, suffix: null }
    }
    try {
        const before = body.ownerDocument.createRange()
        before.selectNodeContents(body)
        before.setEnd(range.startContainer, range.startOffset)
        const after = body.ownerDocument.createRange()
        after.selectNodeContents(body)
        after.setStart(range.endContainer, range.endOffset)
        const exact = range.toString()
        return {
            exact: exact || null,
            prefix: before.toString().slice(-32) || null,
            suffix: after.toString().slice(0, 32) || null,
        }
    } catch {
        return { exact: null, prefix: null, suffix: null }
    }
}

const firstTextRange = visibleRange => {
    const doc = visibleRange?.startContainer?.ownerDocument
        ?? (visibleRange?.startContainer?.nodeType === Node.DOCUMENT_NODE
            ? visibleRange.startContainer
            : null)
    if (!doc?.body || !visibleRange) return null
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
    let startNode = null
    let startOffset = 0
    while (walker.nextNode()) {
        const node = walker.currentNode
        try {
            if (!visibleRange.intersectsNode(node)) continue
        } catch {
            continue
        }
        const boundary = node === visibleRange.startContainer
            ? visibleRange.startOffset
            : 0
        const whitespaceOffset = node.data.slice(boundary).search(/\S/)
        if (whitespaceOffset < 0) continue
        startNode = node
        startOffset = boundary + whitespaceOffset
        break
    }
    if (!startNode) return null

    const result = doc.createRange()
    result.setStart(startNode, startOffset)
    let remaining = 160
    let endNode = startNode
    let endOffset = startOffset
    const tail = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
    tail.currentNode = startNode
    while (endNode) {
        const available = endNode.data.length - endOffset
        if (available >= remaining) {
            result.setEnd(endNode, endOffset + remaining)
            return result
        }
        remaining -= Math.max(0, available)
        const next = tail.nextNode()
        if (!next) {
            result.setEnd(endNode, endNode.data.length)
            return result
        }
        endNode = next
        endOffset = 0
    }
    return result
}

const sectionIndexForDocument = doc =>
    view?.renderer?.getContents?.().find(item => item.doc === doc)?.index

const sectionHref = index =>
    normalizeHref(book?.sections?.[index]?.id ?? '')

const resourceProgression = (index, totalProgression) => {
    const fractions = view?.getSectionFractions?.() ?? []
    const start = fractions[index]
    const end = fractions[index + 1]
    if (Number.isFinite(totalProgression)
        && Number.isFinite(start)
        && Number.isFinite(end)
        && end > start) {
        return boundedNumber((totalProgression - start) / (end - start), 0, 1)
    }
    const renderer = view?.renderer
    if (renderer?.scrolled
        && Number.isFinite(renderer.start)
        && Number.isFinite(renderer.viewSize)
        && renderer.viewSize > 0) {
        return boundedNumber(renderer.start / renderer.viewSize, 0, 1)
    }
    if (Number.isFinite(renderer?.page)
        && Number.isFinite(renderer?.pages)
        && renderer.pages > 2) {
        return boundedNumber((renderer.page - 1) / (renderer.pages - 2), 0, 1)
    }
    return null
}

const totalProgressionFor = (index, resourceProgression) => {
    const sections = book?.sections ?? []
    const weights = sections.map(section =>
        Number.isFinite(section?.size) && section.size > 0 ? section.size : 1
    )
    const total = weights.reduce((sum, value) => sum + value, 0)
    if (!Number.isFinite(total) || total <= 0) return null
    const before = weights
        .slice(0, index)
        .reduce((sum, value) => sum + value, 0)
    return boundedNumber(
        (before + (resourceProgression ?? 0) * (weights[index] ?? 0)) / total,
        0,
        1
    )
}

const positionForRange = (
    range,
    index,
    totalProgression,
    chapterTitle = '',
    preservesRange = false,
    resourceProgressionOverride = null
) => {
    const semanticRange = preservesRange ? range : firstTextRange(range) ?? range
    const cfi = semanticRange ? view?.getCFI?.(index, semanticRange) : null
    const quote = contextForRange(semanticRange)
    const start = semanticRange
        ? domPoint(semanticRange.startContainer, semanticRange.startOffset)
        : null
    const end = semanticRange
        ? domPoint(semanticRange.endContainer, semanticRange.endOffset)
        : null
    const selector = start?.cssSelector ?? null
    return {
        href: sectionHref(index),
        cfi: typeof cfi === 'string' && cfi.startsWith('epubcfi(') ? cfi : null,
        resourceProgression: resourceProgressionOverride
            ?? resourceProgression(index, totalProgression),
        totalProgression: boundedNumber(totalProgression, 0, 1),
        chapterTitle: String(chapterTitle ?? ''),
        pageCurrent: null,
        pageTotal: null,
        exact: quote.exact,
        prefix: quote.prefix,
        suffix: quote.suffix,
        cssSelector: selector,
        domRange: start ? { start, end } : null,
    }
}

const relocationPosition = detail => {
    const index = detail?.section?.current
        ?? detail?.index
        ?? view?.renderer?.primaryIndex
        ?? 0
    const suppliedTotalProgression = Number.isFinite(detail?.fraction)
        ? boundedNumber(detail.fraction, 0, 1)
        : null
    const currentResourceProgression = resourceProgression(
        index,
        suppliedTotalProgression
    )
    const totalProgression = suppliedTotalProgression
        ?? totalProgressionFor(index, currentResourceProgression)
        ?? 0
    const position = positionForRange(
        detail?.range,
        index,
        totalProgression,
        detail?.tocItem?.label ?? '',
        false,
        currentResourceProgression
    )
    const current = detail?.location?.current
    const total = detail?.location?.total
    position.pageCurrent = Number.isInteger(current) ? current + 1 : null
    position.pageTotal = Number.isInteger(total) ? total : null
    return position
}

const isNetworkURL = value => {
    try {
        const protocol = new URL(value, location.href).protocol
        return protocol === 'http:' || protocol === 'https:'
    } catch {
        return false
    }
}

const hasRemoteScheme = value =>
    /(?:^|[\s("'=])(?:https?|wss?|ftp):/iu.test(String(value ?? ''))

const sanitizeCSS = source => String(source)
    .replace(
        /@import\s+(?:url\()?["']?(?:https?|wss?|ftp):[^;)"']+["']?\)?\s*;?/giu,
        ''
    )
    .replace(
        /url\(\s*["']?(?:https?|wss?|ftp):[^)"']+["']?\s*\)/giu,
        'url("")'
    )

const markupParserType = (source, mediaType, name) => {
    const type = String(mediaType ?? '').toLowerCase()
    const path = String(name ?? '').toLowerCase()
    if (type.includes('svg') || path.endsWith('.svg')
        || /^\s*<svg(?:\s|>)/iu.test(source)) return 'image/svg+xml'
    if (type.includes('html') && !type.includes('xhtml')
        || path.endsWith('.html') || path.endsWith('.htm')) return 'text/html'
    return 'application/xhtml+xml'
}

const sanitizeMarkup = (source, mediaType, name = '', requiresCSP = false) => {
    const parser = new DOMParser()
    const parserType = markupParserType(source, mediaType, name)
    let doc = parser.parseFromString(source, parserType)
    if (doc.querySelector('parsererror') && parserType === 'application/xhtml+xml') {
        doc = parser.parseFromString(source, 'text/html')
    }
    if (doc.querySelector('parsererror')) {
        throw new Error('Publication markup could not be sanitized')
    }
    for (const script of doc.querySelectorAll('script')) {
        script.setAttribute('type', 'application/x-enve-blocked')
        script.removeAttribute('src')
        script.removeAttribute('href')
    }
    for (const element of doc.querySelectorAll('*')) {
        for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name.toLowerCase()
            const value = attribute.value.trim()
            if (name.startsWith('on')) {
                element.removeAttribute(attribute.name)
                continue
            }
            if (name === 'style') {
                element.setAttribute(attribute.name, sanitizeCSS(attribute.value))
                continue
            }
            if ((name === 'href' || name === 'src' || name === 'xlink:href'
                || name === 'action' || name === 'formaction')
                && /^javascript:/i.test(value)) {
                element.setAttribute(attribute.name, '#')
            }
            if ((name === 'srcset' || name === 'poster' || name === 'background')
                && hasRemoteScheme(value)) {
                element.removeAttribute(attribute.name)
            }
        }
    }
    for (const meta of doc.querySelectorAll('meta[http-equiv]')) {
        if (meta.getAttribute('http-equiv')?.toLowerCase() === 'refresh') meta.remove()
    }
    for (const base of doc.querySelectorAll('base')) base.remove()
    for (const element of doc.querySelectorAll('iframe, frame, object, embed, applet')) {
        element.removeAttribute('src')
        element.removeAttribute('srcdoc')
        element.removeAttribute('data')
        element.setAttribute('hidden', '')
        element.setAttribute('aria-hidden', 'true')
    }
    for (const link of doc.querySelectorAll('link[href]')) {
        if (isNetworkURL(link.getAttribute('href'))) {
            link.removeAttribute('href')
        }
    }
    for (const style of doc.querySelectorAll('style')) {
        style.textContent = sanitizeCSS(style.textContent ?? '')
    }
    const root = doc.documentElement
    if (root?.localName === 'html') {
        const namespace = root.namespaceURI
        const makeElement = name => namespace
            ? doc.createElementNS(namespace, name)
            : doc.createElement(name)
        let head = doc.querySelector('head')
        if (!head) {
            head = makeElement('head')
            root.insertBefore(head, root.firstChild)
        }
        const meta = makeElement('meta')
        meta.setAttribute('http-equiv', 'Content-Security-Policy')
        meta.setAttribute(
            'content',
            "default-src 'none'; style-src 'unsafe-inline' blob: data:; img-src blob: data:; font-src blob: data:; media-src blob: data:; script-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
        )
        head.prepend(meta)
    } else if (requiresCSP || root?.localName !== 'svg') {
        throw new Error('Publication document does not have a securable root')
    }
    return new XMLSerializer().serializeToString(doc)
}

const sourceText = async data => {
    if (typeof data === 'string') return data
    if (data instanceof Blob) return data.text()
    if (data instanceof ArrayBuffer) return new TextDecoder().decode(data)
    if (ArrayBuffer.isView(data)) {
        return new TextDecoder().decode(
            new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
        )
    }
    return null
}

const transformedPublicationData = async (data, mediaType, name, requiresCSP) => {
    const resolved = await data
    const type = String(mediaType ?? '').toLowerCase()
    const path = String(name ?? '').toLowerCase()
    if (type.includes('javascript') || type.includes('ecmascript')
        || path.endsWith('.js') || path.endsWith('.mjs')) {
        return typeof resolved === 'string'
            ? ''
            : new Blob([], { type: 'text/plain' })
    }
    const text = await sourceText(resolved)
    if (text === null) return resolved
    const looksLikeMarkup = /^\s*(?:<\?xml[\s\S]*?\?>\s*)?<(?:!doctype|html|svg|[a-z][\w:.-]*\s+xmlns\s*=)/iu
        .test(text)
    const isMarkup = looksLikeMarkup
        || type.includes('html')
        || type.includes('xhtml')
        || type.includes('xml')
        || type.includes('svg')
        || /\.(?:xhtml|html?|xml|svg)$/iu.test(path)
    const isCSS = type.includes('css') || path.endsWith('.css')
    if (!isMarkup && !isCSS) return resolved
    const transformed = isCSS
        ? sanitizeCSS(text)
        : sanitizeMarkup(text, mediaType, name, requiresCSP)
    return typeof resolved === 'string'
        ? transformed
        : new Blob([transformed], {
            type: isCSS ? 'text/css' : markupParserType(text, mediaType, name),
        })
}

const installPublicationTransform = openedBook => {
    const target = openedBook?.transformTarget
    if (!target?.addEventListener) {
        throw new Error('Foliate publication transformation is unavailable')
    }
    const sectionNames = new Set(
        (openedBook.sections ?? []).map(section => normalizeHref(section?.id))
    )
    target.addEventListener('data', event => {
        const detail = event.detail
        const type = String(detail?.type ?? '').toLowerCase()
        if (type.includes('javascript') || type.includes('ecmascript')) {
            detail.data = Promise.resolve(detail.data).then(data =>
                typeof data === 'string' ? '' : new Blob([], { type: 'text/plain' })
            )
            detail.type = 'text/plain'
            return
        }
        const requiresCSP = sectionNames.has(normalizeHref(detail.name))
        if (requiresCSP) detail.type = 'application/xhtml+xml'
        detail.data = transformedPublicationData(
            detail.data,
            type,
            detail.name,
            requiresCSP
        )
    })
    target.addEventListener('load', event => {
        if (event.detail?.isScript === true) event.detail.allow = false
    })
}

const fontStack = family => {
    switch (family) {
    case 'sansSerif':
        return '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif'
    case 'openDyslexic':
        return '"OpenDyslexic", sans-serif'
    case 'duospace':
        return '"iA Writer Duospace", ui-monospace, Menlo, monospace'
    default:
        return 'ui-serif, Georgia, "Times New Roman", serif'
    }
}

const colorsForTheme = theme => {
    switch (theme) {
    case 'paper':
        return { background: '#F2EEE3', foreground: '#1D1D1D', link: '#2E5AAC', scheme: 'light' }
    case 'sepia':
        return { background: '#FAF4E8', foreground: '#121212', link: '#8C5A22', scheme: 'light' }
    case 'eink':
        return { background: '#FFFFFF', foreground: '#000000', link: '#000000', scheme: 'light' }
    default:
        return { background: '#000000', foreground: '#FEFEFE', link: '#7CB8FF', scheme: 'dark' }
    }
}

const clearBionic = doc => {
    try {
        doc.defaultView?.CSS?.highlights?.delete('enve-bionic')
    } catch {
        // A document can disappear while a renderer transition is completing.
    }
}

const applyBionic = doc => {
    clearBionic(doc)
    if (!preferences?.bionic) return
    const win = doc.defaultView
    if (!win?.Highlight || !win.CSS?.highlights) {
        throw new Error('CSS Highlights are unavailable')
    }
    const ranges = []
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
            const parent = node.parentElement
            if (!parent || parent.closest('script, style, noscript, textarea')) {
                return NodeFilter.FILTER_REJECT
            }
            return /\p{L}/u.test(node.data)
                ? NodeFilter.FILTER_ACCEPT
                : NodeFilter.FILTER_REJECT
        },
    })
    while (walker.nextNode()) {
        const node = walker.currentNode
        const matcher = /\p{L}[\p{L}\p{M}'’-]*/gu
        for (const match of node.data.matchAll(matcher)) {
            const length = match[0].length
            const boldLength = length <= 3 ? 1 : length <= 6 ? 2 : Math.ceil(length * 0.4)
            const range = doc.createRange()
            range.setStart(node, match.index)
            range.setEnd(node, match.index + boldLength)
            ranges.push(range)
        }
    }
    win.CSS.highlights.set('enve-bionic', new win.Highlight(...ranges))
}

const appearanceStyles = next => {
    const colors = colorsForTheme(next.theme)
    const family = next.customFontFamily
        ? JSON.stringify(next.customFontFamily)
        : fontStack(next.fontFamily)
    const publisherReset = next.publisherStyles
        ? ''
        : `body :where(p, div, section, article, blockquote, li, h1, h2, h3, h4, h5, h6) {
            font-family: inherit !important;
            color: inherit !important;
        }`
    return `
        ${next.customFontCSS || ''}
        :root {
            color-scheme: ${colors.scheme};
            --theme-bg-color: ${colors.background};
            --theme-fg-color: ${colors.foreground};
            --override-color: true;
        }
        html, body {
            background: ${colors.background} !important;
            color: ${colors.foreground} !important;
            font-family: ${family} !important;
            font-size: ${Math.round(next.fontSize * 100)}% !important;
            line-height: ${next.lineHeight} !important;
            text-align: ${next.justified ? 'justify' : 'start'} !important;
            letter-spacing: ${next.letterSpacing}em !important;
            word-spacing: ${next.wordSpacing}em !important;
            direction: ${next.direction === 'auto' ? 'inherit' : next.direction} !important;
            writing-mode: ${next.verticalWriting === null
                ? 'inherit'
                : next.verticalWriting ? 'vertical-rl' : 'horizontal-tb'} !important;
        }
        body {
            padding-inline: ${Math.max(0, next.pageMargins)}rem !important;
        }
        p {
            margin-block: ${Math.max(0, next.paragraphSpacing)}em !important;
        }
        ${next.publisherStyles ? '' : `
        p {
            text-indent: ${Math.max(0, next.paragraphIndent)}em !important;
        }
        `}
        a { color: ${colors.link} !important; }
        ::highlight(enve-bionic) {
            text-shadow:
                -0.35px 0 currentColor,
                0.35px 0 currentColor,
                0 -0.2px currentColor,
                0 0.2px currentColor;
        }
        ${publisherReset}
    `
}

const applyPreferences = next => {
    preferences = next
    const colors = colorsForTheme(next.theme)
    document.documentElement.style.setProperty('--footnote-background', colors.background)
    document.documentElement.style.setProperty('--footnote-foreground', colors.foreground)
    document.documentElement.style.setProperty('--footnote-border', `${colors.foreground}40`)
    const renderer = view?.renderer
    if (!renderer) return
    const verticalMargin = Math.max(0, (next.topMargins + next.bottomMargins) / 2) * 16
    renderer.setStyles?.(appearanceStyles(next))
    renderer.setAttribute('gap', `${Math.min(7, Math.max(0, next.pageMargins) * 7)}%`)
    renderer.setAttribute('margin', `${verticalMargin}px`)
    renderer.setAttribute('max-block-size', `calc(100% - ${verticalMargin * 2}px)`)
    renderer.setAttribute(
        'max-inline-size',
        next.scroll
            ? '9999px'
            : `${Math.max(320, Math.round(720 / Math.max(0.25, next.pageMargins)))}px`
    )
    renderer.setAttribute(
        'max-column-count',
        next.scroll ? '1' : next.columns === 'two' ? '2' : next.columns === 'one' ? '1' : '2'
    )
    if (next.scroll) renderer.setAttribute('flow', 'scrolled')
    else renderer.removeAttribute('flow')
    for (const content of renderer.getContents?.() ?? []) applyBionic(content.doc)
    renderer.render?.()
}

const captureRendererRelocationReason = () => {
    view?.renderer?.addEventListener('relocate', event => {
        pendingRendererRelocationReason = typeof event.detail?.reason === 'string'
            ? event.detail.reason
            : null
    }, { capture: true })
}

const applyPreferenceCommand = async next => {
    const reloadLayout = preferences !== null
        && (preferences.direction !== next.direction
            || preferences.verticalWriting !== next.verticalWriting)
    if (!reloadLayout) {
        applyPreferences(next)
        return
    }
    const cfi = lastPosition?.cfi
    const href = lastPosition?.href
    const fraction = lastPosition?.totalProgression
    lastVisibleRange = null
    view.close()
    await view.open(book)
    captureRendererRelocationReason()
    applyPreferences(next)
    if (typeof cfi === 'string') await view.goTo(cfi)
    else if (typeof fraction === 'number') await view.goToFraction(fraction)
    else if (typeof href === 'string' && href) await view.goTo(href)
    await drawAnnotations(Array.from(annotationByCFI.values()))
    for (const content of view.renderer?.getContents?.() ?? []) {
        attachDocumentListeners(content.doc)
    }
}

const attachDocumentListeners = doc => {
    if (!doc || doc.documentElement.dataset.enveListeners === '1') return
    doc.documentElement.dataset.enveListeners = '1'
    const selectionHandler = () => {
        clearTimeout(selectionTimer)
        selectionTimer = setTimeout(emitSelection, 0)
    }
    doc.addEventListener('selectionchange', selectionHandler)
    doc.addEventListener('pointerup', selectionHandler)
    doc.addEventListener('keydown', handleNavigationKeydown)
    selectionCleanups.push(() => {
        doc.removeEventListener('selectionchange', selectionHandler)
        doc.removeEventListener('pointerup', selectionHandler)
        doc.removeEventListener('keydown', handleNavigationKeydown)
    })
    applyBionic(doc)
}

const currentSelectionSnapshot = () => {
    for (const content of view?.renderer?.getContents?.() ?? []) {
        const selection = content.doc.getSelection()
        if (!selection || selection.isCollapsed || selection.rangeCount === 0) continue
        const range = selection.getRangeAt(0)
        if (!range.toString().trim()) continue
        const totalProgression = lastPosition?.totalProgression ?? 0
        const locator = positionForRange(
            range,
            content.index ?? 0,
            totalProgression,
            lastPosition?.chapterTitle ?? '',
            true
        )
        const rect = range.getBoundingClientRect()
        const frame = content.doc.defaultView?.frameElement?.getBoundingClientRect()
        return {
            locator,
            frame: {
                x: rect.left + (frame?.left ?? 0),
                y: rect.top + (frame?.top ?? 0),
                width: rect.width,
                height: rect.height,
            },
        }
    }
    return null
}

const emitSelection = () => {
    lastSelection = currentSelectionSnapshot()
    post('selection', { selection: lastSelection })
}

const clearSelection = () => {
    view?.deselect?.()
    lastSelection = null
    post('selection', { selection: null })
}

const closeFootnote = () => {
    if (!activeFootnote) return
    activeFootnote.view.close()
    activeFootnote.overlay.remove()
    activeFootnote = null
}

const footnotes = new FootnoteHandler()
footnotes.addEventListener('before-render', event => {
    closeFootnote()
    const noteView = event.detail.view
    const overlay = document.createElement('div')
    overlay.className = 'footnote-overlay'
    overlay.setAttribute('role', 'dialog')
    overlay.setAttribute('aria-modal', 'true')
    overlay.setAttribute('aria-label', 'Footnote')

    const panel = document.createElement('div')
    panel.className = 'footnote-panel'
    const closeButton = document.createElement('button')
    closeButton.className = 'footnote-close'
    closeButton.type = 'button'
    closeButton.setAttribute('aria-label', 'Close footnote')
    closeButton.textContent = '×'
    closeButton.addEventListener('click', closeFootnote)

    panel.append(closeButton, noteView)
    overlay.append(panel)
    overlay.addEventListener('click', event => {
        if (event.target === overlay) closeFootnote()
    })
    document.body.append(overlay)
    activeFootnote = { overlay, view: noteView }
})
footnotes.addEventListener('render', event => {
    const noteView = event.detail.view
    requestAnimationFrame(() => {
        if (activeFootnote?.view !== noteView) return
        noteView.renderer?.setAttribute('flow', 'scrolled')
        noteView.renderer?.setAttribute('margin', '20px')
        noteView.renderer?.setAttribute('max-column-count', '1')
        const colors = colorsForTheme(preferences.theme)
        const family = preferences.customFontFamily
            ? JSON.stringify(preferences.customFontFamily)
            : fontStack(preferences.fontFamily)
        noteView.renderer?.setStyles?.(`
            ${preferences.customFontCSS || ''}
            :root { color-scheme: ${colors.scheme}; }
            html, body {
                background: ${colors.background} !important;
                color: ${colors.foreground} !important;
                font-family: ${family} !important;
                font-size: ${Math.round(preferences.fontSize * 100)}% !important;
                line-height: ${preferences.lineHeight} !important;
            }
            a { color: ${colors.link} !important; }
        `)
        activeFootnote.overlay.querySelector('.footnote-close')?.focus()
    })
})

const handleNavigationKeydown = event => {
    if (event.key === 'Escape') {
        if (activeFootnote) {
            event.preventDefault()
            closeFootnote()
        }
        return
    }
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return
    if (!view || activeFootnote || lastSelection) return
    switch (event.key) {
    case 'ArrowRight':
    case 'PageDown':
    case ' ':
        event.preventDefault()
        view.next()
        break
    case 'ArrowLeft':
    case 'PageUp':
        event.preventDefault()
        view.prev()
        break
    }
}

document.addEventListener('keydown', handleNavigationKeydown)

const drawAnnotations = async annotations => {
    const active = new Set(annotations.map(annotation => annotation.cfi))
    for (const cfi of drawnAnnotationCFIs) {
        if (!active.has(cfi)) {
            await view.deleteAnnotation?.({ value: cfi })
            drawnAnnotationCFIs.delete(cfi)
            annotationByCFI.delete(cfi)
        }
    }
    for (const annotation of annotations) {
        annotationByCFI.set(annotation.cfi, annotation)
        await view.addAnnotation?.({
            value: annotation.cfi,
            color: annotation.color,
            style: annotation.style,
            hasNote: annotation.hasNote,
        })
        drawnAnnotationCFIs.add(annotation.cfi)
    }
}

const textNodeFromPoint = (doc, point) => {
    const validKeys = hasExactKeys(point, ['cssSelector', 'textNodeIndex', 'charOffset'])
        || hasExactKeys(point, ['cssSelector', 'textNodeIndex'])
    if (!validKeys) return null
    let parent = null
    try {
        parent = doc.querySelector(point.cssSelector)
    } catch {
        return null
    }
    const node = parent?.childNodes?.[point.textNodeIndex]
    if (node?.nodeType !== Node.TEXT_NODE) return null
    const offset = point.charOffset === null
        ? 0
        : Math.min(node.data.length, Math.max(0, point.charOffset))
    return { node, offset }
}

const rangeFromDOMRange = (doc, domRange) => {
    if (!hasExactKeys(domRange, ['start', 'end'])
        && !hasExactKeys(domRange, ['start'])) return null
    const start = textNodeFromPoint(doc, domRange.start)
    if (!start) return null
    const end = domRange.end ? textNodeFromPoint(doc, domRange.end) : start
    if (!end) return null
    const range = doc.createRange()
    try {
        range.setStart(start.node, start.offset)
        range.setEnd(end.node, end.offset)
        return range
    } catch {
        return null
    }
}

const coalescedTextMap = raw => {
    let text = ''
    const rawStarts = []
    const rawEnds = []
    let pendingWhitespace = null
    let fallbackIndex = 0
    const graphemes = typeof Intl.Segmenter === 'function'
        ? Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(raw))
        : Array.from(raw, segment => {
            const entry = { segment, index: fallbackIndex }
            fallbackIndex += segment.length
            return entry
        })
    for (const { segment, index } of graphemes) {
        const rawEnd = index + segment.length
        if (/^\s+$/u.test(segment)) {
            if (text && !text.endsWith(' ')) {
                if (pendingWhitespace) pendingWhitespace.end = rawEnd
                else pendingWhitespace = { start: index, end: rawEnd }
            }
            continue
        }
        if (pendingWhitespace !== null) {
            text += ' '
            rawStarts.push(pendingWhitespace.start)
            rawEnds.push(pendingWhitespace.end)
            pendingWhitespace = null
        }
        const normalized = segment.normalize('NFC')
        text += normalized
        for (let offset = 0; offset < normalized.length; offset++) {
            rawStarts.push(index)
            rawEnds.push(rawEnd)
        }
    }
    return { text, rawStarts, rawEnds }
}

const normalizedQuote = value =>
    typeof value === 'string'
        ? value.normalize('NFC').replace(/\s+/gu, ' ').trim()
        : ''

const rangeFromTextQuote = (root, exact, prefix, suffix) => {
    if (!root || typeof exact !== 'string' || !exact) return null
    const doc = root.ownerDocument
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT)
    const nodes = []
    let text = ''
    while (walker.nextNode()) {
        nodes.push({ node: walker.currentNode, start: text.length })
        text += walker.currentNode.data
    }
    const mapped = coalescedTextMap(text)
    const needle = normalizedQuote(exact)
    const normalizedPrefix = normalizedQuote(prefix)
    const normalizedSuffix = normalizedQuote(suffix)
    if (!needle) return null
    let searchFrom = 0
    while (searchFrom <= mapped.text.length) {
        const index = mapped.text.indexOf(needle, searchFrom)
        if (index < 0) return null
        const preceding = mapped.text.slice(
                Math.max(0, index - normalizedPrefix.length),
                index
            )
        const prefixMatches = !normalizedPrefix
            || preceding.endsWith(normalizedPrefix)
            || (preceding.length > 0 && normalizedPrefix.endsWith(preceding))
        const normalizedEnd = index + needle.length
        const following = mapped.text.slice(
                normalizedEnd,
                normalizedEnd + normalizedSuffix.length
            )
        const suffixMatches = !normalizedSuffix
            || following.startsWith(normalizedSuffix)
            || (following.length > 0 && normalizedSuffix.startsWith(following))
        if (prefixMatches && suffixMatches) {
            const rawStart = mapped.rawStarts[index]
            const rawEnd = mapped.rawEnds[normalizedEnd - 1] ?? rawStart
            const startEntry = nodes.findLast(entry => entry.start <= rawStart)
            const endEntry = nodes.findLast(entry => entry.start < rawEnd) ?? startEntry
            if (!startEntry || !endEntry) return null
            const range = doc.createRange()
            range.setStart(startEntry.node, rawStart - startEntry.start)
            range.setEnd(endEntry.node, rawEnd - endEntry.start)
            return range
        }
        searchFrom = index + 1
    }
    return null
}

const parseLocator = locatorJSON => {
    if (typeof locatorJSON !== 'string') throw new TypeError('Locator must be a string')
    const trimmed = locatorJSON.trim()
    if (trimmed.startsWith('epubcfi(')) {
        return { cfi: trimmed, totalProgression: null }
    }
    const value = JSON.parse(trimmed)
    if (!hasExactKeys(value, ['href', 'type', 'locations', 'text'])
        && !hasExactKeys(value, ['href', 'type', 'locations'])
        && !hasExactKeys(value, ['href', 'type', 'title', 'locations', 'text'])
        && !hasExactKeys(value, ['href', 'type', 'title', 'locations'])) {
        throw new TypeError('Locator schema is invalid')
    }
    return {
        href: typeof value.href === 'string' ? value.href : '',
        cfi: typeof value.locations?.cfi === 'string'
            ? value.locations.cfi
            : Array.isArray(value.locations?.fragments)
                ? value.locations.fragments.find(fragment =>
                    typeof fragment === 'string'
                    && fragment.startsWith('epubcfi(')
                    && fragment.endsWith(')')
                ) ?? null
                : null,
        htmlID: Array.isArray(value.locations?.fragments)
            ? value.locations.fragments.map(htmlIDFromFragment).find(Boolean) ?? null
            : htmlIDFromFragment(String(value.href).split('#', 2)[1] ?? null),
        cssSelector: typeof value.locations?.cssSelector === 'string'
            ? value.locations.cssSelector
            : null,
        domRange: value.locations?.domRange ?? null,
        exact: typeof value.text?.highlight === 'string' ? value.text.highlight : null,
        prefix: typeof value.text?.before === 'string' ? value.text.before : null,
        suffix: typeof value.text?.after === 'string' ? value.text.after : null,
        resourceProgression: typeof value.locations?.progression === 'number'
            ? boundedNumber(value.locations.progression, 0, 1)
            : null,
        totalProgression: typeof value.locations?.totalProgression === 'number'
            ? boundedNumber(value.locations.totalProgression, 0, 1)
            : null,
    }
}

const semanticRangeForLocator = async (locator, navigateToResource = true) => {
    if (!locator.href
        || (!locator.domRange && !locator.exact && !locator.cssSelector && !locator.htmlID)) {
        return null
    }
    const expectedIndex = book?.sections?.findIndex(section =>
        normalizeHref(section?.id) === normalizeHref(locator.href)
    ) ?? -1
    if (expectedIndex < 0) return null
    let content = view.renderer?.getContents?.()
        .find(item => item.index === expectedIndex)
    if (!content?.doc && navigateToResource) {
        await view.goTo(locator.href)
        content = view.renderer?.getContents?.()
            .find(item => item.index === expectedIndex)
    }
    if (!content?.doc) return null
    let selectedElement = null
    if (locator.cssSelector) {
        try {
            selectedElement = content.doc.querySelector(locator.cssSelector)
        } catch {
            selectedElement = null
        }
    }
    let range = locator.domRange
        ? rangeFromDOMRange(content.doc, locator.domRange)
        : null
    if (!range && locator.htmlID) {
        const element = content.doc.getElementById(locator.htmlID)
        if (element) {
            range = content.doc.createRange()
            range.selectNodeContents(element)
            range.collapse(true)
        }
    }
    if (!range && locator.exact && selectedElement) {
        range = rangeFromTextQuote(
            selectedElement,
            locator.exact,
            locator.prefix,
            locator.suffix
        ) ?? rangeFromTextQuote(selectedElement, locator.exact, null, null)
    }
    if (!range && locator.exact) {
        range = rangeFromTextQuote(
            content.doc.body,
            locator.exact,
            locator.prefix,
            locator.suffix
        ) ?? rangeFromTextQuote(content.doc.body, locator.exact, null, null)
    }
    if (!range && selectedElement) {
        range = content.doc.createRange()
        range.selectNodeContents(selectedElement)
    }
    return range ? { content, range } : null
}

const mintCFIFromLocator = async (locator, navigateToResource = true) => {
    if (locator.cfi?.startsWith('epubcfi(')) {
        try {
            const resolved = view.resolveCFI(locator.cfi)
            if (Number.isInteger(resolved?.index)
                && resolved.index >= 0
                && resolved.index < (book?.sections?.length ?? 0)
                && (!locator.href
                    || sectionHref(resolved.index) === normalizeHref(locator.href))) {
                return locator.cfi
            }
        } catch {
            // Continue through semantic anchors.
        }
    }
    const resolved = await semanticRangeForLocator(locator, navigateToResource)
    return resolved ? view.getCFI(resolved.content.index, resolved.range) : null
}

const withNavigationAnimation = async (animated, action) => {
    if (typeof animated !== 'boolean') throw new TypeError('Animated must be a boolean')
    const renderer = view?.renderer
    const wasAnimated = renderer?.hasAttribute?.('animated') ?? false
    renderer?.toggleAttribute?.('animated', animated)
    try {
        return await action()
    } finally {
        renderer?.toggleAttribute?.('animated', wasAnimated)
    }
}

const restoreLocator = async (locatorJSON, animated = false) => {
    const locator = parseLocator(locatorJSON)
    const cfi = await mintCFIFromLocator(locator)
    if (cfi) {
        const resolved = await withNavigationAnimation(animated, () => view.goTo(cfi))
        if (Number.isInteger(resolved?.index) && resolved.index >= 0) return true
    }
    if (locator.href && locator.resourceProgression !== null) {
        const index = book?.sections?.findIndex(section =>
            normalizeHref(section?.id) === normalizeHref(locator.href)
        ) ?? -1
        const fractions = view?.getSectionFractions?.() ?? []
        const start = fractions[index]
        const end = fractions[index + 1]
        if (index >= 0
            && typeof start === 'number'
            && typeof end === 'number'
            && end >= start) {
            const fraction = start + (end - start) * locator.resourceProgression
            await withNavigationAnimation(
                animated,
                () => view.goToFraction(boundedNumber(fraction, 0, 1))
            )
            return true
        }
    }
    if (locator.totalProgression !== null) {
        await withNavigationAnimation(
            animated,
            () => view.goToFraction(locator.totalProgression)
        )
        return true
    }
    if (locator.href) {
        const resolved = await withNavigationAnimation(
            animated,
            () => view.goTo(locator.href)
        )
        if (Number.isInteger(resolved?.index) && resolved.index >= 0) return true
        const index = book?.sections?.findIndex(section =>
            normalizeHref(section?.id) === normalizeHref(locator.href)
        ) ?? -1
        return index >= 0
    }
    return false
}

const applyTTSLocator = async locatorJSON => {
    for (const content of view.renderer?.getContents?.() ?? []) {
        content.overlayer?.remove(ttsAnnotationKey)
    }
    if (locatorJSON === null) return { applied: true, cleared: true }
    const locator = parseLocator(locatorJSON)
    locator.cfi = null
    locator.domRange = null
    const resolved = await semanticRangeForLocator(locator, false)
    if (!resolved?.content.overlayer || resolved.range.collapsed) {
        return { applied: false, cleared: false }
    }
    resolved.content.overlayer.add(
        ttsAnnotationKey,
        resolved.range,
        Overlayer.highlight,
        { color: '#3399FF' }
    )
    return {
        applied: resolved.range.getClientRects().length > 0,
        cleared: false,
    }
}

const textPointAtOffset = (element, target) => {
    const walker = element.ownerDocument.createTreeWalker(element, NodeFilter.SHOW_TEXT)
    let consumed = 0
    while (walker.nextNode()) {
        const node = walker.currentNode
        const end = consumed + node.data.length
        if (target <= end) {
            return { node, offset: Math.max(0, target - consumed) }
        }
        consumed = end
    }
    return null
}

const ttsSentenceRange = (block, point, startsAtSentence) => {
    const before = block.ownerDocument.createRange()
    before.selectNodeContents(block)
    try {
        before.setEnd(point.node, point.offset)
    } catch {
        return null
    }

    const blockText = block.textContent ?? ''
    const language = block.lang || block.ownerDocument.documentElement.lang || 'en'
    const offset = before.toString().length
    const sentence = Array.from(
        new Intl.Segmenter(language, { granularity: 'sentence' }).segment(blockText)
    ).find(item => offset >= item.index && offset < item.index + item.segment.length)
    const startOffset = startsAtSentence ? sentence?.index ?? offset : offset
    const sentenceEnd = sentence
        ? sentence.index + sentence.segment.length
        : Math.min(blockText.length, startOffset + 160)
    const endOffset = Math.min(sentenceEnd, startOffset + 160)
    const start = textPointAtOffset(block, startOffset)
    const end = textPointAtOffset(block, Math.max(startOffset, endOffset))
    if (!start || !end) return null

    const range = block.ownerDocument.createRange()
    range.setStart(start.node, start.offset)
    range.setEnd(end.node, end.offset)
    return range
}

const ttsStartPosition = () => {
    if (!lastPosition || !lastVisibleRange) return lastPosition
    const visibleRange = firstTextRange(lastVisibleRange)
    if (!visibleRange) return lastPosition
    const point = {
        node: visibleRange.startContainer,
        offset: visibleRange.startOffset,
    }
    const block = nearestTTSBlock(point.node)
    const selector = cssPath(block)
    const index = sectionIndexForDocument(point.node.ownerDocument)
    if (!selector || !Number.isInteger(index)) return lastPosition
    const range = ttsSentenceRange(block, point, false) ?? visibleRange
    const position = positionForRange(
        range,
        index,
        lastPosition.totalProgression,
        lastPosition.chapterTitle,
        true,
        lastPosition.resourceProgression
    )
    position.cssSelector = selector
    position.pageCurrent = lastPosition.pageCurrent
    position.pageTotal = lastPosition.pageTotal
    return position
}

const caretPointInDocument = (doc, x, y) => {
    const position = doc.caretPositionFromPoint?.(x, y)
    if (position) return { node: position.offsetNode, offset: position.offset }
    const range = doc.caretRangeFromPoint?.(x, y)
    return range ? { node: range.startContainer, offset: range.startOffset } : null
}

const distanceToRect = (x, y, rect) => {
    const dx = x < rect.left ? rect.left - x : x > rect.right ? x - rect.right : 0
    const dy = y < rect.top ? rect.top - y : y > rect.bottom ? y - rect.bottom : 0
    return dx * dx + dy * dy
}

const nearestTextPoint = (doc, x, y) => {
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT)
    let bestNode = null
    let bestScore = Infinity
    while (walker.nextNode()) {
        const node = walker.currentNode
        if (!node.data.trim()) continue
        const range = doc.createRange()
        range.selectNodeContents(node)
        for (const rect of range.getClientRects()) {
            if (rect.width <= 0 || rect.height <= 0) continue
            const score = distanceToRect(x, y, rect)
            if (score < bestScore) {
                bestNode = node
                bestScore = score
            }
        }
    }
    if (!bestNode) return null

    let bestOffset = 0
    bestScore = Infinity
    for (let offset = 0; offset < bestNode.data.length; offset++) {
        const range = doc.createRange()
        range.setStart(bestNode, offset)
        range.setEnd(bestNode, offset + 1)
        for (const rect of range.getClientRects()) {
            if (rect.width <= 0 || rect.height <= 0) continue
            const score = distanceToRect(x, y, rect)
            if (score < bestScore) {
                bestOffset = offset
                bestScore = score
            }
        }
    }
    return { node: bestNode, offset: bestOffset }
}

const ttsPositionAtPoint = (x, y) => {
    if (!lastPosition) return null
    const contents = view?.renderer?.getContents?.() ?? []
    const atPoint = contents.find(content => {
        const frame = content.doc?.defaultView?.frameElement?.getBoundingClientRect?.()
        return frame
            && x >= frame.left
            && x <= frame.right
            && y >= frame.top
            && y <= frame.bottom
    })
    const primary = contents.find(content => content.index === view.renderer?.primaryIndex)
    const candidates = Array.from(new Set([atPoint, primary, ...contents].filter(Boolean)))
    for (const content of candidates) {
        const frame = content.doc?.defaultView?.frameElement?.getBoundingClientRect?.()
        const localX = x - (frame?.left ?? 0)
        const localY = y - (frame?.top ?? 0)
        const caret = caretPointInDocument(content.doc, localX, localY)
        const point = caret?.node?.nodeType === Node.TEXT_NODE
            ? caret
            : nearestTextPoint(content.doc, localX, localY)
        const block = nearestTTSBlock(point?.node)
        const selector = cssPath(block)
        if (!point || !block || !selector) continue

        const range = ttsSentenceRange(block, point, true)
        if (!range) continue
        const position = positionForRange(
            range,
            content.index,
            lastPosition.totalProgression,
            lastPosition.chapterTitle,
            true,
            lastPosition.resourceProgression
        )
        position.cssSelector = selector
        position.pageCurrent = lastPosition.pageCurrent
        position.pageTotal = lastPosition.pageTotal
        return position
    }
    return null
}

const followTTSLocator = async locatorJSON => {
    const locator = parseLocator(locatorJSON)
    locator.cfi = null
    locator.domRange = null
    let resolved = await semanticRangeForLocator(locator, true)
    if (!resolved) return
    if (resolved.content.index !== view.renderer?.primaryIndex) {
        await view.goTo(locator.href)
        resolved = await semanticRangeForLocator(locator, false)
        if (!resolved) return
    }
    const { content, range } = resolved
    let isVisible = false
    if (lastVisibleRange?.startContainer?.ownerDocument === content.doc) {
        try {
            isVisible = lastVisibleRange.isPointInRange(
                range.startContainer,
                range.startOffset
            ) || lastVisibleRange.isPointInRange(
                range.endContainer,
                Math.max(0, range.endOffset - 1)
            ) || range.isPointInRange(
                lastVisibleRange.startContainer,
                lastVisibleRange.startOffset
            )
        } catch {
            isVisible = false
        }
    }
    if (!isVisible) await view.renderer.scrollToAnchor?.(range)
}

const performSearch = async query => {
    view.clearSearch?.()
    const results = []
    for await (const result of view.search({ query, scope: 'book' })) {
        const items = result?.subitems ?? (result?.cfi ? [result] : [])
        for (const item of items) {
            if (typeof item?.cfi !== 'string') continue
            let index = 0
            try {
                index = view.resolveCFI(item.cfi)?.index ?? 0
            } catch {
                continue
            }
            const excerpt = item.excerpt ?? {}
            const exact = String(excerpt.match ?? query)
            const locator = {
                href: sectionHref(index),
                cfi: item.cfi,
                resourceProgression: null,
                totalProgression: 0,
                chapterTitle: String(result.label ?? ''),
                pageCurrent: null,
                pageTotal: null,
                exact,
                prefix: typeof excerpt.pre === 'string' ? excerpt.pre : null,
                suffix: typeof excerpt.post === 'string' ? excerpt.post : null,
                cssSelector: null,
                domRange: null,
            }
            results.push({ locator })
        }
    }
    return results
}

const currentPageText = () => {
    if (!lastVisibleRange?.startContainer?.isConnected) return ''
    return lastVisibleRange.toString().replace(/\s+/g, ' ').trim().slice(0, 10000)
}

const runAutoScroll = timestamp => {
    if (!autoScrollSpeed || !view?.renderer) {
        autoScrollFrame = 0
        return
    }
    const delta = autoScrollPreviousTime
        ? Math.min(50, timestamp - autoScrollPreviousTime)
        : 0
    autoScrollPreviousTime = timestamp
    const distance = autoScrollSpeed * delta / 1000
    view.renderer.scrollBy?.(distance, distance)
    if (view.renderer.atEnd) view.next?.()
    autoScrollFrame = requestAnimationFrame(runAutoScroll)
}

const setAutoScroll = speed => {
    autoScrollSpeed = Math.max(0, speed)
    autoScrollPreviousTime = 0
    if (autoScrollFrame) cancelAnimationFrame(autoScrollFrame)
    autoScrollFrame = autoScrollSpeed ? requestAnimationFrame(runAutoScroll) : 0
}

const validatePreferences = value => {
    const keys = [
        'theme', 'fontFamily', 'customFontFamily', 'customFontCSS', 'columns',
        'fontSize', 'lineHeight', 'pageMargins', 'topMargins', 'bottomMargins',
        'paragraphSpacing', 'paragraphIndent', 'scroll', 'publisherStyles', 'justified',
        'wordSpacing', 'letterSpacing', 'bionic', 'direction', 'verticalWriting',
    ]
    if (!hasExactKeys(value, keys)) throw new TypeError('Preference schema is invalid')
    if (!['paper', 'sepia', 'midnight', 'eink'].includes(value.theme)) {
        throw new TypeError('Theme is invalid')
    }
    if (!['serif', 'sansSerif', 'openDyslexic', 'duospace'].includes(value.fontFamily)) {
        throw new TypeError('Font family is invalid')
    }
    if (!['auto', 'one', 'two'].includes(value.columns)) {
        throw new TypeError('Column mode is invalid')
    }
    if (!['auto', 'ltr', 'rtl'].includes(value.direction)) {
        throw new TypeError('Direction is invalid')
    }
    for (const key of [
        'fontSize', 'lineHeight', 'pageMargins', 'topMargins', 'bottomMargins',
        'paragraphSpacing', 'paragraphIndent', 'wordSpacing', 'letterSpacing',
    ]) boundedNumber(value[key], -1000, 1000)
    for (const key of ['scroll', 'publisherStyles', 'justified', 'bionic']) {
        if (typeof value[key] !== 'boolean') throw new TypeError(`${key} must be a boolean`)
    }
    optionalString(value.customFontFamily)
    optionalString(value.customFontCSS)
    if (value.verticalWriting !== null && typeof value.verticalWriting !== 'boolean') {
        throw new TypeError('Vertical writing must be a boolean or null')
    }
    return value
}

const validateAnnotations = value => {
    if (!Array.isArray(value)) throw new TypeError('Annotations must be an array')
    return value.map(annotation => {
        if (!hasExactKeys(annotation, ['id', 'cfi', 'color', 'style', 'hasNote'])) {
            throw new TypeError('Annotation schema is invalid')
        }
        if (typeof annotation.id !== 'string'
            || typeof annotation.cfi !== 'string'
            || typeof annotation.color !== 'string'
            || typeof annotation.hasNote !== 'boolean'
            || !['highlight', 'underline', 'strikethrough', 'squiggly'].includes(annotation.style)) {
            throw new TypeError('Annotation value is invalid')
        }
        return annotation
    })
}

const command = async envelope => {
    if (!hasExactKeys(envelope, ['version', 'capability', 'sequence', 'type', 'payload'])
        || envelope.version !== BRIDGE_VERSION
        || envelope.capability !== capability
        || !Number.isSafeInteger(envelope.sequence)
        || envelope.sequence <= incomingSequence
        || typeof envelope.type !== 'string'
        || !isRecord(envelope.payload)) {
        throw new TypeError('Command envelope is invalid')
    }
    incomingSequence = envelope.sequence
    const payload = envelope.payload
    switch (envelope.type) {
    case 'restore':
        if (!hasExactKeys(payload, ['locatorJSON', 'animated'])
            || typeof payload.animated !== 'boolean') {
            throw new TypeError('Restore payload is invalid')
        }
        return {
            restored: await restoreLocator(payload.locatorJSON, payload.animated),
        }
    case 'next':
        if (!hasExactKeys(payload, ['animated'])
            || typeof payload.animated !== 'boolean') {
            throw new TypeError('Next payload is invalid')
        }
        await withNavigationAnimation(payload.animated, () => view.next())
        return { moved: true }
    case 'previous':
        if (!hasExactKeys(payload, ['animated'])
            || typeof payload.animated !== 'boolean') {
            throw new TypeError('Previous payload is invalid')
        }
        await withNavigationAnimation(payload.animated, () => view.prev())
        return { moved: true }
    case 'pageDrag':
        if (!hasExactKeys(payload, ['deltaX', 'deltaY'])) {
            throw new TypeError('Page-drag payload is invalid')
        }
        if (preferences.scroll || lastSelection) return { applied: false }
        view.renderer.scrollBy(
            boundedNumber(payload.deltaX, -2000, 2000),
            boundedNumber(payload.deltaY, -2000, 2000)
        )
        return { applied: true }
    case 'pageDragEnd':
        if (!hasExactKeys(payload, ['velocityX', 'velocityY'])) {
            throw new TypeError('Page-drag-end payload is invalid')
        }
        if (preferences.scroll || lastSelection) return { completed: false }
        {
            const renderer = view.renderer
            const wasAnimated = renderer.hasAttribute('animated')
            renderer.setAttribute('animated', '')
            renderer.snap(
                boundedNumber(payload.velocityX, -5, 5),
                boundedNumber(payload.velocityY, -5, 5)
            )
            renderer.toggleAttribute('animated', wasAnimated)
            return { completed: true }
        }
    case 'href':
        if (!hasExactKeys(payload, ['href', 'animated'])
            || typeof payload.href !== 'string'
            || typeof payload.animated !== 'boolean') {
            throw new TypeError('Href payload is invalid')
        }
        {
            const resolved = await withNavigationAnimation(
                payload.animated,
                () => view.goTo(payload.href)
            )
            return {
                moved: Number.isInteger(resolved?.index) && resolved.index >= 0,
            }
        }
    case 'fraction':
        if (!hasExactKeys(payload, ['fraction', 'animated'])
            || typeof payload.animated !== 'boolean') {
            throw new TypeError('Fraction payload is invalid')
        }
        await withNavigationAnimation(
            payload.animated,
            () => view.goToFraction(boundedNumber(payload.fraction, 0, 1))
        )
        return { moved: true }
    case 'preferences':
        if (!hasExactKeys(payload, ['preferences'])) {
            throw new TypeError('Preferences payload is invalid')
        }
        await applyPreferenceCommand(validatePreferences(payload.preferences))
        return { applied: true }
    case 'clearSelection':
        if (!hasExactKeys(payload, [])) throw new TypeError('Clear-selection payload is invalid')
        clearSelection()
        return { cleared: true }
    case 'refreshSelection':
        if (!hasExactKeys(payload, [])) throw new TypeError('Refresh-selection payload is invalid')
        emitSelection()
        return { available: lastSelection !== null }
    case 'annotations':
        if (!hasExactKeys(payload, ['annotations'])) {
            throw new TypeError('Annotations payload is invalid')
        }
        await drawAnnotations(validateAnnotations(payload.annotations))
        return { applied: true }
    case 'search':
        if (!hasExactKeys(payload, ['query']) || typeof payload.query !== 'string') {
            throw new TypeError('Search payload is invalid')
        }
        return { results: await performSearch(payload.query.trim()) }
    case 'clearSearch':
        if (!hasExactKeys(payload, [])) throw new TypeError('Clear-search payload is invalid')
        view.clearSearch?.()
        return { cleared: true }
    case 'autoScroll':
        if (!hasExactKeys(payload, ['pointsPerSecond'])) {
            throw new TypeError('Auto-scroll payload is invalid')
        }
        setAutoScroll(boundedNumber(payload.pointsPerSecond, 0, 500))
        return { applied: true }
    case 'pageText':
        if (!hasExactKeys(payload, [])) throw new TypeError('Page-text payload is invalid')
        return { text: currentPageText() }
    case 'flush':
        if (!hasExactKeys(payload, [])) throw new TypeError('Flush payload is invalid')
        return { locator: lastPosition }
    case 'ttsStart':
        if (!hasExactKeys(payload, [])) throw new TypeError('TTS-start payload is invalid')
        return { locator: ttsStartPosition() }
    case 'ttsAt':
        if (!hasExactKeys(payload, ['x', 'y'])) throw new TypeError('TTS-at payload is invalid')
        return {
            locator: ttsPositionAtPoint(
                boundedNumber(payload.x, 0, 10000),
                boundedNumber(payload.y, 0, 10000)
            ),
        }
    case 'tts':
        if (!hasExactKeys(payload, ['locatorJSON'])) throw new TypeError('TTS payload is invalid')
        optionalString(payload.locatorJSON)
        return await applyTTSLocator(payload.locatorJSON)
    case 'ttsFollow':
        if (!hasExactKeys(payload, ['locatorJSON']) || typeof payload.locatorJSON !== 'string') {
            throw new TypeError('TTS follow payload is invalid')
        }
        await followTTSLocator(payload.locatorJSON)
        return { applied: true }
    case 'teardown':
        if (!hasExactKeys(payload, [])) throw new TypeError('Teardown payload is invalid')
        setAutoScroll(0)
        lastVisibleRange = null
        for (const cleanup of selectionCleanups.splice(0)) cleanup()
        view?.close?.()
        book?.destroy?.()
        view = null
        book = null
        return { closed: true }
    default:
        throw new TypeError('Unknown command')
    }
}

Object.defineProperty(globalThis, 'EnveFoliateRuntime', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: Object.freeze({ command }),
})

const loadSessionBook = async (streaming, fileExtension) => {
    if (streaming === null) {
        if (!['epub', 'fb2'].includes(fileExtension)) {
            throw new Error('Reader file type is invalid')
        }
        const bookResponse = await fetch(`/book/current.${fileExtension}`, { cache: 'no-store', credentials: 'omit' })
        if (!bookResponse.ok) {
            throw new Error('Local reader resources could not be loaded')
        }
        const blob = await bookResponse.blob()
        const mediaType = fileExtension === 'fb2'
            ? 'application/x-fictionbook+xml'
            : 'application/epub+zip'
        const file = new File([blob], `current.${fileExtension}`, { type: mediaType })
        return makeBook(file)
    }
    if (!isRecord(streaming) || !hasExactKeys(streaming, ['sizes']) || !isRecord(streaming.sizes)) {
        throw new Error('Reader session schema is invalid')
    }
    const sizes = streaming.sizes
    const resourceURL = path =>
        '/book/resource/' + String(path).split('/').map(encodeURIComponent).join('/')
    const loadText = async path => {
        const response = await fetch(resourceURL(path), { cache: 'no-store', credentials: 'omit' })
        return response.ok ? response.text() : null
    }
    const loadBlob = async path => {
        const response = await fetch(resourceURL(path), { cache: 'no-store', credentials: 'omit' })
        return response.ok ? response.blob() : null
    }
    const getSize = path => Number(sizes[String(path)]) || 0
    return new EPUB({ loadText, loadBlob, getSize }).init()
}

const boot = async () => {
    if (!nativeHandler || !capability || !handlerName) {
        throw new Error('Native bridge configuration is unavailable')
    }
    const sessionResponse = await fetch('/session.json', { cache: 'no-store', credentials: 'omit' })
    if (!sessionResponse.ok) {
        throw new Error('Local reader resources could not be loaded')
    }
    const session = await sessionResponse.json()
    if (!hasExactKeys(session, [
        'version', 'initialLocatorJSON', 'initialProgression', 'preferences', 'annotations', 'fileExtension', 'streaming',
    ]) || session.version !== BRIDGE_VERSION) {
        throw new Error('Reader session schema is invalid')
    }
    preferences = validatePreferences(session.preferences)
    const annotations = validateAnnotations(session.annotations)
    book = await loadSessionBook(session.streaming, session.fileExtension)
    if (session.fileExtension === 'epub') installPublicationTransform(book)

    view = document.createElement('foliate-view')
    document.querySelector('#reader').replaceChildren(view)
    view.addEventListener('relocate', event => {
        lastVisibleRange = event.detail?.range ?? null
        lastPosition = relocationPosition(event.detail)
        lastRelocationReason = pendingRendererRelocationReason
        pendingRendererRelocationReason = null
        if (initialized) {
            post('relocate', {
                locator: lastPosition,
                reason: lastRelocationReason,
            })
        }
    })
    view.addEventListener('load', event => attachDocumentListeners(event.detail?.doc))
    view.addEventListener('create-overlay', () => {
        for (const content of view.renderer?.getContents?.() ?? []) {
            attachDocumentListeners(content.doc)
        }
        drawAnnotations(annotations).catch(postError)
    })
    view.addEventListener('draw-annotation', event => {
        const { annotation, draw } = event.detail
        const style = annotation.style
        const renderer = style === 'underline'
            ? Overlayer.underline
            : style === 'strikethrough'
                ? Overlayer.strikethrough
                : style === 'squiggly'
                    ? Overlayer.squiggly
                    : Overlayer.highlight
        const rendererWithNote = (rects, options) => {
            const group = renderer(rects, options)
            if (!annotation.hasNote || !rects.length) return group
            const first = rects[0]
            const badge = group.ownerDocument.createElementNS(
                'http://www.w3.org/2000/svg',
                'circle'
            )
            badge.setAttribute('cx', String(first.left + first.width))
            badge.setAttribute('cy', String(first.top))
            badge.setAttribute('r', '4')
            badge.setAttribute('fill', annotation.color)
            badge.setAttribute('stroke', '#000000')
            badge.setAttribute('stroke-width', '1')
            group.append(badge)
            return group
        }
        draw(rendererWithNote, { color: annotation.color })
    })
    view.addEventListener('show-annotation', event => {
        const annotation = annotationByCFI.get(event.detail?.value)
        if (annotation) post('annotationActivated', { id: annotation.id })
    })
    view.addEventListener('external-link', event => {
        event.preventDefault()
        const href = event.detail?.href
        if (typeof href === 'string' && isNetworkURL(href)) {
            post('externalLink', { url: href })
        }
    })
    view.addEventListener('link', event => {
        const handled = footnotes.handle(book, event)
        handled?.catch(error => {
            console.error('Footnote popup failed', error)
            closeFootnote()
            view.goTo(event.detail?.href)
        })
    })

    await view.open(book)
    captureRendererRelocationReason()
    applyPreferences(preferences)
    await drawAnnotations(annotations)
    if (typeof session.initialLocatorJSON === 'string' && session.initialLocatorJSON) {
        const restored = await restoreLocator(session.initialLocatorJSON)
        if (!restored) await view.goToFraction(session.initialProgression)
    } else {
        await view.goToFraction(session.initialProgression)
    }
    for (const content of view.renderer?.getContents?.() ?? []) {
        attachDocumentListeners(content.doc)
    }
    initialized = true
    const renderedContents = view.renderer?.getContents?.() ?? []
    const supportsBionic = renderedContents.length > 0 && renderedContents.every(content => {
        const win = content.doc.defaultView
        return Boolean(win?.Highlight && win.CSS?.highlights)
    })
    if (!supportsBionic
        || typeof view.next !== 'function'
        || typeof view.prev !== 'function'
        || typeof view.goTo !== 'function'
        || typeof view.goToFraction !== 'function'
        || typeof view.getCFI !== 'function'
        || typeof view.resolveCFI !== 'function'
        || typeof view.getSectionFractions !== 'function'
        || typeof view.addAnnotation !== 'function'
        || typeof view.deleteAnnotation !== 'function'
        || typeof view.search !== 'function'
        || typeof view.clearSearch !== 'function'
        || typeof view.deselect !== 'function'
        || typeof view.close !== 'function'
        || typeof view.renderer?.setStyles !== 'function'
        || typeof view.renderer?.getContents !== 'function'
        || typeof view.renderer?.scrollBy !== 'function'
        || typeof view.renderer?.snap !== 'function'
        || typeof view.renderer?.render !== 'function'
        || !Array.isArray(book.sections)
        || (session.fileExtension === 'epub'
            && typeof book.transformTarget?.addEventListener !== 'function')) {
        throw new Error('The Foliate runtime does not provide the required reader capabilities')
    }
    if (lastPosition) {
        post('relocate', {
            locator: lastPosition,
            reason: lastRelocationReason,
        })
    }
    post('ready', { capabilities: REQUIRED_CAPABILITIES })
}

boot().catch(postError)
