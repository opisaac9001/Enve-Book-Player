#if os(iOS)
import CoreText
import Foundation
import UIKit

final class AnnotationExportFile: Identifiable {
    let id = UUID()
    let url: URL
    private let directory: URL

    init(data: Data, title: String, fileExtension: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnveHighlights-" + id.uuidString, isDirectory: true)
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let filename = String(title.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        url = directory.appendingPathComponent(filename.isEmpty ? "Highlights" : filename).appendingPathExtension(fileExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

extension AnnotationExporter {
    func makeFile(format: AnnotationExportFormat) throws -> AnnotationExportFile {
        let data = try format == .pdf ? pdfData() : Data(preview(format: format).utf8)
        return try AnnotationExportFile(data: data, title: bookTitle, fileExtension: format.fileExtension)
    }

    func pdfData() throws -> Data {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let text = NSAttributedString(
            string: preview(format: .plainText),
            attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.black, .paragraphStyle: paragraph]
        )
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let body = CGPath(rect: CGRect(x: 48, y: 72, width: 516, height: 672), transform: nil)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: bookTitle, kCGPDFContextCreator as String: "Enve Book Player"]
        var failedLayout = false
        let data = UIGraphicsPDFRenderer(bounds: page, format: format).pdfData { context in
            var offset = 0
            var pageNumber = 0
            while offset < text.length {
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), body, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { failedLayout = true; break }
                context.beginPage()
                pageNumber += 1
                UIColor.white.setFill()
                context.fill(page)
                context.cgContext.saveGState()
                context.cgContext.textMatrix = .identity
                context.cgContext.translateBy(x: 0, y: page.height)
                context.cgContext.scaleBy(x: 1, y: -1)
                CTFrameDraw(frame, context.cgContext)
                context.cgContext.restoreGState()
                ("Enve · \(pageNumber)" as NSString).draw(
                    at: CGPoint(x: 48, y: 750),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.darkGray]
                )
                offset += visible.length
            }
        }
        if failedLayout {
            throw NSError(domain: "AnnotationExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "The PDF couldn't fit this text. Try exporting as Markdown instead."])
        }
        return data
    }
}
#endif
