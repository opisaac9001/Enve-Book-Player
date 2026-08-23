import { makeBook } from './foliate/view.js'
import { Overlayer } from './foliate/overlayer.js'
import { FootnoteHandler } from './foliate/footnotes.js'

const bridge = window.EnveFoliate
const sendNative = bridge.postMessage.bind(bridge)
let capability = null
let sequence = 0
const nativeSetAttribute = Element.prototype.setAttribute
Element.prototype.setAttribute = function(name, value) {
    if (this.localName === 'iframe' && String(name).toLocaleLowerCase() === 'sandbox') {
        const sandbox = String(value)
            .split(/\s+/)
            .filter(token => token && token !== 'allow-scripts')
            .join(' ')
        return nativeSetAttribute.call(this, name, sandbox)
    }
    return nativeSetAttribute.call(this, name, value)
}
const view = document.createElement('foliate-view')
document.body.append(view)

const postNative = (type, payload = null) => {
    if (type === 'initialState') {
        sendNative(JSON.stringify({ type }))
        return
    }
    if (!capability) return
    sequence += 1
    sendNative(JSON.stringify({ type, payload, capability, sequence }))
}

const requestInitialState = () => new Promise((resolve, reject) => {
    const timeout = setTimeout(
        () => reject(new Error('The native reader did not provide its initial state.')),
        10000,
    )
    bridge.onmessage = event => {
        clearTimeout(timeout)
        try {
            const state = JSON.parse(event.data)
            if (typeof state.capability !== 'string' || !state.capability) {
                throw new Error('Missing bridge capability')
            }
            capability = state.capability
            bridge.onmessage = null
            resolve(state)
        } catch {
            reject(new Error('The native reader returned invalid initial state.'))
        }
    }
    postNative('initialState')
})

let identity = {}
let preferences = {}
let customFonts = []
let lastLocation = null
let currentSelection = null
let userInteractionPending = false
let userInteractionToken = 0
let restorePending = true
let annotationValues = new Map()
let activeFootnote = null

const READER_THEMES = {
    LIGHT: { background: '#FFFFFF', text: '#161616', panel: '#FFFFFF', border: '#D8D8D8' },
    SEPIA: { background: '#F4ECD8', text: '#332D24', panel: '#F4ECD8', border: '#CFC2A5' },
    OLED: { background: '#000000', text: '#E8E8E8', panel: '#111111', border: '#353535' },
    DARK: { background: '#121212', text: '#E8E8E8', panel: '#202020', border: '#414141' },
}

const compact = value => String(value ?? '').normalize('NFC').replace(/\s+/g, ' ').trim()
const bounded = value => Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : null
const BIONIC_HIGHLIGHT = 'enve-bionic'
const markUserInteraction = () => {
    const token = ++userInteractionToken
    userInteractionPending = true
    setTimeout(() => {
        if (userInteractionToken === token) userInteractionPending = false
    }, 2000)
}

const applyBionicReading = (doc, enabled) => {
    const cssHighlights = doc.defaultView?.CSS?.highlights
    cssHighlights?.delete(BIONIC_HIGHLIGHT)
    doc.getElementById('enve-bionic-style')?.remove()
    if (!enabled) return
    if (!cssHighlights || typeof doc.defaultView.Highlight !== 'function') {
        throw new Error('compatibility:Bionic Reading requires a newer Android System WebView.')
    }

    const ranges = []
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
            const parent = node.parentElement
            if (!parent || parent.closest('script,style,noscript,svg,math')) {
                return NodeFilter.FILTER_REJECT
            }
            return NodeFilter.FILTER_ACCEPT
        },
    })
    while (walker.nextNode()) {
        const node = walker.currentNode
        for (const match of node.data.matchAll(/[\p{L}\p{N}]+/gu)) {
            const length = Math.max(1, Math.ceil(match[0].length * 0.45))
            const range = doc.createRange()
            range.setStart(node, match.index)
            range.setEnd(node, match.index + length)
            ranges.push(range)
        }
    }
    cssHighlights.set(BIONIC_HIGHLIGHT, new doc.defaultView.Highlight(...ranges))
    const style = doc.createElement('style')
    style.id = 'enve-bionic-style'
    style.textContent = `::highlight(${BIONIC_HIGHLIGHT}) {
        text-shadow: 0.025em 0 currentColor, -0.025em 0 currentColor;
    }`
    doc.head.append(style)
}

const cssPath = element => {
    if (!element || element.nodeType !== 1) return null
    if (element.id) return `#${CSS.escape(element.id)}`
    const parts = []
    let current = element
    while (current && current.nodeType === Node.ELEMENT_NODE && current !== current.ownerDocument.body) {
        const tag = current.localName
        if (!tag) break
        const siblings = Array.from(current.parentElement?.children ?? [])
            .filter(item => item.localName === tag)
        const suffix = siblings.length > 1
            ? `:nth-of-type(${siblings.indexOf(current) + 1})`
            : ''
        parts.unshift(`${tag}${suffix}`)
        current = current.parentElement
    }
    parts.unshift('body')
    return parts.join(' > ')
}

