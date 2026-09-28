import Foundation
import Testing

@testable import enve

struct KomgaReadiumProgressionTests {
    // GET /api/v1/books/{id}/progression from Komga 1.x, device renamed.
    private let capturedProgression = Data(
        #"""
        {"modified":"2026-09-26T10:45:00Z","device":{"id":"urn:uuid:00000000-0000-0000-0000-000000000001","name":"Enve"},"locator":{"href":"OEBPS/9176909207730625171_11043-0-0.txt.html","type":"application/xhtml+xml","locations":{"progression":0.2,"totalProgression":0.040462427},"text":{"highlight":"the gelid pavement."},"koboSpan":"kobo.50.5"}}
        """#.utf8
    )

    // GET /api/v1/books/{id}/positions, trimmed to three entries.
    private let capturedPositions = Data(
        #"""
        {"total":346,"positions":[{"href":"OEBPS/wrap0000.html","type":"application/xhtml+xml","locations":{"progression":0.0,"position":1,"totalProgression":0.0028901733},"koboSpan":"kobo.1.1"},{"href":"OEBPS/9176909207730625171_11043-0-0.txt.html","type":"application/xhtml+xml","locations":{"progression":0.0,"position":2,"totalProgression":0.0057803467},"koboSpan":"kobo.1.1"},{"href":"OEBPS/9176909207730625171_11043-0-0.txt.html","type":"application/xhtml+xml","locations":{"progression":0.015873017,"position":3,"totalProgression":0.00867052},"koboSpan":"kobo.1.1"}]}
        """#.utf8
    )

    @Test func aFetchedProgressionBecomesAReadiumLocator() throws {
        let progression = try #require(KomgaProvider.readiumProgression(from: capturedProgression))
        let locator = try #require(EpubCFI.jsonObject(progression.locator))
        let locations = try #require(locator["locations"] as? [String: Any])

        #expect(locator["href"] as? String == "OEBPS/9176909207730625171_11043-0-0.txt.html")
        #expect(locator["koboSpan"] == nil)
        #expect(locations["progression"] as? Double == 0.2)
        #expect((locator["text"] as? [String: Any])?["highlight"] as? String == "the gelid pavement.")
        #expect(abs((progression.totalProgression ?? 0) - 0.040462427) < 1e-9)
    }

    @Test func aReadiumLocatorIsSentInKomgasShape() throws {
        let readium = ##"{"href":"OEBPS/9176909207730625171_11043-0-0.txt.html#id00032","type":"application/xhtml+xml","locations":{"progression":0.1395,"totalProgression":0.02,"cssSelector":"#id00032","fragments":["id00032","epubcfi(/6/4!/4/68)"],"enveSourceEngine":"foliate"},"text":{"highlight":"the gelid pavement.","before":"light on "}}"##
        let locator = try #require(KomgaProvider.komgaLocator(fromReadiumLocator: readium, totalProgression: 0.0266))
        let locations = try #require(locator["locations"] as? [String: Any])
        let body = KomgaProvider.readiumProgressionBody(
            locator: locator,
            modified: Date(timeIntervalSince1970: 1_790_418_075.5),
            device: OPDSProgressionDevice(id: "urn:uuid:00000000-0000-0000-0000-000000000001", name: "Enve")
        )

        #expect(locator["href"] as? String == "OEBPS/9176909207730625171_11043-0-0.txt.html")
        #expect(Set(locations.keys) == ["progression", "totalProgression", "fragment"])
        #expect(locations["fragment"] as? [String] == ["id00032"])
        #expect(locations["totalProgression"] as? Double == 0.0266)
        #expect((locator["text"] as? [String: String])?["before"] == "light on ")
        #expect(body["modified"] as? String == "2026-09-26T10:21:15.500Z")
        #expect((body["device"] as? [String: String])?["name"] == "Enve")
        #expect(JSONSerialization.isValidJSONObject(body))
    }

    @Test func aProgressWithoutALocatorUsesTheKomgaPositionAtOrBeforeIt() throws {
        let locator = try #require(KomgaProvider.komgaLocator(fromPositions: capturedPositions, totalProgression: 0.007))

        #expect((locator["locations"] as? [String: Any])?["position"] as? Int == 2)
        #expect(locator["koboSpan"] == nil)
    }

    @Test func aLocatorWithoutAnHrefIsNotSent() {
        #expect(KomgaProvider.komgaLocator(fromReadiumLocator: #"{"locations":{"totalProgression":0.2}}"#, totalProgression: 0.2) == nil)
    }
}
