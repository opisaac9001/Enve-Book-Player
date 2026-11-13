import Foundation
import Testing

@testable import enve

@MainActor
struct RediscoverHomeSectionTests {
    @Test func defaultOrderPlacesRediscoverAfterRecentlyAdded() {
        #expect(
            UserPreferences().normalizedHomeSectionOrder == [
                .continueReading, .continueListening, .recentlyAdded, .rediscover, .downloaded, .doorways,
            ]
        )
    }

    @Test func savedOrderFromBeforeRediscoverKeepsItsArrangement() throws {
        let preferences = try decode(
            #"{"homeSectionOrder":["doorways","recentlyAdded","continueListening","continueReading","downloaded"],"hiddenHomeSections":["downloaded"]}"#
        )

        #expect(
            preferences.normalizedHomeSectionOrder == [
                .doorways, .recentlyAdded, .rediscover, .continueListening, .continueReading, .downloaded,
            ]
        )
        #expect(preferences.visibleHomeSections.contains(.rediscover))
        #expect(!preferences.visibleHomeSections.contains(.downloaded))
    }

    @Test func unknownShelvesAreIgnoredWithoutDroppingKnownChoices() throws {
        let preferences = try decode(
            #"{"homeSectionOrder":["rediscover","futureShelf","doorways"],"hiddenHomeSections":["futureShelf","recentlyAdded"],"readingEnabled":false}"#
        )

        #expect(preferences.homeSectionOrder == [.rediscover, .doorways])
        #expect(preferences.hiddenHomeSections == [.recentlyAdded])
        #expect(preferences.readingEnabled == false)
        #expect(preferences.normalizedHomeSectionOrder.first == .continueReading)
        #expect(Set(preferences.normalizedHomeSectionOrder) == Set(UserPreferences.HomeSection.allCases))
    }

    @Test func hiddenRediscoverSurvivesARoundTrip() throws {
        var preferences = UserPreferences()
        preferences.homeSectionOrder = [.rediscover, .continueListening]
        preferences.hiddenHomeSections = [.rediscover]

        let decoded = try JSONDecoder().decode(UserPreferences.self, from: JSONEncoder().encode(preferences))

        #expect(decoded.homeSectionOrder == [.rediscover, .continueListening])
        #expect(!decoded.visibleHomeSections.contains(.rediscover))
    }

    private func decode(_ json: String) throws -> UserPreferences {
        try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
    }
}