const domPoint = (container, offset) => {
    if (!container) return null
    if (container.nodeType === Node.TEXT_NODE) {
        const element = container.parentElement
        if (!element) return null
        const walker = element.ownerDocument.createTreeWalker(
            element,
            NodeFilter.SHOW_TEXT,
        )
        const textNodes = []
        while (walker.nextNode()) textNodes.push(walker.currentNode)
        return {
            cssSelector: cssPath(element),
            textNodeIndex: Math.max(0, textNodes.indexOf(container)),
            charOffset: Math.max(0, offset),
        }
    }
    return null
}

const domRange = range => {
    const start = domPoint(range?.startContainer, range?.startOffset)
    if (!start?.cssSelector) return null
    const end = domPoint(range.endContainer, range.endOffset)
    return { start, ...(end?.cssSelector ? { end } : {}) }
}

const rangeFromDomPoint = (doc, point) => {
    if (!point?.cssSelector) return null
    const element = doc.querySelector(point.cssSelector)
    if (!element) return null
    const walker = doc.createTreeWalker(element, NodeFilter.SHOW_TEXT)
    const textNodes = []
    while (walker.nextNode()) textNodes.push(walker.currentNode)
    const node = textNodes[point.textNodeIndex]
    if (!node) return null
    const maxOffset = node.data.length
    return {
        node,
        offset: Math.max(0, Math.min(maxOffset, point.charOffset ?? 0)),
    }
}

const rangeFromDomRange = (doc, saved) => {
    const start = rangeFromDomPoint(doc, saved?.start)
    if (!start) return null
    const end = rangeFromDomPoint(doc, saved?.end) ?? start
    try {
        const range = doc.createRange()
        range.setStart(start.node, start.offset)
        range.setEnd(end.node, end.offset)
        return range
    } catch {
        return null
    }
}

const textMap = root => {
    const doc = root.ownerDocument ?? root
    const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
            return node.parentElement?.closest('script,style,noscript,template')
                ? NodeFilter.FILTER_REJECT
                : NodeFilter.FILTER_ACCEPT
        },
    })
    const chars = []
    const points = []
    let pendingSpace = null
    while (walker.nextNode()) {
        const node = walker.currentNode
        for (const match of node.data.matchAll(/\P{M}\p{M}*|\p{M}+/gu)) {
            const source = match[0]
            const normalized = source.normalize('NFC')
            const startOffset = match.index
            const endOffset = startOffset + source.length
            if (/^\s+$/u.test(normalized)) {
                if (chars.length && chars[chars.length - 1] !== ' ' && !pendingSpace) {
                    pendingSpace = { node, offset: startOffset, endOffset }
                }
            } else {
                if (pendingSpace) {
                    chars.push(' ')
                    points.push(pendingSpace)
                    pendingSpace = null
                }
                for (let index = 0; index < normalized.length; index += 1) {
                    chars.push(normalized[index])
                    points.push({ node, offset: startOffset, endOffset })
                }
            }
        }
    }
    return { text: chars.join(''), points }
}

const rangeFromTextQuote = (doc, quote, selector) => {
    const exact = compact(quote?.exact)
    if (!exact) return null
    const selectedScope = selector
        ? (() => {
            try {
                return doc.querySelector(selector)
            } catch {
                return null
            }
        })()
        : null
    const findInScope = scope => {
        if (!scope) return null
        const mapped = textMap(scope)
        const haystack = mapped.text.toLocaleLowerCase()
        const needle = exact.toLocaleLowerCase()
        const prefix = compact(quote?.prefix).toLocaleLowerCase()
        const suffix = compact(quote?.suffix).toLocaleLowerCase()
        const matches = []
        let cursor = 0
        while (cursor <= haystack.length - needle.length) {
            const offset = haystack.indexOf(needle, cursor)
            if (offset < 0) break
            let score = 0
            if (prefix && haystack.slice(Math.max(0, offset - prefix.length), offset) === prefix) {
                score += 2
            }
            if (suffix && haystack.slice(offset + needle.length, offset + needle.length + suffix.length) === suffix) {
                score += 2
            }
            matches.push({ offset, score })
            cursor = offset + Math.max(1, needle.length)
        }
        const offset = matches.sort((a, b) => b.score - a.score)[0]?.offset ?? -1
        if (offset < 0) return null
        const start = mapped.points[offset]
        const end = mapped.points[Math.min(mapped.points.length - 1, offset + exact.length - 1)]
        if (!start || !end) return null
        const range = doc.createRange()
        range.setStart(start.node, start.offset)
        range.setEnd(end.node, Math.min(end.node.data.length, end.endOffset))
        return range
    }
    return findInScope(selectedScope) ?? findInScope(doc.body)
}

