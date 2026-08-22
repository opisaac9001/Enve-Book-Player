import Foundation

enum EnveBookLink {
    static let scheme = "enve-book"

    static func readerURL(bookID: String, locator: String?) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "reader"
        components.queryItems = [
            URLQueryItem(name: "bookID", value: bookID),
            URLQueryItem(name: "locator", value: locator),
        ]
        return components.url!
    }

    static func playerURL(bookID: String, timestamp: TimeInterval) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "player"
        components.queryItems = [
            URLQueryItem(name: "bookID", value: bookID),
            URLQueryItem(name: "timestamp", value: String(timestamp)),
        ]
        return components.url!
    }

    static func readerRequest(from url: URL) -> (bookID: String, locator: String?)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme,
            components.host?.lowercased() == "reader",
            components.user == nil,
            components.password == nil,
            let bookID = components.queryItems?.first(where: { $0.name == "bookID" })?.value,
            !bookID.isEmpty
        else { return nil }
        let locator = components.queryItems?.first(where: { $0.name == "locator" })?.value
        return (bookID, locator)
    }

    static func playerRequest(from url: URL) -> (bookID: String, timestamp: TimeInterval?)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme,
            components.host?.lowercased() == "player",
            components.user == nil,
            components.password == nil,
            let bookID = components.queryItems?.first(where: { $0.name == "bookID" })?.value,
            !bookID.isEmpty
        else { return nil }
        let timestamp = components.queryItems?
            .first(where: { $0.name == "timestamp" })?.value
            .flatMap(TimeInterval.init)
        return (bookID, timestamp)
    }
}

enum EnveNotesCaptureLink {
    static func url(book: Book, annotation: ReaderAnnotation) -> URL {
        var components = URLComponents()
        components.scheme = "enve-notes"
        components.host = "capture"

        let selectedText = annotation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reflection = annotation.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLocation = annotation.chapterTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let returnLocator = EpubLocationBridge.compactReturnLocator(from: annotation.locator)

        components.queryItems = [
            URLQueryItem(name: "title", value: "\(book.title) - \(annotation.style.label)"),
            URLQueryItem(name: "reflection", value: reflection?.isEmpty == false ? reflection : nil),
            URLQueryItem(name: "tags", value: "book,\(annotation.style.rawValue)"),
            URLQueryItem(name: "app", value: "bookplayer"),
            URLQueryItem(name: "type", value: "highlight"),
            URLQueryItem(name: "provider", value: book.source.rawValue),
            URLQueryItem(name: "externalID", value: book.stableId),
            URLQueryItem(name: "sourceTitle", value: book.title),
            URLQueryItem(name: "sourceSubtitle", value: annotation.chapterTitle ?? book.author),
            URLQueryItem(name: "locator", value: returnLocator),
            URLQueryItem(name: "displayLocation", value: displayLocation?.isEmpty == false ? displayLocation : nil),
            URLQueryItem(name: "source", value: EnveBookLink.readerURL(bookID: book.stableId, locator: returnLocator).absoluteString),
            URLQueryItem(name: "quote", value: selectedText.isEmpty ? nil : selectedText),
        ]
        .filter { $0.value?.isEmpty == false }
        return components.url!
    }

    static func url(book: Book, bookmark: Bookmark) -> URL {
        var components = URLComponents()
        components.scheme = "enve-notes"
        components.host = "capture"

        let note = bookmark.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayLocation = bookmark.chapterTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let returnLocator =
            bookmark.mediaType == .ebook
            ? EpubLocationBridge.compactReturnLocator(from: bookmark.locator)
            : bookmark.locator
        components.queryItems = [
            URLQueryItem(name: "title", value: "\(book.title) - \(bookmark.title)"),
            URLQueryItem(name: "reflection", value: note?.isEmpty == false ? note : nil),
            URLQueryItem(name: "tags", value: "book,bookmark"),
            URLQueryItem(name: "app", value: "bookplayer"),
            URLQueryItem(name: "type", value: "bookmark"),
            URLQueryItem(name: "provider", value: book.source.rawValue),
            URLQueryItem(name: "externalID", value: book.stableId),
            URLQueryItem(name: "sourceTitle", value: book.title),
            URLQueryItem(name: "sourceSubtitle", value: bookmark.chapterTitle ?? book.author),
            URLQueryItem(name: "locator", value: returnLocator),
            URLQueryItem(name: "timestamp", value: bookmark.mediaType == .ebook ? nil : String(bookmark.position)),
            URLQueryItem(
                name: "displayLocation",
                value: bookmark.mediaType == .ebook && displayLocation?.isEmpty == false
                    ? displayLocation
                    : nil
            ),
            URLQueryItem(
                name: "source",
                value: bookmark.mediaType == .ebook
                    ? EnveBookLink.readerURL(bookID: book.stableId, locator: returnLocator).absoluteString
                    : EnveBookLink.playerURL(bookID: book.stableId, timestamp: bookmark.position).absoluteString
            ),
        ]
        .filter { $0.value?.isEmpty == false }
        return components.url!
    }
}
