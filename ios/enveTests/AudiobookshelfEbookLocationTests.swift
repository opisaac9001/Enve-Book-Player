import Foundation
import Testing

@testable import enve

struct AudiobookshelfEbookLocationTests {
    private let clips = [
        AudioOverlayClip(fragmentId: "s1", textHref: "OEBPS/text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 0, clipEnd: 10),
        AudioOverlayClip(fragmentId: "s2", textHref: "OEBPS/text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 10, clipEnd: 20),
        AudioOverlayClip(fragmentId: "s3", textHref: "OEBPS/text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 20, clipEnd: 30),
        AudioOverlayClip(fragmentId: "s4", textHref: "OEBPS/text/ch1.xhtml", audioSrc: "a.mp3", clipBegin: 30, clipEnd: 40),
    ]

    private var timeline: MediaOverlayTimeline {
        MediaOverlayTimeline(clips: clips, clipTextProgressions: [0.1, 0.2, 0.3, 0.4])
    }

    private func sentence(_ id: String) -> String {
        #"{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["\#(id)"],"totalProgression":0.2}}"#
    }

    private func fragment(of locator: String?) -> String? {
        let locations = locator.flatMap(EpubCFI.jsonObject)?["locations"] as? [String: Any]
        return (locations?["fragments"] as? [String])?.first
    }

    @Test func serverLocationDecodesCFIsAndLegacyReadiumJSON() {
        let legacy = sentence("s1")

        #expect(AudiobookshelfProvider.ebookLocation(fromServerValue: legacy) == .readiumLocatorJSON(legacy))
        #expect(
            AudiobookshelfProvider.ebookLocation(fromServerValue: " epubcfi(/6/18!/4/2[ch1]/8/2[s1]) ")
                == .cfi("epubcfi(/6/18!/4/2[ch1]/8/2[s1])")
        )
        #expect(AudiobookshelfProvider.ebookLocation(fromServerValue: "page=12") == nil)
        #expect(AudiobookshelfProvider.ebookLocation(fromServerValue: "{not json") == nil)
        #expect(AudiobookshelfProvider.ebookLocation(fromServerValue: "") == nil)
        #expect(AudiobookshelfProvider.ebookLocation(fromServerValue: nil) == nil)
    }

    @Test func aPositionThatFailedTheRoundTripOmitsEbookLocation() {
        let omitted = AudiobookshelfProvider.ebookProgressBody(
            progress: 0.42, ebookLocation: nil, itemHasAudio: false, audioPosition: nil
        )
        let sent = AudiobookshelfProvider.ebookProgressBody(
            progress: 0.42, ebookLocation: "epubcfi(/6/4!/4/2[s1])", itemHasAudio: false, audioPosition: nil
        )

        #expect(omitted.keys.sorted() == ["ebookProgress", "isFinished"])
        #expect(omitted["ebookProgress"] as? Double == 0.42)
        #expect(sent["ebookLocation"] as? String == "epubcfi(/6/4!/4/2[s1])")
    }

    @Test func ebookPatchLeavesTheAudioSideAlone() {
        let reading = AudiobookshelfProvider.ebookProgressBody(
            progress: 0.42, ebookLocation: "epubcfi(/6/4!/4/2)", itemHasAudio: true, audioPosition: nil
        )
        let finishing = AudiobookshelfProvider.ebookProgressBody(
            progress: 1, ebookLocation: nil, itemHasAudio: true, audioPosition: nil
        )
        let narrating = AudiobookshelfProvider.ebookProgressBody(
            progress: 0.42, ebookLocation: "epubcfi(/6/4!/4/2)", itemHasAudio: true, audioPosition: (600, 2400)
        )

        #expect(reading.keys.sorted() == ["ebookLocation", "ebookProgress"])
        #expect(finishing["isFinished"] as? Bool == true)
        #expect(narrating["currentTime"] as? Double == 600)
        #expect(narrating["duration"] as? Double == 2400)
        #expect(narrating["progress"] as? Double == 0.25)
        #expect(narrating["isFinished"] == nil)
    }

    @Test func aRecordCreatedByAnAudioPushHasNoEbookPosition() {
        func fraction(_ ebookProgress: Double?, _ location: String?, progress: Double?, audio: Bool) -> Double? {
            ABSMediaProgress.ebookFraction(ebookProgress: ebookProgress, ebookLocation: location, progress: progress, itemHasAudio: audio)
        }

        #expect(fraction(0, nil, progress: 0.25, audio: true) == nil)
        #expect(fraction(0, " ", progress: 1, audio: true) == nil)
        #expect(fraction(nil, nil, progress: 0.25, audio: true) == nil)
        #expect(fraction(0, "epubcfi(/6/2!/4/2)", progress: 0.25, audio: true) == 0)
        #expect(fraction(0.4, nil, progress: 0.25, audio: true) == 0.4)
        #expect(fraction(0, nil, progress: 0, audio: false) == 0)
        #expect(fraction(nil, nil, progress: 1, audio: false) == 1)
    }

    @Test func catalogProgressLeavesADualItemsEbookAloneWhenOnlyAudioWasSaved() {
        let audioOnly = UserMediaProgress(
            id: "record",
            libraryItemId: "dual",
            providerId: UUID(),
            episodeId: nil,
            currentTime: 600,
            progress: 0.25,
            isFinished: false,
            duration: 2_400,
            lastUpdate: Date(timeIntervalSince1970: 5_000),
            ebookProgress: nil
        )
        let localDate = Date(timeIntervalSince1970: 1_000)
        var ebook = Book(
            id: "dual_ebook",
            title: "Dual",
            partKey: "dual",
            mediaType: .ebook,
            epubLocator: sentence("s2"),
            ebookProgress: 1,
            lastUpdate: localDate,
            hasAlternateFormat: true
        )
        var audiobook = Book(id: "dual", title: "Dual", partKey: "dual", lastUpdate: localDate, hasAlternateFormat: true)

        AudiobookshelfProvider.applyServerProgress(audioOnly, to: &ebook)
        AudiobookshelfProvider.applyServerProgress(audioOnly, to: &audiobook)

        #expect(ebook.ebookProgress == 1)
        #expect(ebook.epubLocator == sentence("s2"))
        #expect(ebook.lastUpdate == localDate)
        #expect(audiobook.currentTime == 600)
        #expect(audiobook.lastUpdate == audioOnly.lastUpdate)

        let ebookOnly = UserMediaProgress(
            id: "record",
            libraryItemId: "dual",
            providerId: UUID(),
            episodeId: nil,
            currentTime: 0,
            progress: 0,
            isFinished: false,
            duration: 0,
            lastUpdate: Date(timeIntervalSince1970: 9_000),
            ebookProgress: 0.4
        )
        AudiobookshelfProvider.applyServerProgress(ebookOnly, to: &audiobook)
        AudiobookshelfProvider.applyServerProgress(ebookOnly, to: &ebook)

        #expect(audiobook.currentTime == 600)
        #expect(audiobook.lastUpdate == audioOnly.lastUpdate)
        #expect(ebook.ebookProgress == 0.4)
    }

    @Test func itemAudioDurationIsReadFromTheExpandedItem() throws {
        let baseURL = try #require(URL(string: "http://abs.example.invalid:13378"))
        let url = try #require(AudiobookshelfProvider.expandedItemURL(baseURL: baseURL, itemId: "item-1"))
        #expect(url.path == "/api/items/item-1")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "expanded", value: "1")])
    }

    @Test func narrationMatchesTheItemAudioOnlyWithinOnePercent() {
        #expect(LinkedBookProgressCoordinator.narrationMatchesAudio(narrationDuration: 36_000, audioDuration: 36_300))
        #expect(LinkedBookProgressCoordinator.narrationMatchesAudio(narrationDuration: 36_300, audioDuration: 36_000))
        #expect(!LinkedBookProgressCoordinator.narrationMatchesAudio(narrationDuration: 36_000, audioDuration: 36_400))
        #expect(!LinkedBookProgressCoordinator.narrationMatchesAudio(narrationDuration: 2_336, audioDuration: 28_800))
        #expect(!LinkedBookProgressCoordinator.narrationMatchesAudio(narrationDuration: 0, audioDuration: 0))
    }

    @Test func narrationTimeIsPushedOnlyWhileItSitsInTheNarratedSentence() throws {
        let clip = timeline.clipTimings[2]
        let live = try #require(
            AudiobookshelfProvider.itemAudioPosition(
                narrationTime: 25, clip: clip, overlayDuration: 40, itemAudioDuration: 40.2
            )
        )

        #expect(abs(live.currentTime - 25.125) < 1e-9)
        #expect(live.duration == 40.2)
        #expect(
            AudiobookshelfProvider.itemAudioPosition(narrationTime: 5, clip: clip, overlayDuration: 40, itemAudioDuration: 40.2)
                == nil
        )
        #expect(
            AudiobookshelfProvider.itemAudioPosition(narrationTime: 25, clip: clip, overlayDuration: 40, itemAudioDuration: 60)
                == nil
        )
    }

    @Test func itemAudioBecomesTheNarratedSentence() throws {
        let moved = try #require(
            AudiobookshelfProvider.narratedLocator(itemAudioTime: 35.175, itemAudioDuration: 40.2, timeline: timeline)
        )

        #expect(fragment(of: moved.locator) == "s4")
        #expect(moved.progress == 0.4)
    }

    @Test func serverAudioIsNewerOnlyWhenItLeftTheTimeEnveLastSynced() throws {
        let suiteName = "NarratedAudioPositionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = NarratedAudioPositionStore.itemKey(connectionId: UUID(), itemId: "item-1")
        let store = NarratedAudioPositionStore(defaults: defaults)

        #expect(store.isServerAudioNewer(600, forItem: key))

        store.recordPush(audioTime: 600, forItem: key)
        #expect(!store.isServerAudioNewer(600, forItem: key))
        #expect(store.isServerAudioNewer(1200, forItem: key))

        store.noteServerAudioTime(1200, forItem: key)
        store.recordPush(audioTime: nil, forItem: key)
        #expect(!store.isServerAudioNewer(1200, forItem: key))
        #expect(!NarratedAudioPositionStore(defaults: defaults).isServerAudioNewer(1200, forItem: key))
    }

    @Test func anEbookOnlyPushBeforeAnyServerReadRecordsNothing() throws {
        let suiteName = "NarratedAudioPositionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = NarratedAudioPositionStore.itemKey(connectionId: UUID(), itemId: "item-1")
        let store = NarratedAudioPositionStore(defaults: defaults)

        store.recordPush(audioTime: nil, forItem: key)

        #expect(store.isServerAudioNewer(0, forItem: key))
    }

    @Test func onlyNarrationRecordsAnAudioTimeForAnEbookPush() throws {
        let suiteName = "NarratedAudioPositionStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = NarratedAudioPositionStore(defaults: defaults)
        let ebook = Book(id: "d42b4c1e_ebook", title: "Midnight Dual", source: .audiobookshelf, mediaType: .ebook)

        #expect(store.narrationAudioTime(for: ebook) == nil)

        store.recordNarration(audioTime: 1203.4, for: ebook)
        #expect(store.narrationAudioTime(for: ebook) == 1203.4)
    }

    @Test func aDualItemsEbookSideResolvesToTheItemId() {
        #expect(AudiobookshelfProvider.itemId(forBookId: "d42b4c1e_ebook") == "d42b4c1e")
        #expect(AudiobookshelfProvider.itemId(forBookId: "d42b4c1e") == "d42b4c1e")
    }

    @Test func progressPushesAddressTheLibraryItemNeverTheEbookSide() {
        let ebookSide = Book(id: "d42b4c1e_ebook", title: "Dual", providerId: UUID(), libraryId: "tests")
        var episode = Book(id: "episode-7", title: "Episode", providerId: UUID(), libraryId: "tests")
        episode.isPodcastEpisode = true
        episode.podcastLibraryItemId = "show-1"

        #expect(AudiobookshelfProvider.libraryItemId(for: ebookSide) == "d42b4c1e")
        #expect(AudiobookshelfProvider.libraryItemId(for: episode) == "show-1")
    }

    @Test func listenAlongStartsAtTheReadSentenceOnlyForTheSameRecording() throws {
        let reading = sentence("s3")

        let time = try #require(EbookAudiobookLinker.narratedAudioTime(locatorJSON: reading, timeline: timeline, audioDuration: 40.2))
        #expect(abs(time - 20.1) < 1e-9)
        #expect(EbookAudiobookLinker.narratedAudioTime(locatorJSON: reading, timeline: timeline, audioDuration: 60) == nil)
    }
}