const rangeFromTextOffsets = (doc, mapped, start, end) => {
    const first = mapped.points[start]
    const last = mapped.points[end - 1]
    if (!first || !last) return null
    try {
        const range = doc.createRange()
        range.setStart(first.node, first.offset)
        range.setEnd(last.node, Math.min(last.node.data.length, last.endOffset))
        return range
    } catch {
        return null
    }
}

const sentenceSegments = text => {
    const output = []
    const pattern = /[^.!?]+(?:[.!?]+(?=\s|$)|$)/g
    let match
    while ((match = pattern.exec(text))) {
        const leading = match[0].search(/\S/)
        if (leading < 0) continue
        const trimmed = match[0].trimEnd()
        let start = match.index + leading
        const finish = match.index + trimmed.length
        while (finish - start > 240) {
            const limit = start + 220
            const split = text.lastIndexOf(' ', limit)
            const end = split > start + 80 ? split : limit
            output.push({ start, end })
            start = end
            while (text[start] === ' ') start += 1
        }
        if (finish - start >= 20) output.push({ start, end: finish })
    }
    return output
}

const middleVisibleAnchor = doc => {
    if (!doc?.body) return null
    const viewportX = doc.defaultView.innerWidth / 2
    const viewportY = doc.defaultView.innerHeight / 2
    let best = null
    for (const element of doc.querySelectorAll('p,li,blockquote,dd,dt,figcaption,pre')) {
        const mapped = textMap(element)
        if (mapped.text.length < 20) continue
        for (const segment of sentenceSegments(mapped.text)) {
            const range = rangeFromTextOffsets(doc, mapped, segment.start, segment.end)
            if (!range) continue
            for (const rect of range.getClientRects()) {
                if (rect.width <= 0 || rect.height <= 0) continue
                if (rect.bottom <= 0 || rect.top >= doc.defaultView.innerHeight ||
                    rect.right <= 0 || rect.left >= doc.defaultView.innerWidth) continue
                const x = (
                    Math.max(0, rect.left) +
                    Math.min(doc.defaultView.innerWidth, rect.right)
                ) / 2
                const y = (
                    Math.max(0, rect.top) +
                    Math.min(doc.defaultView.innerHeight, rect.bottom)
                ) / 2
                const distance = Math.hypot(x - viewportX, y - viewportY)
                if (!best || distance < best.distance) {
                    best = { element, mapped, segment, range, distance }
                }
            }
        }
    }
    if (!best) return null
    const exact = best.mapped.text.slice(best.segment.start, best.segment.end).trim()
    if (exact.length < 20) return null
    return {
        cssSelector: cssPath(best.element),
        domRange: domRange(best.range),
        textQuote: {
            exact,
            prefix: best.mapped.text
                .slice(Math.max(0, best.segment.start - 64), best.segment.start)
                .trim() || null,
            suffix: best.mapped.text
                .slice(best.segment.end, Math.min(best.mapped.text.length, best.segment.end + 64))
                .trim() || null,
        },
    }
}

const textQuote = range => {
    if (!range) return null
    const exact = compact(range.toString()).slice(0, 240)
    if (!exact) return null
    const element = range.startContainer.nodeType === Node.ELEMENT_NODE
        ? range.startContainer
        : range.startContainer.parentElement
    const context = compact(
        element?.closest?.('p,li,blockquote,dd,dt,figcaption,pre,div')?.textContent
            ?? element?.textContent,
    )
    const index = context.indexOf(exact)
    return {
        exact,
        prefix: index > 0 ? context.slice(Math.max(0, index - 64), index) : null,
        suffix: index >= 0 ? context.slice(index + exact.length, index + exact.length + 64) : null,
    }
}

const checkpointFromRange = (
    range,
    index,
    cfi,
    totalProgression,
    resourceProgression = null,
) => {
    const resolvedIndex = Number.isInteger(index)
        ? index
        : (view.renderer?.primaryIndex ?? 0)
    const section = view.book?.sections?.[resolvedIndex]
    const resolvedCfi = cfi?.startsWith('epubcfi(')
        ? cfi
        : range
            ? view.getCFI?.(resolvedIndex, range)
            : null
    const selector = range?.startContainer?.nodeType === Node.ELEMENT_NODE
        ? cssPath(range.startContainer)
        : cssPath(range?.startContainer?.parentElement)
    return {
        schemaVersion: 1,
        publicationSha256: identity.publicationSha256 ?? '',
        providerFileId: identity.providerFileId ?? null,
        revision: identity.revision ?? 0,
        writerEpoch: identity.writerEpoch ?? 0,
        observedAt: Date.now(),
        sourceEngine: 'foliate',
        href: section?.id == null ? null : String(section.id),
        epubCfi: resolvedCfi?.startsWith('epubcfi(') ? resolvedCfi : null,
        cssSelector: selector,
        domRange: domRange(range),
        resourceProgression: bounded(resourceProgression),
        totalProgression: bounded(totalProgression),
        textQuote: textQuote(range),
        nativeReadiumLocatorJson: null,
    }
}

