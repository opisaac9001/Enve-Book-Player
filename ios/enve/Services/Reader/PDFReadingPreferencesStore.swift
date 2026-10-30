import Foundation

struct PDFReadingLayout: Equatable {
    var twoPageEnabled = false
    var showsCoverSeparately = false
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
            showsCoverSeparately: defaults.bool(forKey: coverKey(bookID))
        )
    }

    func setLayout(_ layout: PDFReadingLayout, forBookID bookID: String) {
        store(layout.twoPageEnabled, forKey: twoPageKey(bookID))
        store(layout.showsCoverSeparately, forKey: coverKey(bookID))
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
}
