import Foundation
import ReadiumShared
import Testing

@testable import enve

nonisolated struct GrimmoryEpubStreamingTests {
    @Test func streamedResourcesExposeManifestLengthsBeforeFetchingData() async throws {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let counter = GrimmoryFetchCounter()
        let knownPath = "OEBPS/chapter.xhtml"
        let unknownPath = "META-INF/container.xml"
        let session = GrimmoryEpubStreamingSession(
            entries: [
                .init(path: knownPath, mediaType: "application/xhtml+xml", size: 4_096),
                .init(path: unknownPath, mediaType: "application/xml", size: 0),
            ],
            cacheRoot: cacheRoot,
            fetchRemote: { _ in
                await counter.increment()
                return Data(repeating: 0x41, count: 16)
            }
        )
        let container = StreamedGrimmoryEpubContainer(session: session)
        let knownURL = try #require(RelativeURL(path: knownPath)?.normalized)
        let unknownURL = try #require(RelativeURL(path: unknownPath)?.normalized)
        let knownResource = try #require(container[knownURL])
        let unknownResource = try #require(container[unknownURL])

        #expect(try await knownResource.estimatedLength().get() == 4_096)
        #expect(try await unknownResource.estimatedLength().get() == nil)
        let fetchesBeforeRead = await counter.value
        #expect(fetchesBeforeRead == 0)

        #expect(try await knownResource.read().get().count == 16)
        let fetchesAfterRead = await counter.value
        #expect(fetchesAfterRead == 1)
    }
}

private actor GrimmoryFetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