const locatorFromCheckpoint = checkpoint => {
    if (!checkpoint?.href) return null
    const locations = {}
    if (checkpoint.epubCfi?.startsWith('epubcfi(')) {
        locations.cfi = checkpoint.epubCfi
    }
    if (Number.isFinite(checkpoint.resourceProgression)) {
        locations.progression = bounded(checkpoint.resourceProgression)
    }
    if (Number.isFinite(checkpoint.totalProgression)) {
        locations.totalProgression = bounded(checkpoint.totalProgression)
    }
    if (checkpoint.cssSelector) locations.cssSelector = checkpoint.cssSelector
    if (checkpoint.domRange) locations.domRange = checkpoint.domRange
    const locator = {
        href: checkpoint.href,
        type: 'application/xhtml+xml',
        locations,
    }
    if (checkpoint.textQuote?.exact) {
        locator.text = {
            before: checkpoint.textQuote.prefix ?? null,
            highlight: checkpoint.textQuote.exact,
            after: checkpoint.textQuote.suffix ?? null,
        }
    }
    return locator
}

const currentIndex = detail =>
    detail?.section?.current
        ?? view.renderer?.getContents?.()?.[0]?.index
        ?? 0

const currentResourceProgression = () => {
    const renderer = view.renderer
    if (renderer?.scrolled && Number.isFinite(renderer.start) &&
        Number.isFinite(renderer.viewSize) && renderer.viewSize > 0) {
        return bounded(renderer.start / renderer.viewSize)
    }
    if (Number.isFinite(renderer?.page) && Number.isFinite(renderer?.pages) &&
        renderer.pages > 2) {
        return bounded((renderer.page - 1) / (renderer.pages - 2))
    }
    return null
}

const totalProgressionFor = (index, resourceProgression) => {
    const sections = view.book?.sections ?? []
    const weights = sections.map(section =>
        Number.isFinite(section.size) && section.size > 0 ? section.size : 1,
    )
    const total = weights.reduce((sum, value) => sum + value, 0)
    if (!Number.isFinite(total) || total <= 0) return null
    const before = weights.slice(0, index).reduce((sum, value) => sum + value, 0)
    return bounded((before + (resourceProgression ?? 0) * (weights[index] ?? 0)) / total)
}

view.addEventListener('relocate', event => {
    const detail = event.detail ?? {}
    const index = currentIndex(detail)
    const sectionFractions = view.getSectionFractions?.() ?? []
    const sectionStart = sectionFractions[index]
    const sectionEnd = sectionFractions[index + 1]
    const sectionProgression = Number.isFinite(detail.fraction) &&
        Number.isFinite(sectionStart) &&
        Number.isFinite(sectionEnd) &&
        sectionEnd > sectionStart
        ? (detail.fraction - sectionStart) / (sectionEnd - sectionStart)
        : null
    const resourceProgression = bounded(sectionProgression) ?? currentResourceProgression()
    const totalProgression = bounded(detail.fraction)
        ?? totalProgressionFor(index, resourceProgression)
    const baseCheckpoint = checkpointFromRange(
        detail.range,
        index,
        detail.cfi,
        totalProgression,
        resourceProgression,
    )
    const doc = detail.range?.startContainer?.ownerDocument
        ?? view.renderer?.getContents?.()?.find(item => item.index === index)?.doc
    const anchor = middleVisibleAnchor(doc)
    const checkpoint = {
        ...baseCheckpoint,
        cssSelector: anchor?.cssSelector ?? baseCheckpoint.cssSelector,
        domRange: anchor?.domRange ?? baseCheckpoint.domRange,
        textQuote: anchor?.textQuote ?? baseCheckpoint.textQuote,
    }
    const payload = {
        checkpoint,
        locator: locatorFromCheckpoint(checkpoint),
        currentPage: Math.max(1, (detail.location?.current ?? 0) + 1),
        totalPages: Math.max(1, detail.location?.total ?? 1),
        sectionTitle: detail.tocItem?.label ?? '',
        userInitiated: userInteractionPending && !restorePending,
    }
    userInteractionToken += 1
    userInteractionPending = false
    lastLocation = payload
    postNative('relocate', payload)
})

