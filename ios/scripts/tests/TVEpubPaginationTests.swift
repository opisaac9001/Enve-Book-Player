import CoreText
import Foundation

@main
struct TVEpubPaginationTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let sources = [
            String(repeating: "A quiet afternoon by the river. The last line must remain visible.\n\n", count: 60),
            String(repeating: "Short verse.\nAnother line.\n\n", count: 70),
            String(repeating: "長い文章と家族 👨‍👩‍👧‍👦 café e\u{301} — river. ", count: 100),
            String(repeating: "uninterrupted", count: 200),
        ]
        let font = CTFontCreateWithName("TimesNewRomanPSMT" as CFString, 32, nil)
        let sizes = [CGSize(width: 1500, height: 620), CGSize(width: 1100, height: 400)]

        for size in sizes {
            let pages = TVEpubPagination.pages(sources, size: size, font: font, lineSpacing: 14)
            expect(pages.count > sources.count, "Long source pages are divided to fit the viewport")
            for (sourceIndex, source) in sources.enumerated() {
                let sourcePages = pages.filter { $0.sourcePage == sourceIndex }
                expect(sourcePages.map(\.text).joined() == source, "Pagination preserves every character in order")
                var cursor = 0
                for page in sourcePages {
                    expect(page.range.location == cursor && page.range.length > 0, "Pages have no gaps or overlaps")
                    expect(Range(page.range, in: source) != nil, "Page boundaries preserve Unicode characters")
                    cursor = NSMaxRange(page.range)
                    let visible = CTFrameGetVisibleStringRange(page.frame)
                    expect(visible.location == page.range.location && visible.length == page.range.length,
                           "The rendered frame contains the complete saved page range")
                    let lines = CTFrameGetLines(page.frame) as! [CTLine]
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    CTFrameGetLineOrigins(page.frame, CFRange(location: 0, length: 0), &origins)
                    for (line, origin) in zip(lines, origins) {
                        var ascent: CGFloat = 0
                        var descent: CGFloat = 0
                        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                        expect(origin.y - descent >= -0.5, "No line descender is clipped at the bottom")
                        expect(origin.y + ascent <= size.height + 0.5, "No line is clipped at the top")
                    }
                }
                expect(cursor == (source as NSString).length, "The final page reaches the end of its source")
            }
        }

        let large = TVEpubPagination.pages(sources, size: sizes[0], font: font, lineSpacing: 14)
        let small = TVEpubPagination.pages(sources, size: sizes[1], font: font, lineSpacing: 14)
        expect(small.count > large.count, "A smaller viewport produces more pages")
        let location = large[2]
        let restored = small[TVEpubPagination.pageIndex(in: small, sourcePage: location.sourcePage, offset: location.range.location)]
        expect(restored.sourcePage == location.sourcePage && NSLocationInRange(location.range.location, restored.range),
               "Reflow resumes at the same source text instead of an unrelated page number")
        let previousChapterEnd = TVEpubPagination.pageIndex(in: large, sourcePage: sources.count - 1, offset: Int.max)
        expect(previousChapterEnd == large.count - 1, "Turning back across chapters selects the final fitted page")
        expect(TVEpubPagination.pages([], size: sizes[0], font: font, lineSpacing: 14).isEmpty, "Empty books have no fitted pages")
        expect(TVEpubPagination.pages(sources, size: .zero, font: font, lineSpacing: 14).isEmpty,
               "The initial zero-size layout does not attempt pagination")
        let largerFont = CTFontCreateCopyWithAttributes(font, 44, nil, nil)
        expect(TVEpubPagination.pages(sources, size: sizes[0], font: largerFont, lineSpacing: 14).count > large.count,
               "Larger type receives more pages instead of clipping")
        print("TV EPUB pagination: \(checks) regression checks passed.")
    }
}
