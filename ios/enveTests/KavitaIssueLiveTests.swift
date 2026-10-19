import Foundation
import Testing

@testable import enve

@MainActor
struct KavitaIssueLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_KAVITA_ISSUES_LIVE"] != nil))
    func downloadsAndProgressStayWithTheSelectedIssue() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_KAVITA_ISSUES_LIVE"])
        let configuration = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let tables = try #require(configuration["tables"] as? [String: [String: [String]]])
        let shared = try #require(configuration["shared"] as? [String: [String]])
        let row = try #require(tables["Service endpoints"]?["Kavita"]?.joined(separator: " "))
        let range = try #require(row.range(of: #"https?://[^`\s|)]+"#, options: .regularExpression))
        var endpoint = try #require(URLComponents(string: String(row[range])))
        endpoint.host = try #require(configuration["remoteHost"] as? String)
        let address = try #require(endpoint.url?.absoluteString)
        let profile = FamilyProfile(id: UUID().uuidString, name: "Issue verification", role: .adult)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(profile.id)
        let domain = "KavitaIssueLive.\(profile.id)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"))
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let provider = KavitaProvider(connection: ServerConnection(name: "Issue lab", url: address, type: .kavita,
            username: shared["Username"]?.first, password: shared["Password"]?.first), profileSession: session)
        do {
            #expect(try await provider.validateConnection())
            let libraries = try await provider.fetchLibraries()
            let comics = try #require(libraries.first { $0.name == "Enve Test Comics" })
            let catalog = try await provider.fetchBooks(libraryId: comics.id)
            let issues = catalog.filter { $0.seriesInfo?.name == "Enve CBZ Regression" }
            #expect(issues.count == 2)
            let first = try #require(issues.first { $0.seriesInfo?.sequence == "3" })
            let second = try #require(issues.first { $0.seriesInfo?.sequence == "4" })
            #expect(first.id != second.id)
            let detail = try await provider.fetchFullBookDetails(bookId: second.id, libraryId: comics.id)
            #expect(detail.id == second.id)
            let firstFile = try await provider.downloadEbook(for: first)
            let secondFile = try await provider.downloadEbook(for: second)
            #expect(firstFile != secondFile)
            let firstBytes = try Data(contentsOf: firstFile)
            let secondBytes = try Data(contentsOf: secondFile)
            #expect(!firstBytes.isEmpty && !secondBytes.isEmpty)
            #expect(firstBytes != secondBytes)
            let cached = try await provider.downloadEbook(for: second)
            #expect(cached == secondFile)
            let beforeFirst = try #require(await provider.fetchEbookProgress(for: first))
            let beforeSecond = try #require(await provider.fetchEbookProgress(for: second))
            do {
                try await provider.updateEbookProgress(for: second, progress: 0.5, epubLocator: nil)
                let afterFirst = try #require(await provider.fetchEbookProgress(for: first))
                let afterSecond = try #require(await provider.fetchEbookProgress(for: second))
                #expect(afterFirst.progress == beforeFirst.progress)
                #expect(afterSecond.progress == 0.5)
            } catch {
                try await provider.updateEbookProgress(for: second, progress: beforeSecond.progress, epubLocator: nil)
                throw error
            }
            try await provider.updateEbookProgress(for: second, progress: beforeSecond.progress, epubLocator: nil)
            let restored = try #require(await provider.fetchEbookProgress(for: second))
            #expect(restored.progress == beforeSecond.progress)
            print("LAB Kavita independent issues, distinct cached downloads, and chapter-specific progress passed")
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
