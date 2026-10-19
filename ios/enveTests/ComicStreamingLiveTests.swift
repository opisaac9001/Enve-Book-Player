import Foundation
import ImageIO
import Testing

@testable import enve

@MainActor
struct ComicStreamingLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_COMIC_STREAMING_LIVE"] != nil))
    func providersStreamComicImagesWithoutDownloadingArchives() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_COMIC_STREAMING_LIVE"])
        let configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let tables = try #require(configuration["tables"] as? [String: [String: [String]]])
        let shared = try #require(configuration["shared"] as? [String: [String]])
        let profile = FamilyProfile(id: UUID().uuidString, name: "Comic streaming verification", role: .adult)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(profile.id)
        let domain = "ComicStreamingLive.\(profile.id)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        do {
            for service in ["Kavita", "Komga"] {
                let row = try #require(tables["Service endpoints"]?[service]?.joined(separator: " "))
                let range = try #require(row.range(of: #"https?://[^`\s|)]+"#, options: .regularExpression))
                var endpoint = try #require(URLComponents(string: String(row[range])))
                endpoint.host = try #require(configuration["remoteHost"] as? String)
                let connection = ServerConnection(name: "Comic lab", url: try #require(endpoint.url?.absoluteString),
                    type: service == "Kavita" ? .kavita : .komga,
                    username: service == "Kavita" ? shared["Username"]?.first : shared["Email"]?.first,
                    password: shared["Password"]?.first)
                let provider: any IncrementalCatalogProvider & ServerPageProvider
                if service == "Kavita" {
                    provider = KavitaProvider(connection: connection, profileSession: session)
                } else {
                    provider = KomgaProvider(connection: connection, profileSession: session)
                }
                #expect(try await provider.validateConnection())
                let libraries = try await provider.fetchLibraries()
                let library = try #require(libraries.first { $0.name.localizedCaseInsensitiveContains("comic") })
                let source = try await provider.makeCatalogBatchSource(libraryId: library.id,
                    resumeAfter: nil, expectedSnapshotIdentifier: nil)
                var selected: Book?
                while let batch = try await source.next() {
                    selected = batch.books.first { $0.isComic }
                    if selected != nil { break }
                }
                let book = try #require(selected)
                let clock = ContinuousClock()
                let start = clock.now
                let detail = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: library.id)
                let streaming = ServerPageStreamingService(cachesDirectory: storage.cachesDirectory)
                let pages = try await streaming.streamedPages(for: detail, provider: provider, mode: .onDemand)
                #expect(!pages.isEmpty)
                for page in [try #require(pages.first), try #require(pages.last)] {
                    let data = try await streaming.pageData(at: page)
                    #expect(CGImageSourceCreateWithData(data as CFData, nil) != nil)
                }
                #expect(session.ebooks.cachedEbook(forBookId: book.id) == nil)
                print("LAB \(service): \(pages.count) streamed pages; first/last images in \(start.duration(to: clock.now)); no archive download")
                streaming.endSession(for: detail)
                await provider.retire()
            }
        } catch {
            await session.retire()
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        await session.retire()
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
