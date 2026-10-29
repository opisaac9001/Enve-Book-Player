import CoreText
import Foundation

nonisolated struct TVEpubPage {
    let sourcePage: Int
    let range: NSRange
    let text: String
    let frame: CTFrame
}

nonisolated enum TVEpubPagination {
    static func pages(_ sourcePages: [String], size: CGSize, font: CTFont, lineSpacing: CGFloat) -> [TVEpubPage] {
        guard size.width >= CTFontGetSize(font), size.height >= CTFontGetAscent(font) + CTFontGetDescent(font) else {
            return []
        }

        var spacing = lineSpacing
        let paragraph = withUnsafePointer(to: &spacing) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
        var pages: [TVEpubPage] = []

        for (sourcePage, text) in sourcePages.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            var offset = 0
            while offset < attributed.length {
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { return [] }
                let range = NSRange(location: visible.location, length: visible.length)
                pages.append(TVEpubPage(
                    sourcePage: sourcePage,
                    range: range,
                    text: (text as NSString).substring(with: range),
                    frame: frame
                ))
                offset = NSMaxRange(range)
            }
        }
        return pages
    }

    static func pageIndex(in pages: [TVEpubPage], sourcePage: Int, offset: Int) -> Int {
        pages.lastIndex {
            $0.sourcePage < sourcePage || ($0.sourcePage == sourcePage && $0.range.location <= offset)
        } ?? 0
    }
}
