import CoreGraphics
import Foundation

enum PDFPageAdjust: String, CaseIterable, Identifiable {
    case crop, fit, fillHeight, fillWidth

    static let maximumZoom: CGFloat = 6

    var id: String { rawValue }

    var label: String {
        switch self {
        case .crop: "Crop"
        case .fit: "Fit"
        case .fillHeight: "Fill Height"
        case .fillWidth: "Fill Width"
        }
    }

    func scale(fitting content: CGSize, in viewport: CGSize) -> CGFloat? {
        guard content.width > 0, content.height > 0, viewport.width > 0, viewport.height > 0 else { return nil }
        let widthRatio = viewport.width / content.width
        let heightRatio = viewport.height / content.height
        switch self {
        case .crop: return max(widthRatio, heightRatio)
        case .fit: return min(widthRatio, heightRatio)
        case .fillHeight: return heightRatio
        case .fillWidth: return widthRatio
        }
    }
}

struct PDFReadingLayout: Equatable {
    var twoPageEnabled = false
    var showsCoverSeparately = false
    var pageAdjust: PDFPageAdjust = .fit
}

@MainActor
final class PDFReadingPreferencesStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func layout(forBookID bookID: String) -> PDFReadingLayout {
        PDFReadingLayout(
            twoPageEnabled: defaults.bool(forKey: twoPageKey(bookID)),
            showsCoverSeparately: defaults.bool(forKey: coverKey(bookID)),
            pageAdjust: defaults.string(forKey: pageAdjustKey(bookID)).flatMap(PDFPageAdjust.init(rawValue:)) ?? .fit
        )
    }

    func setLayout(_ layout: PDFReadingLayout, forBookID bookID: String) {
        store(layout.twoPageEnabled, forKey: twoPageKey(bookID))
        store(layout.showsCoverSeparately, forKey: coverKey(bookID))
        if layout.pageAdjust == .fit {
            defaults.removeObject(forKey: pageAdjustKey(bookID))
        } else {
            defaults.set(layout.pageAdjust.rawValue, forKey: pageAdjustKey(bookID))
        }
    }

    private func store(_ value: Bool, forKey key: String) {
        if value {
            defaults.set(true, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func twoPageKey(_ bookID: String) -> String {
        "reader.pdf.twoPage.\(bookID)"
    }

    private func coverKey(_ bookID: String) -> String {
        "reader.pdf.coverSeparately.\(bookID)"
    }

    private func pageAdjustKey(_ bookID: String) -> String {
        "reader.pdf.pageAdjust.\(bookID)"
    }
}
