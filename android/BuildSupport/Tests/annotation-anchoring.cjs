const { readFileSync } = require('node:fs')
const { resolve } = require('node:path')
const { createServer } = require('node:http')
const { chromium } = require('playwright')
const assert = require('node:assert/strict')

async function main() {
    const android = process.argv.includes('--android')
    const root = process.cwd()
    const source = readFileSync(resolve(root, android ? 'app/src/main/assets/foliate-reader.js' : 'BuildSupport/FoliateRuntime/adapter.js'), 'utf8')
    const cfiSource = readFileSync(resolve(root, 'ThirdParty/foliate-js/epubcfi.js'), 'utf8')
    const server = createServer((req, res) => {
        res.setHeader('Content-Type', req.url === '/epubcfi.js' ? 'text/javascript' : 'text/html')
        res.end(req.url === '/epubcfi.js' ? cfiSource : '<!doctype html><body>Annotation checks</body>')
    }).listen(0, '127.0.0.1')
    await new Promise(done => server.once('listening', done))
    const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true })
    try {
        const page = await browser.newPage()
        await page.goto(`http://127.0.0.1:${server.address().port}`)
        const result = await page.evaluate(async ({ source, android }) => {
            const CFI = await import('/epubcfi.js')
            const markup = '<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p>First passage. Second passage.</p><table><tr><td>Cell passage text.</td></tr></table></body></html>'
            const makeDoc = () => new DOMParser().parseFromString(markup, 'application/xhtml+xml')
            const doc = makeDoc()
            const range = doc.createRange()
            range.setStart(doc.querySelector('p').firstChild, 0)
            range.setEnd(doc.querySelector('p').firstChild, 14)
            const cfi = CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(range))
            const collapsed = range.cloneRange(); collapsed.collapse(true)
            const point = CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(collapsed))
            const htmlDoc = new DOMParser().parseFromString(markup, 'text/html')
            const htmlRange = htmlDoc.createRange()
            htmlRange.selectNodeContents(htmlDoc.querySelector('td'))
            const htmlCfi = CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(htmlRange))
            const xhtmlRange = doc.createRange()
            xhtmlRange.setStart(doc.querySelector('td').firstChild, 0)
            xhtmlRange.setEnd(doc.querySelector('td').firstChild, 'Cell passage text.'.length)
            const xhtmlCfi = CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(xhtmlRange))
            const posts = [], drawn = []
            const book = { sections: [{ createDocument: async () => makeDoc() }] }
            const view = {
                book,
                resolveCFI(value) {
                    const parts = CFI.parse(value)
                    const index = CFI.fake.toIndex((parts.parent ?? parts).shift())
                    return { index, anchor: target => CFI.toRange(target, parts) }
                },
                getCFI: (index, range) => CFI.joinIndir(CFI.fake.fromIndex(index), CFI.fromRange(range)),
                addAnnotation: async item => { drawn.push(item.value) },
                deleteAnnotation: async () => {},
                addEventListener: () => {},
            }
            let run
            if (android) {
                const anchoring = source.slice(source.indexOf('const compact ='), source.indexOf('\nconst bounded =')) + '\n' +
                    source.slice(source.indexOf('const domPoint ='), source.indexOf('\nconst rangeFromTextOffsets ='))
                const helpers = anchoring + '\n' + source.slice(source.indexOf('const normalizedAnnotationText ='), source.indexOf('\nwindow.enveReader ='))
                const method = source.slice(source.indexOf('    async applyAnnotations(annotations) {'), source.indexOf('    clearSelection()', source.indexOf('    async applyAnnotations(annotations) {')))
                run = new Function('view', 'postNative', `let annotationValues = new Map(); let annotationRevision = 0; ${helpers}; return ({${method}}).applyAnnotations`)(view, (type, payload) => posts.push(payload))
            } else {
                const helpers = source.slice(source.indexOf('let annotationRevision ='), source.indexOf('\nconst textNodeFromPoint'))
                run = new Function('view', 'book', 'post', `const annotationByCFI = new Map(); const drawnAnnotationCFIs = new Set(); ${helpers}; return drawAnnotations`)(view, book, (type, payload) => posts.push(payload))
            }
            const annotation = (id, cfi, text) => ({ id, cfi, text, color: '#ffff00', style: 'highlight', hasNote: false })
            await run([
                annotation('valid', cfi, 'First passage.'),
                annotation('wrong-edition', cfi, 'A different passage.'),
                annotation('broken', 'epubcfi(/6/999!/8/999:99)', 'Missing'),
                annotation('point', point, 'First passage.'),
                annotation('missing', '', 'Missing'),
                annotation('whitespace', cfi, ' First   passage. '),
                ...(android ? [annotation('html-dom', htmlCfi, 'Cell passage text.')] : []),
            ])
            const batch = posts.at(-1).results
            const firstDraws = drawn.length
            const firstDrawn = [...drawn]
            await run([annotation('repaired', cfi, 'First passage.')])
            return { batch, firstDraws, firstDrawn, htmlCfi, xhtmlCfi, retry: posts.at(-1).results }
        }, { source, android })
        assert.deepEqual(result.batch, [
            { id: 'valid', resolved: true },
            { id: 'wrong-edition', resolved: false },
            { id: 'broken', resolved: false },
            { id: 'point', resolved: android },
            { id: 'missing', resolved: false },
            { id: 'whitespace', resolved: true },
            ...(android ? [{ id: 'html-dom', resolved: true }] : []),
        ])
        assert.equal(result.firstDraws, android ? 2 : 1)
        if (android) {
            assert.notEqual(result.htmlCfi, result.xhtmlCfi)
            assert.ok(result.firstDrawn.includes(result.xhtmlCfi))
            assert.ok(!result.firstDrawn.includes(result.htmlCfi))
        }
        assert.deepEqual(result.retry, [{ id: 'repaired', resolved: true }])
        if (android) {
            const parsing = await page.evaluate(source => {
                const sanitize = new Function(`${source.slice(source.indexOf('const compact ='), source.indexOf('\nconst bounded ='))}
${source.slice(source.indexOf('const sanitizePublicationDocument ='), source.indexOf('\nconst hardenPublication ='))}
return sanitizePublicationDocument`)()
                const xhtml = sanitize('<?xml version="1.0" encoding="utf-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body><table><tr><td>Cell</td></tr></table><p><a id="n1"/><span class="koboSpan" id="kobo.1.1">Kobo text</span></p></body></html>', 'application/xhtml+xml')
                const rendered = new DOMParser().parseFromString(xhtml.data, xhtml.type)
                const html = sanitize('<html><body><p>Broken &nbsp;<br></p></body></html>', 'application/xhtml+xml')
                return {
                    xhtmlType: xhtml.type,
                    tbody: rendered.querySelectorAll('tbody').length,
                    anchorChildren: rendered.querySelector('a').childNodes.length,
                    spanParent: rendered.querySelector('span').parentNode.localName,
                    htmlType: html.type,
                }
            }, source)
            assert.deepEqual(parsing, { xhtmlType: 'application/xhtml+xml', tbody: 0, anchorChildren: 0, spanParent: 'p', htmlType: 'text/html' })
        }
        console.log(`${android ? 'Android' : 'iOS'}: actual EPUB CFI ranges, mismatched text, malformed anchors, collapsed points, whitespace, HTML-DOM quote fallback, XHTML-first parsing, isolated failures and retry passed`)
    } finally {
        await browser.close()
        server.close()
    }
}
main().catch(error => { console.error(error); process.exitCode = 1 })
