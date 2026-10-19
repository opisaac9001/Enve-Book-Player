import Foundation

@MainActor
final class ComicReadingDirectionStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func direction(forBookID bookID: String) -> ComicReadingDirection? {
        defaults.string(forKey: key(bookID)).flatMap(ComicReadingDirection.init(rawValue:))
    }

    func setDirection(_ direction: ComicReadingDirection?, forBookID bookID: String) {
        if let direction {
            defaults.set(direction.rawValue, forKey: key(bookID))
        } else {
            defaults.removeObject(forKey: key(bookID))
        }
    }

    func providerDirection(forBookID bookID: String) -> ComicReadingDirection? {
        defaults.string(forKey: providerKey(bookID)).flatMap(ComicReadingDirection.init(rawValue:))
    }

    func setProviderDirection(_ direction: ComicReadingDirection?, forBookID bookID: String) {
        if let direction {
            defaults.set(direction.rawValue, forKey: providerKey(bookID))
        } else {
            defaults.removeObject(forKey: providerKey(bookID))
        }
    }

    private func providerKey(_ bookID: String) -> String {
        "reader.comic.providerDirection.\(bookID)"
    }

    private func key(_ bookID: String) -> String {
        "reader.comic.directionOverride.\(bookID)"
    }
}
