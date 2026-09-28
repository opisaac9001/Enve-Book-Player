import Foundation
import Testing

@testable import enve

@MainActor
struct OPDSProgressionDocumentTests {

    // MARK: Decoding

    @Test func draftExampleThreeDecodesCompletely() throws {
        let document = try decode(
            """
            {
              "title": "Chapter 1 - A New Dawn",
              "modified": "2026-01-27T11:00:00Z",
              "device": {
                "id": "urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a",
                "name": "Ebook Reader (Pixel 10 Pro)"
              },
              "progression": 0.0174920,
              "references": ["chapter1.html#:~:text=It%20was%20expected"]
            }
            """
        )

        #expect(document.title == "Chapter 1 - A New Dawn")
        #expect(document.device.id == "urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a")
        #expect(document.device.name == "Ebook Reader (Pixel 10 Pro)")
        #expect(abs(document.progression - 0.0174920) < 1e-9)
        #expect(document.references == ["chapter1.html#:~:text=It%20was%20expected"])
        #expect(document.point.scrollToText == "It was expected")
        #expect(document.point.resourcePath == "chapter1.html")
    }

    @Test func draftExampleEightDecodesToAnAudioPosition() throws {
        let document = try decode(
            """
            {"title":"Part 4","modified":"2025-12-25T12:00:00Z",
             "device":{"id":"urn:uuid:019c0049-6e8c-745c-adb1-5b03f8ad50c4","name":"Audiobook Player"},
             "progression":0.72370325,"references":["#t=849.250"]}
            """
        )

        #expect(document.point.audioSeconds == 849.25)
    }

    @Test func anAbsentReferencesArrayDecodesToNoReferences() throws {
        let document = try decode(
            """
            {"modified":"2026-01-28T19:00:00Z","device":{"id":"https://reader.example.com","name":"Web Reader"},
             "progression":0.048204}
            """
        )

        #expect(document.references.isEmpty)
        #expect(document.title == nil)
    }

    @Test func membersTheDraftDoesNotDefineAreIgnoredRatherThanRefused() throws {
        let document = try decode(
            """
            {"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":"Reader"},
             "progression":0.5,"somethingNew":{"a":1}}
            """
        )

        #expect(document.progression == 0.5)
    }

    @Test(arguments: [
        #"{"device":{"id":"urn:uuid:1","name":"R"},"progression":0.5}"#,
        #"{"modified":"2026-01-28T19:00:00Z","progression":0.5}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":"R"}}"#,
        #"{"modified":"yesterday","device":{"id":"urn:uuid:1","name":"R"},"progression":0.5}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":""},"progression":0.5}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"name":"R"},"progression":0.5}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":"R"},"progression":1.5}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":"R"},"progression":-0.1}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":"R"},"progression":"0.5"}"#,
        #"{"modified":"2026-01-28T19:00:00Z","device":{"id":"urn:uuid:1","name":"R"},"progression":0.5,"references":"chapter1.html"}"#,
    ])
    func aDocumentThatBreaksTheSchemaIsRefused(body: String) {
        #expect(throws: (any Error).self) { try decode(body) }
    }

    // MARK: URIs

    /// The schema types `device.id` as a URI, and a service that sends something else is not identifying
    /// the device it wrote from — which is the one thing the member exists to do.
    @Test(arguments: [
        "", "reader-1", "1nvalid:scheme", "urn uuid 1", " urn:uuid:1", "urn:uuid:1\n", "urn:uuid:%zz",
        "urn:uuid:%2", "urn:uuid:a<b>",
    ])
    func aDeviceIdentifierThatIsNotAURIIsRefused(id: String) {
        #expect(throws: (any Error).self) { try decode(deviceId: id) }
    }

    @Test(arguments: ["urn:uuid:019c0047-cc8d-7ec4-a3c3-938ccadc020a", "https://reader.example.com/1", "x+y-z.1:a"])
    func aDeviceIdentifierThatIsAURIIsAccepted(id: String) throws {
        #expect(try decode(deviceId: id).device.id == id)
    }

    @Test(arguments: [
        "chapter 1.html", "chapter1.html#par\u{7}", "chapter%zz.html", "chapter%2.html", "c<1>.html",
        "\n#t=5", "", "1a:b/c.html",
    ])
    func aReferenceThatIsNotAURIReferenceIsRefused(reference: String) {
        #expect(throws: (any Error).self) { try decode(references: [reference]) }
    }