view.addEventListener('load', event => {
    const { doc, index } = event.detail
    let selectionGestureLocked = false
    let selectionLockTimer = null
    let selectionPublishTimer = null
    const publishSelection = () => {
        clearTimeout(selectionPublishTimer)
        const selection = doc.defaultView.getSelection()
        if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
            currentSelection = null
            postNative('selection')
            selectionGestureLocked = false
            return
        }
        const range = selection.getRangeAt(0)
        const checkpoint = checkpointFromRange(
            range,
            index,
            view.getCFI(index, range),
            lastLocation?.checkpoint?.totalProgression,
        )
        currentSelection = locatorFromCheckpoint(checkpoint)
        postNative('selection', { locator: currentSelection })
        selectionGestureLocked = false
    }
    const scheduleSelectionPublish = () => {
        clearTimeout(selectionPublishTimer)
        selectionPublishTimer = setTimeout(publishSelection, 75)
    }
    try {
        applyBionicReading(doc, preferences.bionicReading === true)
    } catch (error) {
        postNative('error', { message: String(error?.message ?? error) })
    }
    doc.addEventListener('touchstart', () => {
        markUserInteraction()
        clearTimeout(selectionLockTimer)
        selectionGestureLocked = Boolean(
            currentSelection ||
            (doc.defaultView.getSelection()?.isCollapsed === false),
        )
        if (!selectionGestureLocked) {
            selectionLockTimer = setTimeout(() => {
                selectionGestureLocked = true
            }, 350)
        }
    }, { passive: true })
    doc.addEventListener('touchmove', event => {
        const selection = doc.defaultView.getSelection()
        if (selectionGestureLocked || (selection && !selection.isCollapsed)) {
            event.stopImmediatePropagation()
        }
    }, { capture: true, passive: true })
    doc.addEventListener('touchcancel', () => {
        clearTimeout(selectionLockTimer)
        scheduleSelectionPublish()
    }, { passive: true })
    doc.addEventListener('touchend', () => {
        clearTimeout(selectionLockTimer)
        scheduleSelectionPublish()
    }, { passive: true })
    doc.addEventListener('selectionchange', scheduleSelectionPublish)
})

view.addEventListener('external-link', event => {
    event.preventDefault()
    postNative('externalLink', { href: String(event.detail?.href ?? '') })
})

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
        const theme = READER_THEMES[preferences.theme] ?? READER_THEMES.DARK
        noteView.renderer?.setStyles?.(`
            :root { color-scheme: ${preferences.theme === 'LIGHT' || preferences.theme === 'SEPIA' ? 'light' : 'dark'}; }
            html, body {
                background: ${theme.panel} !important;
                color: ${theme.text} !important;
                font-family: inherit;
                line-height: ${Math.max(1, Math.min(2.5, preferences.lineHeight ?? 1.4))};
            }
            a { color: #F5921A !important; }
        `)
        activeFootnote.overlay.querySelector('.footnote-close')?.focus()
    })
})

view.addEventListener('link', event => {
    const handled = footnotes.handle(view.book, event)
    handled?.catch(error => {
        console.error('Footnote popup failed', error)
        closeFootnote()
        view.goTo(event.detail?.href)
    })
})

document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && activeFootnote) {
        event.preventDefault()
        closeFootnote()
    }
})

view.addEventListener('draw-annotation', event => {
    const { draw, annotation } = event.detail
    const options = { color: annotation.color ?? '#F5921A' }
    const renderer = {
        underline: Overlayer.underline,
        strikethrough: Overlayer.strikethrough,
        squiggly: Overlayer.squiggly,
        highlight: Overlayer.highlight,
    }[annotation.style] ?? Overlayer.highlight
    draw(renderer, options)
})

view.addEventListener('show-annotation', event => {
    const id = annotationValues.get(event.detail.value)
    if (id) postNative('annotationActivated', { id })
})

window.open = () => null

