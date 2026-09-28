import Foundation
import ReadiumZIPFoundation
import Testing

@testable import enve

/// CrossPoint speaks plain KOSync but exercises corners of it that the reference server does not:
/// idiomatic 2xx codes, filename document matching, and xpointers with a bracketed text-node index.
@MainActor
struct KOReaderCrossPointInteropTests {

    // MARK: - Response classification

    @Test func onlyCredentialRejectionsCountAsUnauthorized() {
        for code in [200, 201, 202, 204] {
            #expect(KOReaderResponseClass(statusCode: code) == .success)
        }
        for code in [401, 402] {
            #expect(KOReaderResponseClass(statusCode: code) == .unauthorized)
        }
        // CrossPoint answers 403 for a closed registration or a malformed document id: the request
        // was refused, not the identity, so re-prompting for a password would be wrong.
        for code in [403, 404, 409, 500, 503] {
            #expect(KOReaderResponseClass(statusCode: code) == .failure)
        }
    }

    // MARK: - Configuration

    @Test func matchingDefaultsToFileContentsForBothNewAndLegacyConfigurations() throws {
        let legacy = Data(
            """
            {"serverURL":"https://sync.koreader.rocks","username":"reader","passwordHash":"","autoSyncEnabled":true}
            """.utf8
        )

        let decoded = try JSONDecoder().decode(KOReaderConfig.self, from: legacy)

        #expect(decoded.serverURL == "https://sync.koreader.rocks")
        #expect(decoded.documentMatching == .binary)
        #expect(decoded.sendsDocumentMetadata == false)
        #expect(KOReaderConfig().documentMatching == .binary)
    }

