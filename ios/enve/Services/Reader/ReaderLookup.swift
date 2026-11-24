import Foundation

enum ReaderLookup {
    struct WikipediaQuery: Equatable {
        let term: String
        let wasShortened: Bool
    }

    static let wikipediaQueryLimit = 100
    static let wikipediaSearchLimit = 300

    static func normalizedSelection(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func wikipediaQuery(for selection: String) -> WikipediaQuery? {
        var edges = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces)
        edges.remove(charactersIn: "+#.-")
        let term = normalizedSelection(selection).trimmingCharacters(in: edges)
        guard term.rangeOfCharacter(from: .alphanumerics) != nil else { return nil }
        guard term.count > wikipediaQueryLimit else {
            return WikipediaQuery(term: term, wasShortened: false)
        }
        var shortened = ""
        for word in term.split(separator: " ") {
            let candidate = shortened.isEmpty ? String(word) : shortened + " " + word
            guard candidate.count <= wikipediaQueryLimit else { break }
            shortened = candidate
        }
        if shortened.isEmpty {
            shortened = String(term.prefix(wikipediaQueryLimit))
        }
        return WikipediaQuery(term: shortened.trimmingCharacters(in: edges), wasShortened: true)
    }

    static func wikipediaLanguageCode(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard let identifier = preferredLanguages.first,
            let code = Locale(identifier: identifier).language.languageCode?.identifier.lowercased(),
            (2...3).contains(code.count),
            code.allSatisfy({ $0.isASCII && $0.isLetter })
        else { return "en" }
        // Wikipedia hosts Norwegian Bokmål under the legacy "no" subdomain.
        return code == "nb" ? "no" : code
    }

    static func wikipediaSearchURL(term: String, languageCode: String) -> URL? {
        let cleaned = normalizedSelection(term)
        guard !cleaned.isEmpty, cleaned.count <= wikipediaSearchLimit else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(languageCode).m.wikipedia.org"
        components.path = "/w/index.php"
        components.queryItems = [URLQueryItem(name: "search", value: cleaned)]
        // URLComponents leaves "+" literal, which MediaWiki reads as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }
}
