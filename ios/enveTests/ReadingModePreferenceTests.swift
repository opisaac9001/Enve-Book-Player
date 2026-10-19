import Foundation
import Testing

@testable import enve

@MainActor
struct ReadingModePreferenceTests {
    @Test func queuedLibraryReloadKeepsItsProfileAlive() async throws {
        var fixture: OfflineAvailabilityFixture? = try OfflineAvailabilityFixture()
        let root = try #require(fixture?.root)
        let defaults = try #require(fixture?.defaults)
        let suite = try #require(fixture?.suite)
        let model = LibraryModel(profileSession: fixture?.session)
        weak let session = fixture?.session
        model.select(LibraryMediaFilter.comics)
        fixture = nil

        let retainedSession = try #require(session)
        await retainedSession.retire()
        #expect(!model.hasLoaded)
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    @Test func switchingReadingOffPreservesTheSelectedShelf() async throws {
        let fixture = try OfflineAvailabilityFixture()
        fixture.defaults.set("ebooks", forKey: "imagine.library.media")
        fixture.defaults.set("reading", forKey: "imagine.library.status")
        fixture.defaults.set("authors", forKey: LibraryBrowsePreferences.facetKey)
        let model = LibraryModel(profileSession: fixture.session)
        var preferences = fixture.session.preferences.loadPreferences()
        preferences.readingEnabled = false
        fixture.session.preferences.savePreferences(preferences)

        #expect(model.media == .all)
        #expect(model.status == .listening)
        #expect(model.availableMediaFilters.contains(.all))
        #expect(!model.availableMediaFilters.contains(.ebooks))
        #expect(fixture.defaults.string(forKey: "imagine.library.media") == "ebooks")
        #expect(fixture.defaults.string(forKey: "imagine.library.status") == "reading")

        preferences.readingEnabled = true
        fixture.session.preferences.savePreferences(preferences)
        #expect(model.media == .ebooks)
        #expect(model.status == .reading)

        let comics = LibrarySourceFilter.connection(fixture.providerID)
        fixture.defaults.set("comics", forKey: "imagine.library.source.media.\(comics.rawValue)")
        LibraryBrowsePreferences.save(facet: .series, media: .comics, source: comics, defaults: fixture.defaults)
        preferences.readingEnabled = false
        fixture.session.preferences.savePreferences(preferences)
        model.select(comics)
        await model.reload()
        preferences.readingEnabled = true
        fixture.session.preferences.savePreferences(preferences)
        await model.reload()
        #expect(model.media == .comics)
        #expect(model.facet == .series)
        await fixture.close()
    }

    @Test func allAudioIncludesPodcastsAndNarratedEbooks() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let audio = Book(id: "audio", title: "Audio", providerId: fixture.providerID)
        let ebook = Book(id: "ebook", title: "Ebook", mediaType: .ebook, providerId: fixture.providerID)
        let podcast = Book(id: "podcast", title: "Podcast", mediaType: .podcast, providerId: fixture.providerID)
        let narrated = Book(id: "narrated", title: "Narrated", mediaType: .ebook,
                            epub3Features: EPUB3Features(hasMediaOverlay: true), providerId: fixture.providerID)
        await fixture.session.bookStore.upsertBooks([audio, ebook, podcast, narrated])
        var preferences = fixture.session.preferences.loadPreferences()
        preferences.readingEnabled = false
        fixture.session.preferences.savePreferences(preferences)
        let model = LibraryModel(profileSession: fixture.session)
        await model.bootstrap()
        #expect(Set(model.displayBooks.map(\.id)) == ["audio", "podcast", "narrated"])
        preferences.readingEnabled = true
        fixture.session.preferences.savePreferences(preferences)
        await model.reload()
        #expect(Set(model.displayBooks.map(\.id)) == ["audio", "ebook", "podcast", "narrated"])
        await fixture.close()
    }

    @Test func existingPreferencesKeepReadingEnabled() throws {
        let preferences = try JSONDecoder().decode(UserPreferences.self, from: Data(#"{"playbackSpeed":1.5}"#.utf8))
        #expect(preferences.readingEnabled)
        #expect(preferences.playbackSpeed == 1.5)
    }

    @Test func audiobooksOnlyPersistsWithinItsProfile() throws {
        let firstName = "enve.tests.reading-mode.\(UUID().uuidString)"
        let secondName = "enve.tests.reading-mode.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        let store = LibraryDisplayPreferencesStore(defaults: first)
        var preferences = store.loadPreferences()
        preferences.readingEnabled = false
        preferences.playbackSpeed = 1.75
        store.savePreferences(preferences)

        #expect(!store.readingEnabled)
        #expect(!LibraryDisplayPreferencesStore(defaults: first).readingEnabled)
        #expect(LibraryDisplayPreferencesStore(defaults: second).readingEnabled)
        #expect(store.loadPreferences().playbackSpeed == 1.75)

        let ebook = Book(id: "ebook", title: "Ebook", mediaType: .ebook, providerId: UUID(), libraryId: "test")
        let audiobook = Book(id: "audio", title: "Audio", providerId: UUID(), libraryId: "test")
        #expect(!store.includesLibraryBook(ebook))
        #expect(store.includesLibraryBook(audiobook))
        var narrated = ebook
        narrated.epub3Features = EPUB3Features(hasMediaOverlay: true)
        #expect(store.includesLibraryBook(narrated))

        preferences.readingEnabled = true
        store.savePreferences(preferences)
        #expect(store.readingEnabled)
        #expect(store.includesLibraryBook(ebook))
    }
}