    @Test func metadataIsOmittedWhenEveryFieldIsBlank() {
        #expect(KOReaderDocumentMetadata(filename: "", title: "", authors: "").jsonObject == nil)
        #expect(
            KOReaderDocumentMetadata(filename: "book.epub", title: "Book", authors: "").jsonObject == [
                "filename": "book.epub", "title": "Book",
            ]
        )
    }

    // MARK: - Document matching

    @Test func filenameHashIgnoresTheContainingDirectory() {
        let nested = URL(fileURLWithPath: "/srv/enve-lab/media/books/nested/book.epub")
        let flat = URL(fileURLWithPath: "/var/mobile/book.epub")

        #expect(KOReaderSyncService.filenameHash(fileURL: nested) == "03053ffc045564439ff7f2cabb3b58c5")
        #expect(KOReaderSyncService.filenameHash(fileURL: flat) == KOReaderSyncService.filenameHash(fileURL: nested))
    }

    @Test func smartPlanKeepsTheExistingLinkAndStillLooksForTheFilenameRecord() throws {
        let link = KOReaderBookLink(
            bookStableId: "book",
            documentHash: binary,
            isAutomatic: true,
            filenameHash: filename
        )

        let plan = try #require(
            KOReaderDocumentMatchPlan.make(matching: .smart, link: link, binaryHash: binary, filenameHash: filename)
        )

        #expect(plan.pushHash == binary)
        #expect(plan.fetchCandidates == [binary, filename])
    }

    @Test func smartPlanPushesToThePairedHashWhileStillProbingTheOthers() throws {
        let link = KOReaderBookLink(
            bookStableId: "book",
            documentHash: binary,
            isAutomatic: true,
            filenameHash: filename,
            matchedHash: filename
        )

        let plan = try #require(
            KOReaderDocumentMatchPlan.make(matching: .smart, link: link, binaryHash: binary, filenameHash: filename)
        )

        #expect(plan.pushHash == filename)
        // The peer can move back to content matching, and a plan that stopped probing never sees it.
        #expect(plan.fetchCandidates == [filename, binary])
        #expect(link.documentHash == binary)
    }

    @Test func smartPlanNeverRepeatsAHashWhenBothMethodsAgree() throws {
        let plan = try #require(
            KOReaderDocumentMatchPlan.make(matching: .smart, link: nil, binaryHash: binary, filenameHash: binary)
        )

        #expect(plan.fetchCandidates == [binary])
    }

    @Test func aPinnedHashIsTheOnlyHashConsidered() throws {
        let pinned = KOReaderBookLink(
            bookStableId: "book",
            documentHash: manual,
            isAutomatic: false,
            filenameHash: filename
        )

        let plan = try #require(
            KOReaderDocumentMatchPlan.make(matching: .smart, link: pinned, binaryHash: binary, filenameHash: filename)
        )

        #expect(plan.pushHash == manual)
        #expect(plan.fetchCandidates == [manual])
    }

    @Test func singleMethodModesUseExactlyOneHash() throws {
        let link = KOReaderBookLink(bookStableId: "book", documentHash: binary, isAutomatic: true, filenameHash: filename)

        let binaryPlan = try #require(
            KOReaderDocumentMatchPlan.make(matching: .binary, link: link, binaryHash: binary, filenameHash: filename)
        )
        let filenamePlan = try #require(
            KOReaderDocumentMatchPlan.make(matching: .filename, link: link, binaryHash: binary, filenameHash: filename)
        )

        #expect(binaryPlan.fetchCandidates == [binary])
        #expect(filenamePlan.fetchCandidates == [filename])
        #expect(KOReaderDocumentMatchPlan.make(matching: .filename, link: link, binaryHash: binary, filenameHash: nil) == nil)
    }

    // MARK: - Choosing the peer to pair with

    @Test func theNewestPeerWriteDecidesWhichHashToPairWith() throws {
        let stale = try remoteProgress(percentage: 0.9, timestamp: 1_000)
        let fresh = try remoteProgress(percentage: 0.2, timestamp: 2_000)

        #expect(
            KOReaderSyncService.preferredPeerHash([(hash: binary, progress: stale), (hash: filename, progress: fresh)])
                == filename
        )
        #expect(
            KOReaderSyncService.preferredPeerHash([(hash: filename, progress: fresh), (hash: binary, progress: stale)])
                == filename
        )
    }

    @Test func percentageOnlyDecidesWhatTheServerClockCannot() throws {
        let unstampedAndFurther = try remoteProgress(percentage: 0.8, timestamp: nil)
        let unstampedAndBehind = try remoteProgress(percentage: 0.3, timestamp: 0)
        let stamped = try remoteProgress(percentage: 0.1, timestamp: 1_000)

        #expect(
            KOReaderSyncService.preferredPeerHash([
                (hash: binary, progress: unstampedAndBehind), (hash: filename, progress: unstampedAndFurther),
            ]) == filename
        )
        #expect(
            KOReaderSyncService.preferredPeerHash([
                (hash: filename, progress: unstampedAndFurther), (hash: binary, progress: stamped),
            ]) == binary
        )
    }

    @Test func identicalPeerRecordsSettleOnTheFirstCandidate() throws {
        let one = try remoteProgress(percentage: 0.5, timestamp: 1_000)
        let other = try remoteProgress(percentage: 0.5, timestamp: 1_000)

        #expect(
            KOReaderSyncService.preferredPeerHash([(hash: binary, progress: one), (hash: filename, progress: other)])
                == binary
        )
        #expect(
            KOReaderSyncService.preferredPeerHash([(hash: filename, progress: other), (hash: binary, progress: one)])
                == filename
        )
        #expect(KOReaderSyncService.preferredPeerHash([]) == nil)
    }

    // MARK: - Pairing lifetime

    @Test func rewritingTheFileKeepsAFilenameMatchButDropsAContentMatch() {
        let filenameMatched = KOReaderBookLink(
            bookStableId: "book",
            documentHash: binary,
            isAutomatic: true,
            filenameHash: filename,
            matchedHash: filename
        )

        let sameName = KOReaderSyncService.repairedLink(
            previous: filenameMatched,
            bookStableId: "book",
            documentHash: manual,
            isAutomatic: true,
            fileIdentity: nil,
            filenameHash: filename
        )
        #expect(sameName.matchedHash == filename)
        #expect(sameName.filenameHash == filename)

        var contentMatched = filenameMatched
        contentMatched.matchedHash = binary
        let rewritten = KOReaderSyncService.repairedLink(
            previous: contentMatched,
            bookStableId: "book",
            documentHash: manual,
            isAutomatic: true,
            fileIdentity: nil,
            filenameHash: filename
        )
        #expect(rewritten.matchedHash == nil)
        #expect(rewritten.filenameHash == filename)
    }

    @Test func renamingTheFileClearsAFilenameMatch() {
        let paired = KOReaderBookLink(
            bookStableId: "book",
            documentHash: binary,
            isAutomatic: true,
            filenameHash: filename,
            matchedHash: filename
        )

        // The contents did not change, so the content hash is the same one; only the name moved.
        let renamed = KOReaderSyncService.repairedLink(
            previous: paired,
            bookStableId: "book",
            documentHash: binary,
            isAutomatic: true,
            fileIdentity: nil,
            filenameHash: renamedFilename
        )

        #expect(renamed.filenameHash == renamedFilename)
        #expect(renamed.matchedHash == nil)
    }

    // MARK: - XPointer to partial CFI

    @Test func repeatedTagsResolveThroughTheFullAncestry() throws {
        let html = "<html><body><div><p>alpha</p><p>beta</p></div><div><p>gamma</p><p>delta</p></div></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(
                forXPointer: "/body/DocFragment[1]/body/div[2]/p[2]/text().3",
                html: html
            ) == "/4/4/4/1:3"
        )
        #expect(
            try KOReaderXPointerConverter.partialCFI(
                forXPointer: "/body/DocFragment[1]/body/div[1]/p[2]/text().0",
                html: html
            ) == "/4/2/4/1:0"
        )
    }

    @Test func aBracketedTextNodeIndexSelectsTheRunAfterTheInlineElement() throws {
        let html = "<html><body><p>one<em>two</em>three</p></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text().1", html: html)
                == "/4/2/1:1"
        )
        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text()[2].2", html: html)
                == "/4/2/3:2"
        )
    }

    @Test func characterOffsetsCrossFromScalarsToUTF16() throws {
        let html = "<html><body><p>a\u{1F600}b</p></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text().1", html: html)
                == "/4/2/1:1"
        )
        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text().2", html: html)
                == "/4/2/1:3"
        )
    }

    @Test func aCommentSplitsKOReaderTextNodesInsideOneAddressableCFINode() throws {
        let html = "<html><body><p>abc<!-- aside -->def</p></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text()[2].1", html: html)
                == "/4/2/1:4"
        )
    }

    @Test func cdataContentIsAddressableAsItsOwnTextNode() throws {
        let html = "<html><body><p>a<![CDATA[bc]]>d</p></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text()[2].1", html: html)
                == "/4/2/1:2"
        )
        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text()[3].0", html: html)
                == "/4/2/1:3"
        )
    }

    @Test func aNonRenderedSiblingStillOccupiesAnElementStep() throws {
        let html = "<html><body><style>p { margin: 0 }</style><p>text</p></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[1]/text().0", html: html)
                == "/4/4/1:0"
        )
    }

    @Test func anElementLevelOffsetAnchorsTheElementItself() throws {
        let html = "<html><body><p>a</p><p>b</p></body></html>"

        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/p[2].0", html: html) == "/4/4"
        )
        #expect(
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body", html: html) == "/4"
        )
    }

    @Test func aPathThatDoesNotExistFails() {
        let html = "<html><body><div><p>alpha</p></div></body></html>"

        #expect(throws: KOReaderXPointerConverter.ConversionError.self) {
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/body/DocFragment[1]/body/div[2]/p[1]", html: html)
        }
        #expect(throws: KOReaderXPointerConverter.ConversionError.self) {
            try KOReaderXPointerConverter.partialCFI(forXPointer: "/spine/3", html: html)
        }
    }

    // MARK: - Partial CFI back to XPointer

    @Test func theReverseWalkNamesEachSiblingIndex() throws {
        let html = "<html><body><div><p>alpha</p><p>beta</p></div><div><p>gamma</p><p>delta</p></div></body></html>"

        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/4/4/1:3", html: html) == "/div[2]/p[2]/text().3")
        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2/2", html: html) == "/div[1]/p[1].0")
    }

    @Test func theReverseWalkRecoversABracketedTextNodeIndex() throws {
        let html = "<html><body><p>one<em>two</em>three</p></body></html>"

        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2/3:2", html: html) == "/p[1]/text()[2].2")
        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2/1:1", html: html) == "/p[1]/text().1")
    }

    @Test func theReverseWalkRecoversScalarOffsets() throws {
        let html = "<html><body><p>a\u{1F600}b</p></body></html>"

        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2/1:3", html: html) == "/p[1]/text().2")
    }

    @Test func theReverseWalkSplitsACommentBackIntoTwoTextNodes() throws {
        let html = "<html><body><p>abc<!-- aside -->def</p></body></html>"

        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2/1:4", html: html) == "/p[1]/text()[2].1")
        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2/1:2", html: html) == "/p[1]/text().2")
    }

    @Test func anIdentifierAssertionOutranksThePositionItWasWrittenWith() throws {
        let html = "<html><body><div id=\"one\">x</div><div id=\"two\">y</div></body></html>"

        #expect(try KOReaderXPointerConverter.xpointerSuffix(forPartialCFI: "/4/2[two]/1:0", html: html) == "/div[2]/text().0")
    }

    // MARK: - Against a real EPUB container

    @Test func aRealEPUBRoundTripsThroughContainerOPFAndOneSpineItem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let epubURL = try await makeEPUB(in: root)
        let xpointer = "/body/DocFragment[2]/body/div[1]/p[2]/text().4"

        let locator = try #require(
            await KOReaderXPointerConverter.locatorJSON(xpointer: xpointer, percentage: 0.5, epubFileURL: epubURL)
        )

        #expect(locator.contains("\"href\":\"OEBPS/two.xhtml\""))
        #expect(locator.contains("\"partialCfi\":\"/4/2/4/1:4\""))
        #expect(
            try #require(await KOReaderXPointerConverter.xpointer(forLocatorJSON: locator, epubFileURL: epubURL))
                == xpointer
        )
    }

    // MARK: - Live server

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_CROSSPOINT_LIVE_URL"] != nil))
    func liveCrossPointRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = try #require(environment["ENVE_CROSSPOINT_LIVE_URL"])
        let username = try #require(environment["ENVE_CROSSPOINT_LIVE_USERNAME"])
        let password = try #require(environment["ENVE_CROSSPOINT_LIVE_PASSWORD"])
        let baseURL = try #require(URL(string: endpoint))
        let document = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let service = KOReaderSyncService.shared

        service.clearConfig()
        defer { service.clearConfig() }
        service.updateConfig(
            serverURL: endpoint,
            username: username,
            plaintextPassword: password,
            autoSync: true,
            documentMatching: .filename,
            sendsDocumentMetadata: true
        )

        try await service.authorize()

        do {
            try await service.pushProgress(
                documentHash: document,
                progress: "/body/DocFragment[2]/body/p[3]/text().14",
                percentage: 0.375,
                metadata: KOReaderDocumentMetadata(
                    filename: "crosspoint-live.epub",
                    title: "CrossPoint Live Test",
                    authors: "Enve"
                )
            )

            let initial = try #require(try await service.fetchProgress(documentHash: document))
            #expect(initial.document == document)
            #expect(initial.percentage == 0.375)
            #expect(initial.progress == "/body/DocFragment[2]/body/p[3]/text().14")

            try await Task.sleep(for: .seconds(1.1))
            try await writePeerProgress(
                baseURL: baseURL,
                username: username,
                password: password,
                document: document
            )

            let peer = try #require(try await service.fetchProgress(documentHash: document))
            #expect(peer.percentage == 0.625)
            #expect(peer.progress == "/body/DocFragment[4]/body/p[1]/text().8")
            #expect(peer.deviceId == "crosspoint-live-peer")
        } catch {
            try? await deleteLiveDocument(
                baseURL: baseURL,
                username: username,
                password: password,
                document: document
            )
            throw error
        }

        try await deleteLiveDocument(
            baseURL: baseURL,
            username: username,
            password: password,
            document: document
        )
        #expect(try await service.fetchProgress(documentHash: document) == nil)
    }

    // MARK: - Fixtures

    private func writePeerProgress(
        baseURL: URL,
        username: String,
        password: String,
        document: String
    ) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("syncs/progress"))
        request.httpMethod = "PUT"
        request.setValue(username, forHTTPHeaderField: "x-auth-user")
        request.setValue(KOReaderSyncService.md5Hex(password), forHTTPHeaderField: "x-auth-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "document": document,
            "progress": "/body/DocFragment[4]/body/p[1]/text().8",
            "percentage": 0.625,
            "device": "CrossPoint live test peer",
            "device_id": "crosspoint-live-peer",
        ])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    private func deleteLiveDocument(
        baseURL: URL,
        username: String,
        password: String,
        document: String
    ) async throws {
        var request = URLRequest(
            url: baseURL.appendingPathComponent("api/v1/progress").appendingPathComponent(document)
        )
        request.httpMethod = "DELETE"
        request.setValue(username, forHTTPHeaderField: "x-auth-user")
        request.setValue(KOReaderSyncService.md5Hex(password), forHTTPHeaderField: "x-auth-key")
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }

    private func remoteProgress(percentage: Double, timestamp: TimeInterval?) throws -> KOReaderProgress {
        var object: [String: Any] = [
            "document": binary,
            "progress": "/body/DocFragment[1]/body",
            "percentage": percentage,
            "device": "Peer",
            "device_id": "peer-device",
        ]
        if let timestamp { object["timestamp"] = timestamp }
        return try JSONDecoder().decode(KOReaderProgress.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func makeEPUB(in root: URL) async throws -> URL {
        let contents = root.appendingPathComponent("contents", isDirectory: true)
        let write: (String, String) throws -> Void = { path, text in
            let url = contents.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url)
        }

        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try write(
            "META-INF/container.xml",
            """
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """
        )
        try write(
            "OEBPS/content.opf",
            """
            <?xml version="1.0"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
              <metadata/>
              <manifest>
                <item id="c1" href="one.xhtml" media-type="application/xhtml+xml"/>
                <item id="c2" href="two.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
            </package>
            """
        )
        try write("OEBPS/one.xhtml", "<html><body><p>first</p></body></html>")
        try write("OEBPS/two.xhtml", "<html><body><div><p>alpha</p><p>beta gamma</p></div></body></html>")

        let epubURL = root.appendingPathComponent("book.epub")
        try await FileManager.default.zipItem(at: contents, to: epubURL, shouldKeepParent: false)
        return epubURL
    }

    private let binary = String(repeating: "a", count: 32)
    private let filename = String(repeating: "b", count: 32)
    private let manual = String(repeating: "c", count: 32)
    private let renamedFilename = String(repeating: "d", count: 32)
}
