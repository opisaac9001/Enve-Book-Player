import CoreGraphics
import Foundation
import UIKit

enum TVPagedDocument {
    case pdf(URL, pageCount: Int)
    case comic([URL], rightToLeft: Bool)

    var pageCount: Int {
        switch self {
        case .pdf(_, let count): count
        case .comic(let pages, _): pages.count
        }
    }

    var rightToLeft: Bool {
        if case .comic(_, let rightToLeft) = self { return rightToLeft }
        return false
    }

    func image(at pageIndex: Int) async throws -> UIImage {
        let document = self
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let image: UIImage
            switch document {
            case .pdf(let url, _):
                guard let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: pageIndex + 1) else {
                    throw TVPublicationError("This PDF page could not be opened.")
                }
                let box = page.getBoxRect(.cropBox)
                let rotated = page.rotationAngle % 180 != 0
                let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
                guard pageSize.width.isFinite, pageSize.height.isFinite, pageSize.width > 0, pageSize.height > 0 else {
                    throw TVPublicationError("This PDF page has an invalid size.")
                }
                let scale = min(2560 / max(pageSize.width, pageSize.height), 3)
                let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
                guard size.width > 0, size.height > 0 else {
                    throw TVPublicationError("This PDF page has an invalid size.")
                }
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                format.opaque = true
                image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
                    let bounds = CGRect(origin: .zero, size: size)
                    renderer.cgContext.setFillColor(UIColor.white.cgColor)
                    renderer.cgContext.fill(bounds)
                    renderer.cgContext.translateBy(x: 0, y: size.height)
                    renderer.cgContext.scaleBy(x: scale, y: -scale)
                    renderer.cgContext.concatenate(page.getDrawingTransform(
                        .cropBox, rect: CGRect(origin: .zero, size: pageSize), rotate: 0, preserveAspectRatio: true
                    ))
                    renderer.cgContext.drawPDFPage(page)
                }
            case .comic(let pages, _):
                let data = try Data(contentsOf: pages[pageIndex], options: .mappedIfSafe)
                guard let decoded = DiskImageCache.decodeDownsampled(data, maxPixelSize: 2560) else {
                    throw TVPublicationError("This comic page could not be decoded.")
                }
                image = decoded
            }
            try Task.checkCancellation()
            return image
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

nonisolated struct TVPublicationError: LocalizedError {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { message }
}
