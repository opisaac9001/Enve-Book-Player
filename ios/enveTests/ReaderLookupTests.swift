import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderLookupTests {
    @Test func blankOrPunctuationOnlySelectionHasNoQuery() {
        #expect(ReaderLookup.wikipediaQuery(for: "  \n\t ") == nil)
        #expect(ReaderLookup.wikipediaQuery(for: "“…”") == nil)
    }

    @Test func shortSelectionIsCleanedWithoutShortening() {
        #expect(
            ReaderLookup.wikipediaQuery(for: "  “Mont\nSaint-Michel,” ")
                == .init(term: "Mont Saint-Michel", wasShortened: false)
        )
    }

    @Test func longSelectionIsShortenedOnAWordBoundary() throws {
        let selection = Array(repeating: "lighthouse", count: 40).joined(separator: " ")
        let query = try #require(ReaderLookup.wikipediaQuery(for: selection))
        #expect(query.wasShortened)
        #expect(query.term.count <= ReaderLookup.wikipediaQueryLimit)
        #expect(query.term.split(separator: " ").allSatisfy { $0 == "lighthouse" })
    }

    @Test func unbrokenLongSelectionIsCutAtTheLimit() throws {
        let query = try #require(ReaderLookup.wikipediaQuery(for: String(repeating: "a", count: 250)))
        #expect(query.wasShortened)
        #expect(query.term.count == ReaderLookup.wikipediaQueryLimit)
    }

    @Test(arguments: ["C++", "C#", ".NET"])
    func selectionPreservesMeaningfulSymbols(_ term: String) {
        #expect(ReaderLookup.wikipediaQuery(for: term)?.term == term)
    }

    @Test func searchURLEncodesReservedCharacters() throws {
        let url = try #require(ReaderLookup.wikipediaSearchURL(term: "C++ & Rust #1?", languageCode: "en"))
        #expect(url.scheme == "https")
        #expect(url.host == "en.m.wikipedia.org")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems == [URLQueryItem(name: "search", value: "C++ & Rust #1?")])
        #expect(components.percentEncodedQuery?.contains("+") == false)
    }

    @Test func searchURLRejectsEmptyAndOverlongTerms() {
        #expect(ReaderLookup.wikipediaSearchURL(term: " \n ", languageCode: "en") == nil)
        #expect(ReaderLookup.wikipediaSearchURL(term: String(repeating: "a", count: 301), languageCode: "en") == nil)
    }

    @Test(arguments: [(["fr-CA"], "fr"), (["nb-NO"], "no"), (["zh-Hant-TW"], "zh"), ([], "en")])
    func languageCodeFollowsPreferredLanguage(_ preferred: [String], _ expected: String) {
        #expect(ReaderLookup.wikipediaLanguageCode(preferredLanguages: preferred) == expected)
    }
}