const applyPreferences = next => {
    preferences = { ...preferences, ...(next ?? {}) }
    const theme = READER_THEMES[preferences.theme] ?? READER_THEMES.DARK
    document.documentElement.style.background = theme.background
    document.documentElement.style.setProperty('--footnote-panel', theme.panel)
    document.documentElement.style.setProperty('--footnote-text', theme.text)
    document.documentElement.style.setProperty('--footnote-border', theme.border)
    document.body.style.background = theme.background
    const fonts = {
        SERIF: 'serif',
        SANS: 'sans-serif',
        DYSLEXIC: 'OpenDyslexic, sans-serif',
        MONO: 'monospace',
        LITERATA: 'Literata, serif',
        ATKINSON: 'Atkinson Hyperlegible, sans-serif',
        LEXEND: 'Lexend, sans-serif',
        IA_WRITER: 'iA Writer Duo, monospace',
    }
    const customFont = customFonts.find(
        item => item.family === preferences.customFontName,
    )
    const customFontCss = customFont
        ? `"${customFont.family.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`
        : null
    const customFontFaces = (customFonts ?? []).flatMap(font =>
        (font.faces ?? []).map(face => `
            @font-face {
                font-family: "${font.family.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}";
                src: url("${face.url}");
                font-weight: ${face.weight};
                font-style: ${face.style};
                font-display: block;
            }
        `),
    ).join('\n')
    const important = preferences.publisherStyles === false ? ' !important' : ''
    view.renderer?.setStyles?.(`
        ${customFontFaces}
        :root {
            color-scheme: ${preferences.theme === 'LIGHT' || preferences.theme === 'SEPIA' ? 'light' : 'dark'};
            background: ${theme.background}${important};
            color: ${theme.text}${important};
        }
        html, body {
            background: ${theme.background}${important};
            color: ${theme.text}${important};
            font-family: ${customFontCss ?? fonts[preferences.font] ?? fonts.SERIF}${important};
            font-size: ${Math.max(0.7, Math.min(4, preferences.fontSize ?? 1))}em${important};
            line-height: ${Math.max(1, Math.min(2.5, preferences.lineHeight ?? 1.4))}${important};
            word-spacing: ${preferences.wordSpacing ?? 0}em${important};
            letter-spacing: ${preferences.letterSpacing ?? 0}em${important};
            font-weight: ${Math.round(400 * (preferences.fontWeight ?? 1))}${important};
            text-align: ${preferences.justified === false ? 'start' : 'justify'}${important};
        }
        p {
            margin-block: ${Math.max(0, preferences.paragraphSpacing ?? 0)}em${important};
            text-indent: ${Math.max(0, preferences.paragraphIndent ?? 0)}em${important};
        }
    `)
    view.renderer?.setAttribute('flow', preferences.scroll ? 'scrolled' : 'paginated')
    view.renderer?.setAttribute(
        'gap',
        `${Math.min(7, Math.max(0, preferences.pageMargins ?? 1) * 7)}%`,
    )
    view.renderer?.setAttribute(
        'margin',
        `${Math.round(48 * Math.max(0, Math.min(2, preferences.pageMargins ?? 1)))}px`,
    )
    const columns = preferences.columns === 'ONE' ? 1 : preferences.columns === 'TWO' ? 2 : 0
    if (columns > 0) view.renderer?.setAttribute('max-column-count', String(columns))
    else view.renderer?.removeAttribute('max-column-count')
    for (const { doc } of view.renderer?.getContents?.() ?? []) {
        try {
            applyBionicReading(doc, preferences.bionicReading === true)
        } catch (error) {
            postNative('error', { message: String(error?.message ?? error) })
        }
    }
}

const restoreFromCheckpoint = async checkpoint => {
    if (!checkpoint) return 'start'
    if (checkpoint.epubCfi?.startsWith('epubcfi(')) {
        try {
            const resolved = view.resolveCFI(checkpoint.epubCfi)
            if (
                resolved &&
                Number.isInteger(resolved.index) &&
                resolved.index >= 0 &&
                resolved.index < view.book.sections.length
            ) {
                await view.renderer.goTo(resolved)
                return 'cfi'
            }
        } catch {}
    }
    const hasPortableAnchor = Boolean(
        checkpoint.textQuote?.exact ||
        checkpoint.domRange ||
        checkpoint.cssSelector
    )
    const hasResourceProgression = Number.isFinite(checkpoint.resourceProgression)
    const shouldUseHref = checkpoint.href && (
        hasPortableAnchor ||
        hasResourceProgression ||
        !Number.isFinite(checkpoint.totalProgression)
    )
    if (shouldUseHref) {
        try {
            const resolved = view.book.resolveHref(checkpoint.href)
            if (
                resolved &&
                Number.isInteger(resolved.index) &&
                resolved.index >= 0 &&
                resolved.index < view.book.sections.length
            ) {
                let restoreMethod = 'href'
                const anchor = doc => {
                    const text = rangeFromTextQuote(
                        doc,
                        checkpoint.textQuote,
                        checkpoint.cssSelector,
                    )
                    if (text) {
                        restoreMethod = 'textQuote'
                        return text
                    }
                    const savedRange = rangeFromDomRange(doc, checkpoint.domRange)
                    if (savedRange) {
                        restoreMethod = 'domRange'
                        return savedRange
                    }
                    if (checkpoint.cssSelector) {
                        try {
                            const element = doc.querySelector(checkpoint.cssSelector)
                            if (element) {
                                restoreMethod = 'cssSelector'
                                return element
                            }
                        } catch {}
                    }
                    if (Number.isFinite(checkpoint.resourceProgression)) {
                        restoreMethod = 'resourceProgression'
                        return bounded(checkpoint.resourceProgression)
                    }
                    return resolved.anchor?.(doc) ?? 0
                }
                await view.renderer.goTo({ ...resolved, anchor })
                return restoreMethod
            }
        } catch {}
    }
    if (Number.isFinite(checkpoint.totalProgression) && checkpoint.totalProgression > 0) {
        try {
            await view.goToFraction(bounded(checkpoint.totalProgression))
            return 'progression'
        } catch {}
    }
    return 'start'
}

