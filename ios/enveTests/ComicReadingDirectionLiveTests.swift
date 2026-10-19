import Foundation
import Testing

@testable import enve

@MainActor
struct ComicReadingDirectionLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_COMIC_DIRECTION_LIVE"] != nil))
    func providersFollowTheComicAndSeriesMetadata() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_COMIC_DIRECTION_LIVE"])
        let configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let tables = try #require(configuration["tables"] as? [String: [String: [String]]])
        let shared = try #require(configuration["shared"] as? [String: [String]])
        let profile = FamilyProfile(id: UUID().uuidString, name: "Comic direction verification", role: .adult)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(profile.id)
        let domain = "ComicDirectionLive.\(profile.id)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        do {
            for service in ["Grimmory", "Komga"] {
                let row = try #require(tables["Service endpoints"]?[service]?.joined(separator: " "))
                let range = try #require(row.range(of: #"https?://[^`\s|)]+"#, options: .regularExpression))
                var endpoint = try #require(URLComponents(string: String(row[range])))
                endpoint.host = try #require(configuration["remoteHost"] as? String)
                let connection = ServerConnection(name: "Direction lab", url: try #require(endpoint.url?.absoluteString),
                    type: service == "Komga" ? .komga : .booklore,
                    username: service == "Komga" ? shared["Email"]?.first : shared["Username"]?.first,
                    password: shared["Password"]?.first)
                let provider: any LibraryProvider & ComicReadingDirectionProvider
                let leftID: String
                let rightID: String
                if service == "Komga" {
                    provider = KomgaProvider(connection: connection, profileSession: session)
                    leftID = "0RF1WT6ZXMH2X"
                    rightID = "0R9AMY8ASMQH7"
                } else {
                    provider = BookloreProvider(connection: connection, profileSession: session)
                    leftID = "30273"
                    rightID = "30274"
                }
                #expect(try await provider.validateConnection())
                for (id, expected) in [(leftID, ComicReadingDirection.leftToRight), (rightID, .rightToLeft)] {
                    let book = Book(id: id, title: "Direction fixture", source: service == "Komga" ? .komga : .booklore,
                        mediaType: .ebook, ebookFormat: "cbz", providerId: connection.id, libraryId: "comics")
                    #expect(try await provider.fetchComicReadingDirection(for: book) == expected)
                }
                await provider.retire()
                print("LAB \(service) left-to-right and right-to-left comic metadata passed")
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
