import Foundation
import Testing

@testable import enve

@MainActor
struct LibraryFilterStateTests {
    @Test func sourceAndLibraryScopesDoNotCountAsFilters() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let scopes: [LibrarySourceFilter] = [
            .all, .device, .connection(fixture.providerID),
            .library(providerId: fixture.providerID, libraryId: "books"),
        ]
        for scope in scopes {
            fixture.defaults.set(scope.rawValue, forKey: "imagine.library.source")
            let model = LibraryModel(profileSession: fixture.session)

            #expect(model.sourceFilter == scope)
            #expect(model.activeFilterCount == 0)
            #expect(!model.isNarrowed)
        }
        await fixture.close()
    }

    @Test func clearingContentFiltersPreservesTheLibraryAndStaysClearedAfterReopening() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let scope = LibrarySourceFilter.library(providerId: fixture.providerID, libraryId: "books")
        fixture.defaults.set(scope.rawValue, forKey: "imagine.library.source")
        let model = LibraryModel(profileSession: fixture.session)
        model.select(LibraryStatusFilter.finished)
        model.select(LibraryMediaFilter.audiobooks)
        model.selectMinimumRating(4)
        model.selectSeriesFilter(.inSeries)
        model.toggleGenre("Fantasy")
        model.toggleGenre("Adventure")
        model.toggleLanguage("English")
        #expect(model.activeFilterCount == 7)
        #expect(model.isNarrowed)

        model.clearFilters()

        #expect(model.sourceFilter == scope)
        #expect(model.status == .all)
        #expect(model.media == .all)
        #expect(model.advancedFilters == .empty)
        #expect(!model.isNarrowed)
        let reopened = LibraryModel(profileSession: fixture.session)
        #expect(reopened.sourceFilter == scope)
        #expect(reopened.activeFilterCount == 0)
        #expect(reopened.media == .all)
        await fixture.close()
    }

    @Test func removingTheLastSortKeepsDefaultOrderingWithoutRestoringTheRule() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let model = LibraryModel(profileSession: fixture.session)

        model.removeSort(.recent)

        #expect(model.sortDescriptors.isEmpty)
        #expect(model.usesDefaultSorting)
        #expect(model.sort == .recent)
        #expect(model.sortDirection == .descending)
        let reopened = LibraryModel(profileSession: fixture.session)
        #expect(reopened.sortDescriptors.isEmpty)
        #expect(reopened.usesDefaultSorting)

        model.addSort(.title)
        #expect(model.sortDescriptors == [.init(field: .title, direction: .ascending)])
        model.removeSort(.title)
        #expect(model.sortDescriptors.isEmpty)
        #expect(model.sort == .recent)
        #expect(model.sortDirection == .descending)
        await fixture.close()
    }

    @Test func removingASortKeepsTheOtherPrioritiesAndDirections() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let model = LibraryModel(profileSession: fixture.session)
        model.addSort(.title)
        model.addSort(.author)
        model.select(.descending, for: .author)
        model.moveSortUp(.author)

        model.removeSort(.recent)

        #expect(model.sortDescriptors == [
            .init(field: .author, direction: .descending),
            .init(field: .title, direction: .ascending),
        ])
        #expect(model.sort == .author)
        model.clearSorting()
        #expect(model.sortDescriptors.isEmpty)
        #expect(LibraryModel(profileSession: fixture.session).sortDescriptors.isEmpty)
        await fixture.close()
    }
}
