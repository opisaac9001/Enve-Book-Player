import Testing
import WebKit
@testable import enve

@MainActor
struct ReaderLayoutRuntimeTests {
    @Test func overflowFitsWhilePublisherTablesAndColumnFragmentsKeepTheirStyle() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        let rows = (0..<60).map { "<tr><td>Entry \($0)</td><td>Value</td></tr>" }.joined()
        let lines = (0..<80).map { "Short line \($0)" }.joined(separator: "\n")
        webView.loadHTMLString("""
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"/>
            <style>html{width:320px;height:500px}body{margin:0;width:320px;height:500px;column-width:320px;column-gap:32px}td{font:14px serif}</style></head><body>
            <table id="small" style="width:128px;border:3px solid rgb(10,20,30)"><tr><td>Small</td></tr></table>
            <table id="wide" style="width:2400px"><tr><td>Oversized</td><td>Table</td></tr></table>
            <pre id="long">\(String(repeating: "unbroken", count: 70))</pre>
            <table id="tall" style="width:128px">\(rows)</table>
            <pre id="tall-pre">\(lines)</pre>
            </body></html>
            """, baseURL: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if (try? await webView.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('wide')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let result = try await webView.evaluateJavaScript(ReaderWideContentScript.source)
        #expect(ReaderWideContentScript.parse(result) == .changed)
        let values = try #require(try await webView.evaluateJavaScript("""
            (() => {
                const maxWidth = id => Math.max(...Array.from(document.getElementById(id).getClientRects(), r => r.width));
                const tagged = id => Array.from(document.getElementById(id).attributes).some(a => a.name.startsWith('data-enve-fit'));
                return {wide:maxWidth('wide'), small:maxWidth('small'), tall:maxWidth('tall'),
                    smallTagged:tagged('small'), tallTagged:tagged('tall'), preTagged:tagged('tall-pre'),
                    border:getComputedStyle(document.getElementById('small')).borderTopColor,
                    longWhiteSpace:getComputedStyle(document.getElementById('long')).whiteSpace};
            })()
            """) as? [String: Any])
        #expect((values["wide"] as? Double ?? .infinity) <= 321)
        #expect((values["small"] as? Double ?? 0) == 128)
        #expect((values["tall"] as? Double ?? 0) == 128)
        #expect(values["smallTagged"] as? Bool == false)
        #expect(values["tallTagged"] as? Bool == false)
        #expect(values["preTagged"] as? Bool == false)
        #expect(values["border"] as? String == "rgb(10, 20, 30)")
        #expect(values["longWhiteSpace"] as? String == "pre-wrap")
        #expect(ReaderWideContentScript.parse(try await webView.evaluateJavaScript(ReaderWideContentScript.source)) == .stable)
    }
}