const flattenToc = (items, depth = 0) => (items ?? []).flatMap(item => [
    { title: compact(item.label) || 'Untitled', href: item.href ?? '', depth },
    ...flattenToc(item.subitems, depth + 1),
])

const sanitizePublicationDocument = (source, mediaType) => {
    const value = String(source ?? '')
    const parserType = mediaType === 'text/html' ||
        /^\s*(?:<\?xml[\s\S]*?\?>\s*)?(?:<!doctype\s+html|<html(?:\s|>))/i.test(value)
        ? 'text/html'
        : 'application/xml'
    let doc = new DOMParser().parseFromString(value, parserType)
    let outputType = parserType === 'text/html'
        ? 'text/html'
        : (mediaType || parserType)
    if (parserType !== 'text/html' && doc.querySelector('parsererror')) {
        if (mediaType.includes('html')) {
            doc = new DOMParser().parseFromString(value, 'text/html')
            outputType = 'text/html'
        } else {
            const error = compact(doc.querySelector('parsererror')?.textContent)
            throw new Error(`compatibility:Invalid ${mediaType || 'XML'} publication resource: ${error}`)
        }
    }

    for (const element of doc.querySelectorAll('*')) {
        for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name.toLocaleLowerCase()
            const value = attribute.value.trim().toLocaleLowerCase()
            if (name.startsWith('on') || name === 'srcdoc' || value.startsWith('javascript:')) {
                element.removeAttribute(attribute.name)
            }
        }

        const name = element.localName?.toLocaleLowerCase()
        if (name === 'script') {
            element.setAttribute('type', 'application/x-enve-blocked')
            element.removeAttribute('src')
            element.removeAttribute('href')
            element.removeAttribute('xlink:href')
            element.textContent = ''
        } else if (['iframe', 'frame', 'object', 'embed', 'applet'].includes(name)) {
            for (const attribute of ['src', 'data', 'srcdoc', 'code', 'codebase']) {
                element.removeAttribute(attribute)
            }
            if (name === 'iframe' || name === 'frame') {
                element.setAttribute('sandbox', '')
            }
        } else if (name === 'meta' &&
            element.getAttribute('http-equiv')?.toLocaleLowerCase() === 'refresh') {
            element.removeAttribute('content')
        }
    }

    const data = doc.contentType === 'text/html'
        ? `<!doctype html>${doc.documentElement.outerHTML}`
        : new XMLSerializer().serializeToString(doc)
    return { data, type: outputType }
}

const hardenPublication = book => {
    book.transformTarget?.addEventListener('load', event => {
        if (event.detail?.isScript) event.detail.allow = false
    })
    book.transformTarget?.addEventListener('data', event => {
        const detail = event.detail ?? {}
        detail.data = Promise.resolve(detail.data)
            .then(source => {
                const value = String(source ?? '')
                const mediaType = String(detail.type ?? '').toLocaleLowerCase()
                const declaredDocument = mediaType.includes('html') ||
                    mediaType.includes('xml') ||
                    mediaType.includes('svg')
                const sniffedDocument =
                    /^\s*(?:<\?xml[\s\S]*?\?>\s*)?<(?:!doctype\s+html|html|svg)(?:\s|>)/i
                        .test(value)
                if (!declaredDocument && !sniffedDocument) return source
                const sanitized = sanitizePublicationDocument(value, mediaType)
                detail.type = sanitized.type
                return sanitized.data
            })
            .catch(error => {
                postNative('error', { message: String(error?.message ?? error) })
                return ''
            })
    })
}

const annotationCfi = async annotation => {
    if (annotation.cfi?.startsWith('epubcfi(')) {
        try {
            if (view.resolveCFI(annotation.cfi)) return annotation.cfi
        } catch {}
    }
    const locator = annotation.locator
    if (!locator?.href) return null
    try {
        const resolved = view.book.resolveHref(locator.href)
        const section = view.book.sections[resolved?.index]
        if (!resolved || !section?.createDocument) return null
        const doc = await section.createDocument()
        const checkpoint = {
            cssSelector: locator.locations?.cssSelector,
            domRange: locator.locations?.domRange,
            textQuote: locator.text?.highlight ? {
                exact: locator.text.highlight,
                prefix: locator.text.before,
                suffix: locator.text.after,
            } : null,
        }
        let anchor = rangeFromTextQuote(doc, checkpoint.textQuote, checkpoint.cssSelector)
            ?? rangeFromDomRange(doc, checkpoint.domRange)
        if (!anchor && checkpoint.cssSelector) {
            try {
                anchor = doc.querySelector(checkpoint.cssSelector)
            } catch {}
        }
        anchor ??= resolved.anchor?.(doc)
        if (!anchor) return null
        const range = anchor.startContainer
            ? anchor
            : (() => {
                const value = doc.createRange()
                value.selectNodeContents(anchor)
                return value
            })()
        return view.getCFI(resolved.index, range)
    } catch {
        return null
    }
}

