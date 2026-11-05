import Foundation
import Testing

@testable import enve

@MainActor
struct ListeningPositionLinkTests {
    private let message =
        #"{"a":["Antoine de Saint-Exupéry"],"dur":5400000,"isbn":"9782070612758","k":"enve.position","pos":1,"t":"Le \"Petit\" Prince \\ Édition","v":1}"#

    private func webData() throws -> String {
        let url = ListeningPositionLink.shareURL(for: try ListeningPositionPayload.decode(message))
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "d" }?.value)
    }

    @Test func webLinkCarriesThePayloadInTheQuery() throws {
        let url = ListeningPositionLink.shareURL(for: try ListeningPositionPayload.decode(message))
        #expect(url.absoluteString.hasPrefix("https://envemedia.com/position/?d="))
        #expect(url.fragment == nil)
        let data = try webData()
        #expect(!data.contains("="))
        #expect(ListeningPositionLink.message(from: URL(string: "enve-book://position?d=\(data)")!) == message)
    }

    @Test func appSchemeLinkRoundTrips() throws {
        let data = try webData()
        #expect(ListeningPositionLink.message(from: URL(string: "enve-book://position?d=\(data)")!) == message)
    }

    @Test func matchesAndroidEncoding() throws {
        // Android's java.util.Base64 URL encoder without padding produces this for the same payload.
        let android = "eyJhIjpbIkFudG9pbmUgZGUgU2FpbnQtRXh1cMOpcnkiXSwiZHVyIjo1NDAwMDAwLCJpc2JuIjoiOTc4MjA3MDYxMjc1OCIsImsiOiJlbnZlLnBvc2l0aW9uIiwicG9zIjoxLCJ0IjoiTGUgXCJQZXRpdFwiIFByaW5jZSBcXCDDiWRpdGlvbiIsInYiOjF9"
        #expect(try webData() == android)
    }

    @Test func rejectsOtherLinks() throws {
        let data = try webData()
        for link in [
            "enve-book://reader?d=\(data)",
            "enve-book://player?bookID=1",
            "https://example.com/position/?d=\(data)",
            "https://envemedia.com/position/?d=\(data)",
            "enve://position?d=\(data)",
            "enve-book://position",
            "https://envemedia.com/position/",
            "enve-book://position?d=!!!",
        ] {
            #expect(ListeningPositionLink.message(from: URL(string: link)!) == nil, "\(link)")
        }
    }
}
