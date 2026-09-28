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
            const makeDoc = () => new DOMParser().parseFromString('<html xmlns="http://www.w3.org/1999/xhtml"><head/><body><p>First passage. Second passage.</p></body></html>', 'application/xhtml+xml')
            const doc = makeDoc()
            const range = doc.createRange()
            range.setStart(doc.querySelector('p').firstChild, 0)
            range.setEnd(doc.querySelector('p').firstChild, 14)
            const cfi = CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(range))
            const collapsed = range.cloneRange(); collapsed.collapse(true)
            const point = CFI.joinIndir(CFI.fake.fromIndex(0), CFI.fromRange(collapsed))
            const posts = [], drawn = []
            const book = { sections: [{ createDocument: async () => makeDoc() }] }
            const view = {
                book,
                resolveCFI(value) {
                    const parts = CFI.parse(value)
                    const index = CFI.fake.toIndex((parts.parent ?? parts).shift())
                    return { index, anchor: target => CFI.toRange(target, parts) }
                },
                addAnnotation: async item => { drawn.push(item.value) },
                deleteAnnotation: async () => {},
                addEventListener: () => {},
            }
            let run
            if (android) {
                const helpers = source.slice(source.indexOf('const normalizedAnnotationText ='), source.indexOf('\nwindow.enveReader ='))
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
            ])
            const batch = posts.at(-1).results
            const firstDraws = drawn.length
            await run([annotation('repaired', cfi, 'First passage.')])
            return { batch, firstDraws, retry: posts.at(-1).results }
        }, { source, android })
        assert.deepEqual(result.batch, [
            { id: 'valid', resolved: true },
            { id: 'wrong-edition', resolved: false },
            { id: 'broken', resolved: false },
            { id: 'point', resolved: false },
            { id: 'missing', resolved: false },
            { id: 'whitespace', resolved: true },
        ])
        assert.equal(result.firstDraws, 1)
        assert.deepEqual(result.retry, [{ id: 'repaired', resolved: true }])
        console.log(`${android ? 'Android' : 'iOS'}: actual EPUB CFI ranges, mismatched text, malformed anchors, collapsed points, whitespace, isolated failures and retry passed`)
    } finally {
        await browser.close()
        server.close()
    }
}
main().catch(error => { console.error(error); process.exitCode = 1 })
