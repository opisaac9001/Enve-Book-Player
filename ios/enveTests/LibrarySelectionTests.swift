import Foundation
import Testing

@testable import enve

@MainActor
struct LibrarySelectionTests {
    @Test func aNewLibraryJoinsAnExplicitSelection() {
        var connection = Self.connection(selected: ["a"], known: ["a", "b"])

        connection.includeNewLibraries(fetchedIds: ["a", "b", "c"], previouslySeenIds: [])

        #expect(connection.selectedLibraryIds == ["a", "c"])
        #expect(connection.knownLibraryIds == ["a", "b", "c"])
    }

    @Test func allLibrariesStayUnrestrictedAndAreRecordedAsKnown() {
        var connection = Self.connection(selected: nil, known: nil)

        connection.includeNewLibraries(fetchedIds: ["a", "b"], previouslySeenIds: ["a"])

        #expect(connection.selectedLibraryIds == nil)
        #expect(connection.knownLibraryIds == ["a", "b"])
    }

    @Test func migrationTreatsCachedUnselectedLibrariesAsExcluded() {
        var connection = Self.connection(selected: ["a"], known: nil)

        connection.includeNewLibraries(fetchedIds: ["a", "b", "c"], previouslySeenIds: ["a", "b"])

        #expect(connection.selectedLibraryIds == ["a", "c"])
        #expect(connection.knownLibraryIds == ["a", "b", "c"])
    }

    @Test func migrationWithoutACachedCatalogKeepsTheSelection() {
        var connection = Self.connection(selected: ["a"], known: nil)

        connection.includeNewLibraries(fetchedIds: ["a", "b"], previouslySeenIds: [])

        #expect(connection.selectedLibraryIds == ["a"])
        #expect(connection.knownLibraryIds == ["a", "b"])
    }

    @Test func anEmptyLibraryListingChangesNothing() {
        var connection = Self.connection(selected: ["a"], known: ["a", "b"])

        connection.includeNewLibraries(fetchedIds: [], previouslySeenIds: ["a", "b"])

        #expect(connection.selectedLibraryIds == ["a"])
        #expect(connection.knownLibraryIds == ["a", "b"])
    }

    @Test func aLibraryMissingFromOneListingIsNotTreatedAsNewLater() {
        var connection = Self.connection(selected: ["a"], known: ["a", "b"])

        connection.includeNewLibraries(fetchedIds: ["a"], previouslySeenIds: [])
        connection.includeNewLibraries(fetchedIds: ["a", "b"], previouslySeenIds: [])

        #expect(connection.selectedLibraryIds == ["a"])
    }

    @Test func knownLibrariesSurviveAPersistenceRoundTrip() throws {
        let connection = Self.connection(selected: ["a"], known: ["a", "b"])

        let decoded = try JSONDecoder().decode(ServerConnection.self, from: JSONEncoder().encode(connection))

        #expect(decoded.knownLibraryIds == ["a", "b"])
    }

    private static func connection(selected: Set<String>?, known: Set<String>?) -> ServerConnection {
        var connection = ServerConnection(
            name: "Grimmory",
            url: "http://grimmory.example.invalid",
            type: .booklore,
            selectedLibraryIds: selected
        )
        connection.knownLibraryIds = known
        return connection
    }
}
