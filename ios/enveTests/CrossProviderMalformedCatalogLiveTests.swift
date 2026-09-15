import Foundation
import Testing

@testable import enve

@MainActor
struct CrossProviderMalformedCatalogLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_CATALOG_MALFORMED_FIXTURE_URL"] != nil))
    func eachProviderImportsValidNeighborsAndRejectsOnlyBrokenItem() async throws {
        let endpoint = try #require(ProcessInfo.processInfo.environment["ENVE_CATALOG_MALFORMED_FIXTURE_URL"])
        let cases: [(ProviderType, String, [String])] = [
            (.jellyfin, "jellyfin", ["valid-1", "valid-2"]),
            (.emby, "emby", ["valid-1", "valid-2"]),
            (.komga, "komga", ["valid-1", "valid-2"]),
            (.kavita, "kavita", ["1", "2"]),
            (.plex, "plex", ["valid-1", "valid-2"]),
            (.storyteller, "storyteller", ["valid-1", "valid-2"]),
            (.silo, "silo", ["valid-1", "valid-2"]),
        ]

        for (type, path, expectedBookIds) in cases {
            RejectedContentStore.shared.clear()
            let connection = ServerConnection(
                name: "Malformed \(path) fixture",
                url: "\(endpoint)/\(path)",
                type: type,
                token: "fixture-token",
                userId: "fixture-user"
            )
            let provider: any IncrementalCatalogProvider = switch type {
            case .jellyfin: JellyfinProvider(connection: connection)
            case .emby: EmbyProvider(connection: connection)
            case .komga: KomgaProvider(connection: connection)
            case .kavita: KavitaProvider(connection: connection)
            case .storyteller: StorytellerProvider(connection: connection)
            case .silo: SiloProvider(connection: connection)
            default: PlexProvider(connection: connection)
            }

            let source = try await provider.makeCatalogBatchSource(
                libraryId: "1",
                resumeAfter: nil,
                expectedSnapshotIdentifier: nil
            )
            let batch = try #require(try await source.next())

            #expect(batch.books.map(\.id).sorted() == expectedBookIds)
            #expect(!batch.completesSnapshot)
            #expect(batch.resumeToken == nil)
            #expect(try await source.next() == nil)
            #expect(RejectedContentStore.shared.entries.count == 1)
            #expect(RejectedContentStore.shared.entries.first?.itemIdentifier == "broken-1")
            if type == .silo {
                for key in ["silo_profile_id_", "silo_profile_name_", "silo_profile_user_id_"] {
                    UserDefaults.standard.removeObject(forKey: key + connection.id.uuidString)
                }
            }
        }

        RejectedContentStore.shared.clear()
    }
}