    /// A relative path, a fragment-only reference and a percent-encoded directive are all URI references,
    /// and so is an unencoded accented path: a catalog writes one far more often than it encodes one.
    @Test(arguments: [
        "chapter1.html",
        "#par36",
        "#t=849.250",
        "/opds/books/1/chapter1.html",
        "https://cdn.example.com/c1.html#:~:text=It%20was%20expected",
        "#epubcfi(/6/4[chap01]!/4/2/2)",
        "?spread=2#page=6",
        "chapitre-é.html",
    ])
    func aValidURIReferenceIsKept(reference: String) throws {
        #expect(try decode(references: [reference]).references == [reference])
    }

    @Test(arguments: ["2026-01-27T11:00:00Z", "2026-01-27T11:00:00.123Z", "2026-01-27T12:00:00+01:00"])
    func bothFractionalAndWholeSecondTimestampsAreAccepted(timestamp: String) throws {
        let document = try decode(
            #"{"modified":"\#(timestamp)","device":{"id":"urn:uuid:1","name":"R"},"progression":0.5}"#
        )

        #expect(document.modified.timeIntervalSince1970 > 0)
    }

    // MARK: Encoding

    @Test func referencesSurviveADecodeAndEncodeUnchanged() throws {
        let references = ["#t=40.274", "chapter1.html#par36", "#vendorSpecific=1", "page78.jxl"]
        let original = try decode(
            ##"""
            {"modified":"2026-01-27T11:00:00Z","device":{"id":"urn:uuid:1","name":"R"},"progression":0.5,
             "references":["#t=40.274","chapter1.html#par36","#vendorSpecific=1","page78.jxl"]}
            """##
        )

        let encoded = try OPDSProgressionTransport.encode(original)
        let round = try JSONDecoder().decode(OPDSProgressionDocument.self, from: encoded)

        #expect(original.references == references)
        #expect(round.references == references)
        #expect(round == original)
    }

    @Test func anEncodedDocumentCarriesSubSecondPrecisionAndOmitsWhatIsAbsent() throws {
        let document = OPDSProgressionDocument(
            modified: Date(timeIntervalSince1970: 1_769_598_000.25),
            device: OPDSProgressionDevice(id: "urn:uuid:1", name: "Enve"),
            progression: 0.25
        )

        let json = try #require(
            try JSONSerialization.jsonObject(with: OPDSProgressionTransport.encode(document)) as? [String: Any]
        )

        #expect(!json.keys.contains("title"))
        #expect(!json.keys.contains("references"))
        #expect((json["modified"] as? String)?.contains(".250") == true)
        #expect(json["progression"] as? Double == 0.25)
    }

    @Test func aProgressionOutsideTheSchemaRangeIsClampedBeforeItIsSent() {
        let document = OPDSProgressionDocument(
            modified: Date(),
            device: OPDSProgressionDevice(id: "urn:uuid:1", name: "Enve"),
            progression: 1.4
        )

        #expect(document.progression == 1)
    }

    // MARK: Problem details

    @Test func aProblemDetailsObjectResolvesToItsRegistryIdentifier() throws {
        let details = try JSONDecoder().decode(
            OPDSProblemDetails.self,
            from: Data(
                #"{"type":"https://registry.opds.io/error#progression-date","title":"A more recent progression point is already available."}"#
                    .utf8
            )
        )

        #expect(details.registry == .staleDate)
        #expect(details.message == "A more recent progression point is already available.")
    }

    @Test func aProblemDetailsObjectWithoutATitleIsNotAProblemDetailsObject() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                OPDSProblemDetails.self,
                from: Data(#"{"type":"https://registry.opds.io/error#progression-date"}"#.utf8)
            )
        }
    }

    private func decode(_ body: String) throws -> OPDSProgressionDocument {
        try JSONDecoder().decode(OPDSProgressionDocument.self, from: Data(body.utf8))
    }

    /// Built through `JSONSerialization` so a control character or a stray backslash reaches the decoder as
    /// itself rather than as invalid JSON.
    private func decode(
        deviceId: String = "urn:uuid:1",
        references: [String]? = nil
    ) throws -> OPDSProgressionDocument {
        var payload: [String: Any] = [
            "modified": "2026-01-27T11:00:00Z",
            "device": ["id": deviceId, "name": "Reader"],
            "progression": 0.5,
        ]
        if let references { payload["references"] = references }
        return try JSONDecoder().decode(
            OPDSProgressionDocument.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }
}
