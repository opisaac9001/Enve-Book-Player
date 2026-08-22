import SwiftUI
import UIKit

@MainActor
final class AmbientColorStore {
    static let shared = AmbientColorStore()
    private init() {}

    private var cache: [String: Color] = [:]

    func color(for book: Book) -> Color {
        cache[book.stableId] ?? Hearth.accent
    }

    func resolve(for book: Book) async -> Color {
        if let cached = cache[book.stableId] { return cached }
        guard let url = book.coverURL else { return Hearth.accent }
        var image = DiskImageCache.shared.memoryImage(for: url)
        if image == nil {
            image = await DiskImageCache.shared.image(for: url)
        }
        guard let image, let extracted = Self.dominantColor(of: image) else { return Hearth.accent }
        let color = Self.warmed(extracted)
        cache[book.stableId] = color
        return color
    }

    private nonisolated static func dominantColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }
        let size = 8
        guard
            let context = CGContext(
                data: nil,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let data = context.data else { return nil }
        let ptr = data.bindMemory(to: UInt8.self, capacity: size * size * 4)

        var best: (score: Double, r: Double, g: Double, b: Double) = (-1, 0, 0, 0)
        var avg: (r: Double, g: Double, b: Double) = (0, 0, 0)
        for i in 0..<(size * size) {
            let r = Double(ptr[i * 4]) / 255
            let g = Double(ptr[i * 4 + 1]) / 255
            let b = Double(ptr[i * 4 + 2]) / 255
            avg.r += r; avg.g += g; avg.b += b
            let mx = max(r, g, b)
            let mn = min(r, g, b)
            let saturation = mx == 0 ? 0 : (mx - mn) / mx

            let score = saturation * (1 - abs(mx - 0.55))
            if score > best.score { best = (score, r, g, b) }
        }
        let n = Double(size * size)
        if best.score < 0.08 {
            return UIColor(red: avg.r / n, green: avg.g / n, blue: avg.b / n, alpha: 1)
        }
        return UIColor(red: best.r, green: best.g, blue: best.b, alpha: 1)
    }

    private nonisolated static func warmed(_ color: UIColor) -> Color {
        var h: CGFloat = 0
        var s: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let brightness = min(max(b, 0.45), 0.9)
        let saturation = min(max(s, 0.25), 0.85)
        return Color(uiColor: UIColor(hue: h, saturation: saturation, brightness: brightness, alpha: 1))
    }
}