window.enveReader = {
    goForward() {
        markUserInteraction()
        view.next()
    },
    goBackward() {
        markUserInteraction()
        view.prev()
    },
    goToProgress(fraction) {
        markUserInteraction()
        view.goToFraction(bounded(Number(fraction)) ?? 0)
    },
    goToHref(href) {
        markUserInteraction()
        view.goTo(String(href))
    },
    goToLocator(locator) {
        markUserInteraction()
        const checkpoint = locator?.checkpoint
        if (checkpoint) return restoreFromCheckpoint(checkpoint)
        const cfi = locator?.locations?.cfi?.startsWith('epubcfi(')
            ? locator.locations.cfi
            : null
        if (cfi) return view.goTo(cfi)
        if (locator?.href) return restoreFromCheckpoint({
            href: locator.href,
            cssSelector: locator.locations?.cssSelector,
            domRange: locator.locations?.domRange,
            resourceProgression: locator.locations?.progression,
            totalProgression: locator.locations?.totalProgression,
            textQuote: locator.text?.highlight ? {
                exact: locator.text.highlight,
                prefix: locator.text.before,
                suffix: locator.text.after,
            } : null,
        })
    },
    applyPreferences(next) {
        applyPreferences(next)
    },
    async applyAnnotations(annotations) {
        for (const value of annotationValues.keys()) {
            await view.deleteAnnotation({ value }).catch(() => {})
        }
        annotationValues = new Map()
        for (const annotation of annotations ?? []) {
            const cfi = await annotationCfi(annotation)
            if (!cfi) continue
            annotationValues.set(cfi, annotation.id)
            await view.addAnnotation({
                value: cfi,
                color: annotation.color,
                style: annotation.style,
            }).catch(() => {})
        }
    },
    clearSelection() {
        view.deselect()
        currentSelection = null
        postNative('selection')
    },
    clearSearch() {
        view.clearSearch()
    },
    autoScrollStep(distance) {
        markUserInteraction()
        view.next(Math.max(1, Number(distance) || 1))
    },
    async search(requestId, query, limit) {
        const output = []
        try {
            for await (const result of view.search({ query })) {
                for (const item of result.subitems ?? []) {
                    const resolved = view.resolveCFI(item.cfi)
                    const index = resolved?.index ?? result.index ?? 0
                    const checkpoint = checkpointFromRange(
                        null,
                        index,
                        item.cfi,
                        view.book.sections.length > 0
                            ? (index + 0.5) / view.book.sections.length
                            : 0,
                    )
                    output.push({
                        locator: locatorFromCheckpoint({
                            ...checkpoint,
                            textQuote: { exact: compact(item.excerpt?.match ?? item.excerpt ?? '') },
                        }),
                        excerpt: compact(
                            typeof item.excerpt === 'string'
                                ? item.excerpt
                                : [
                                    item.excerpt?.pre,
                                    item.excerpt?.match,
                                    item.excerpt?.post,
                                ].filter(Boolean).join(' '),
                        ),
                    })
                    if (output.length >= limit) break
                }
                if (output.length >= limit) break
            }
            postNative('searchResult', { requestId, results: output })
        } catch (error) {
            postNative('searchResult', {
                requestId,
                error: String(error?.message ?? error),
            })
        }
    },
    close() {
        closeFootnote()
        view.close()
    },
}

const boot = async () => {
    try {
        const initial = await requestInitialState()
        identity = initial.identity ?? {}
        preferences = initial.preferences ?? {}
        customFonts = initial.customFonts ?? []
        const response = await fetch('/book/current.epub', { cache: 'no-store' })
        if (!response.ok) throw new Error(`EPUB request failed (${response.status})`)
        const file = new File(
            [await response.blob()],
            'book.epub',
            { type: 'application/epub+zip' },
        )
        const book = await makeBook(file)
        hardenPublication(book)
        await view.open(book)
        applyPreferences(preferences)
        const relocated = new Promise(resolve => {
            view.addEventListener('relocate', () => resolve(), { once: true })
        })
        const method = await restoreFromCheckpoint(initial.checkpoint)
        if (method === 'start') await view.next()
        await Promise.race([
            relocated,
            new Promise(resolve => setTimeout(resolve, 10000)),
        ])
        restorePending = false
        postNative('ready', {
            title: compact(view.book.metadata?.title),
            toc: flattenToc(view.book.toc),
            restoreMethod: method,
            checkpoint: lastLocation?.checkpoint ?? null,
        })
    } catch (error) {
        postNative('error', { message: String(error?.message ?? error) })
    }
}

boot()
