import Foundation
import ImageIO
import UIKit

struct ReaderIllustrationReference: Equatable {
    let href: String
    let alt: String?
    let caption: String?

    static func resolvedHref(src: String, documentHref: String) -> String? {
        var raw = src.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cut = raw.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            raw = String(raw[..<cut])
        }
        guard !raw.isEmpty,
            raw.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil
        else {
            return nil
        }
        let decoded = raw.removingPercentEncoding ?? raw
        guard !decoded.hasPrefix("//"),
            decoded.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) == nil
        else { return nil }
        var document = documentHref
        if let cut = document.firstIndex(where: { $0 == "#" || $0 == "?" }) {
            document = String(document[..<cut])
        }
        document = document.removingPercentEncoding ?? document
        var segments: [String] =
            decoded.hasPrefix("/")
            ? []
            : document.split(separator: "/", omittingEmptySubsequences: true).dropLast().map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                _ = segments.popLast()
            default:
                segments.append(String(part))
            }
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "/")
    }
}

struct ReaderIllustration: Identifiable {
    let id = UUID()
    let image: UIImage
    let alt: String?
    let caption: String?
    let hasTransparency: Bool

    var subtitle: String? { caption ?? alt }
}

enum ReaderIllustrationScript {
    static let minimumDimension: Double = 48

    static func at(_ point: CGPoint) -> String {
        """
        (function () {
            var XLINK = 'http://www.w3.org/1999/xlink';
            function text(value) {
                var trimmed = String(value || '').replace(/\\s+/g, ' ').trim();
                return trimmed || null;
            }
            function describe(target) {
                var element = target && target.closest ? target.closest('img, image, svg') : null;
                if (!element || element.closest('a[href]')) return null;
                if (element.localName === 'svg') element = element.querySelector('image') || element;
                var source = element.getAttribute('src')
                    || element.getAttribute('href')
                    || element.getAttributeNS(XLINK, 'href');
                if (!source) return null;
                var rect = element.getBoundingClientRect();
                var figure = element.closest('figure');
                var figcaption = figure ? figure.querySelector('figcaption') : null;
                var svg = element.closest('svg');
                var label = svg ? svg.querySelector(':scope > title, :scope > desc') : null;
                return {
                    src: source,
                    alt: text(element.getAttribute('alt') || element.getAttribute('aria-label') || element.getAttribute('title')),
                    caption: text(figcaption && figcaption.textContent) || text(label && label.textContent),
                    width: rect.width,
                    height: rect.height
                };
            }
            return describe(document.elementFromPoint(\(point.x), \(point.y)));
        })();
        """
    }

    static func reference(from value: Any?, documentHref: String) -> ReaderIllustrationReference? {
        guard let payload = value as? [String: Any],
            let src = payload["src"] as? String,
            let width = (payload["width"] as? NSNumber)?.doubleValue,
            let height = (payload["height"] as? NSNumber)?.doubleValue,
            width >= minimumDimension,
            height >= minimumDimension,
            let href = ReaderIllustrationReference.resolvedHref(src: src, documentHref: documentHref)
        else {
            return nil
        }
        return ReaderIllustrationReference(
            href: href,
            alt: payload["alt"] as? String,
            caption: payload["caption"] as? String
        )
    }
}

nonisolated enum ReaderIllustrationDecoder {
    static let maxPixelSize = 4096

    static func image(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    static func hasAlpha(_ image: UIImage) -> Bool {
        guard let alphaInfo = image.cgImage?.alphaInfo else { return false }
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }
}
