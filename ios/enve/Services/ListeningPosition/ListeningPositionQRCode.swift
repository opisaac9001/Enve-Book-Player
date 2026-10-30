import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit

enum ListeningPositionQRCode {
    nonisolated static let maxImageBytes = 20 * 1024 * 1024
    nonisolated static let maxImagePixels = 100_000_000
    nonisolated static let maxScanDimension = 2048

    nonisolated static func image(for message: String, moduleSize: CGFloat = 10) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: moduleSize, y: moduleSize)),
            let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        let border = 4 * moduleSize
        let size = CGSize(width: CGFloat(cgImage.width) + 2 * border, height: CGFloat(cgImage.height) + 2 * border)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cgImage).draw(at: CGPoint(x: border, y: border))
        }
    }

    /// Reads every QR message in an imported image. Only the text is returned; nothing it names is opened.
    nonisolated static func messages(inImageData data: Data) -> [String] {
        guard data.count <= maxImageBytes,
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 16384, height <= 16384,
            width <= maxImagePixels / height,
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxScanDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary),
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
        else { return [] }
        return detector.features(in: CIImage(cgImage: thumbnail)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
