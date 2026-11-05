import Foundation
import StoryAlignCore
import Testing
@testable import enve

@MainActor
struct PassageAlignmentStoreTests {
    private let identity = PassageMediaIdentity(ebookStableId: "ebook", audiobookStableId: "audio", readingRevision: "epub-a", trackRevisions: ["track-0", "track-1"])

    private func mapping(_ sentence: Int, track: Int = 0, start: Double, end: Double, chapter: Int = 0, text: String? = nil) -> PassageMapping {
        PassageMapping(
            key: PassageSentenceKey(chapter: chapter, sentence: sentence), href: "OEBPS/c\(chapter).xhtml",
            text: text ?? "Sentence \(chapter)-\(sentence).", before: "", after: "",
            chapterProgression: Double(sentence) / 100, totalProgression: Double(sentence) / 1000,
            trackIndex: track, start: start, end: end, granularity: .sentence, engine: "engine", score: -0.2
        )
    }

    private func update(_ mappings: [PassageMapping], track: Int = 0, window: Int = 0, owned: Range<Double> = 0..<37.75) -> PassageWindowUpdate {
        PassageWindowUpdate(trackIndex: track, windowIndex: window, ownedEnds: owned, engine: "engine", mappings: mappings)
    }

    @Test func acceptedWindowResolvesSentencesPausesGapsAndUnpreparedAudio() {
        var set = PassageMappingSet(identity: identity)
        set.merge(update([mapping(0, start: 1, end: 5), mapping(1, start: 5.8, end: 10), mapping(2, start: 21, end: 26), mapping(3, start: 26.5, end: 30)]))
        #expect(set.resolve(trackIndex: 0, time: 3).mapping?.key.sentence == 0)
        guard case .pause(let previous, let next) = set.resolve(trackIndex: 0, time: 5.4) else {
            Issue.record("Expected a pause between adjacent sentences")
            return
        }
        #expect(previous.key.sentence == 0 && next.key.sentence == 1)
        #expect(set.resolve(trackIndex: 0, time: 5.4).handoffMapping?.key.sentence == 1)
        // A ten-second unmatched stretch inside coverage is a gap, never the neighboring sentence.
        #expect(set.resolve(trackIndex: 0, time: 15) == .gap)
        #expect(set.resolve(trackIndex: 0, time: 15).handoffMapping == nil)
        #expect(set.resolve(trackIndex: 0, time: 50) == .unprepared)
        #expect(set.resolve(trackIndex: 1, time: 3) == .unprepared)
    }

    @Test func attemptedButRejectedWindowEstablishesNoCoverage() {
        var set = PassageMappingSet(identity: identity)
        set.merge(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9)]))
        #expect(set.hasAttempted(trackIndex: 0, windowIndex: 0, engine: "engine"))
        #expect(set.mappings.isEmpty)
        #expect(set.coverage.isEmpty)
        #expect(set.resolve(trackIndex: 0, time: 3) == .unprepared)
    }

    @Test func conflictingMappingsDoNotReplaceIndependentlyAcceptedNeighbors() {
        var set = PassageMappingSet(identity: identity)
        set.merge(update([mapping(10, start: 1, end: 5), mapping(11, start: 6, end: 9), mapping(12, start: 10, end: 14)]))
        // A later window claims earlier sentences after later audio: the book order would run backwards.
        set.merge(update([mapping(3, start: 40, end: 44), mapping(4, start: 45, end: 49), mapping(5, start: 50, end: 54), mapping(13, start: 55, end: 59)], window: 1, owned: 37.75..<67.75))
        #expect(set.mappings.map(\.key.sentence) == [10, 11, 12])
        #expect(set.windows.first { $0.windowIndex == 1 }?.accepted == false)
        #expect(set.resolve(trackIndex: 0, time: 42) == .unprepared)
    }

    @Test func reanalyzingAWindowReplacesOnlyItsOwnedSentences() {
        var set = PassageMappingSet(identity: identity)
        set.merge(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 20), mapping(3, start: 30, end: 39)]))
        // Sentence 3 ends after the window's seam, so the next window finalizes it.
        #expect(set.mappings.map(\.key.sentence) == [0, 1, 2])
        set.merge(update([mapping(3, start: 30, end: 39), mapping(4, start: 40, end: 45), mapping(5, start: 46, end: 50)], window: 1, owned: 37.75..<67.75))
        #expect(set.mappings.map(\.key.sentence) == [0, 1, 2, 3, 4, 5])
        #expect(set.resolve(trackIndex: 0, time: 35).mapping?.key.sentence == 3)
        set.merge(update([mapping(0, start: 1.2, end: 5.1), mapping(1, start: 6.1, end: 9.2), mapping(3, start: 10, end: 12)]))
        // Too few new sentences: the earlier accepted result stands.
        #expect(set.mappings.map(\.key.sentence) == [0, 1, 2, 3, 4, 5])
        #expect(set.mappings.first?.start == 1)
        set.merge(update([mapping(0, start: 1.2, end: 5.1), mapping(1, start: 6.1, end: 9.2), mapping(6, start: 0.2, end: 0.9).withKey(chapter: 0, sentence: -1)]))
        #expect(set.mappings.map(\.key.sentence) == [-1, 0, 1, 3, 4, 5])
        #expect(set.mappings[1].start == 1.2)
        #expect(set.resolve(trackIndex: 0, time: 15) == .gap)
    }

    @Test func replacedTrackInvalidatesOnlyItsTimingsAndReplacedEPUBInvalidatesAll() {
        var set = PassageMappingSet(identity: identity)
        set.merge(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]))
        set.merge(update([mapping(3, track: 1, start: 1, end: 5), mapping(4, track: 1, start: 6, end: 9), mapping(5, track: 1, start: 10, end: 14)], track: 1))
        // Both tracks share timestamps; resolution never crosses into the neighboring track.
        #expect(set.resolve(trackIndex: 0, time: 7).mapping?.key.sentence == 1)
        #expect(set.resolve(trackIndex: 1, time: 7).mapping?.key.sentence == 4)
        #expect(set.resolve(trackIndex: 0, time: 15) == .gap)
        #expect(set.resolve(trackIndex: 1, time: 0.5) == .gap)
        let replacedTrack = PassageMediaIdentity(ebookStableId: "ebook", audiobookStableId: "audio", readingRevision: "epub-a", trackRevisions: ["track-0", "track-1-new"])
        let rebased = set.rebased(to: replacedTrack)
        #expect(rebased?.mappings.map(\.trackIndex) == [0, 0, 0])
        #expect(rebased?.resolve(trackIndex: 1, time: 3) == .unprepared)
        let replacedEPUB = PassageMediaIdentity(ebookStableId: "ebook", audiobookStableId: "audio", readingRevision: "epub-b", trackRevisions: ["track-0", "track-1"])
        #expect(set.rebased(to: replacedEPUB) == nil)
    }

    @Test func textResolutionDistinguishesMatchedUnspokenAmbiguousAndUnprepared() {
        let sentences = [
            PassageSentence(key: .init(chapter: 0, sentence: 0), href: "OEBPS/c0.xhtml", text: "Chapter One", chapterProgression: 0, totalProgression: 0),
            PassageSentence(key: .init(chapter: 0, sentence: 1), href: "OEBPS/c0.xhtml", text: "The harbor was quiet before dawn.", chapterProgression: 0.1, totalProgression: 0.01),
            PassageSentence(key: .init(chapter: 0, sentence: 2), href: "OEBPS/c0.xhtml", text: "A heading nobody reads", chapterProgression: 0.2, totalProgression: 0.02),
            PassageSentence(key: .init(chapter: 0, sentence: 3), href: "OEBPS/c0.xhtml", text: "Gulls circled the masts.", chapterProgression: 0.3, totalProgression: 0.03),
            PassageSentence(key: .init(chapter: 0, sentence: 4), href: "OEBPS/c0.xhtml", text: "She waited.", chapterProgression: 0.4, totalProgression: 0.04),
            PassageSentence(key: .init(chapter: 0, sentence: 5), href: "OEBPS/c0.xhtml", text: "She waited.", chapterProgression: 0.9, totalProgression: 0.09),
            PassageSentence(key: .init(chapter: 0, sentence: 6), href: "OEBPS/c0.xhtml", text: "The tide turned slowly at noon.", chapterProgression: 0.95, totalProgression: 0.095),
        ]
        var set = PassageMappingSet(identity: identity)
        set.merge(update([
            mapping(1, start: 1, end: 4, text: sentences[1].text), mapping(3, start: 4.8, end: 7, text: sentences[3].text),
            mapping(4, start: 7.5, end: 8.5, text: sentences[4].text),
        ]))
        #expect(set.resolve(href: "/OEBPS/c0.xhtml#p3", quote: "The harbor was quiet before dawn", chapterProgression: nil, sentences: sentences).mappingKey == 1)
        #expect(set.resolve(href: "OEBPS/c0.xhtml", quote: "A heading nobody reads", chapterProgression: nil, sentences: sentences) == .notSpoken(sentences[2]))
        #expect(set.resolve(href: "OEBPS/c0.xhtml", quote: "She waited.", chapterProgression: nil, sentences: sentences) == .ambiguous)
        #expect(set.resolve(href: "OEBPS/c0.xhtml", quote: "She waited.", chapterProgression: 0.42, sentences: sentences).mappingKey == 4)
        #expect(set.resolve(href: "OEBPS/c0.xhtml", quote: "The tide turned slowly at noon.", chapterProgression: nil, sentences: sentences) == .unprepared(sentences[6]))
        #expect(set.resolve(href: "OEBPS/other.xhtml", quote: "The harbor was quiet before dawn", chapterProgression: nil, sentences: sentences) == .unprepared(nil))
    }

    @Test func locatorUsesOriginalHrefTextAndContext() throws {
        let value = PassageMapping(
            key: .init(chapter: 2, sentence: 7), href: "OEBPS/Text/c2.xhtml", text: "Café “déjà vu” — again.", before: "earlier.", after: "Later",
            chapterProgression: 0.25, totalProgression: 0.4, trackIndex: 0, start: 1, end: 2, granularity: .sentence, engine: "e", score: 0
        )
        let object = try #require(JSONSerialization.jsonObject(with: Data(value.locatorJSON.utf8)) as? [String: Any])
        #expect(object["href"] as? String == "OEBPS/Text/c2.xhtml")
        let text = try #require(object["text"] as? [String: String])
        #expect(text["highlight"] == "Café “déjà vu” — again.")
        #expect(text["before"] == "earlier.")
        #expect((object["locations"] as? [String: Double])?["totalProgression"] == 0.4)
    }

    @Test func committedMappingsSurviveRestartAndUnknownSchemaIsIgnored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PassageAlignmentStore(root: root)
        let saved = try await store.commit(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]), identity: identity)
        #expect(saved?.mappings.count == 3)
        await store.retire()

        let reopened = PassageAlignmentStore(root: root)
        let restored = await reopened.mappingSet(for: identity)
        #expect(restored == saved)
        #expect(restored?.resolve(trackIndex: 0, time: 7).mapping?.key.sentence == 1)

        let file = root.appendingPathComponent("pairs/\(PassageAlignmentStore.pairKey(ebookStableId: "ebook", audiobookStableId: "audio"))/mapping.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == nil)
        await reopened.retire()
    }

    @Test func pathLikeLocalStableIdentifiersStillPersist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = String(repeating: "Very Long Audiobook Folder Name ", count: 8)
        let long = PassageMediaIdentity(ebookStableId: "local:unknown:/Documents/\(folder)/book.epub", audiobookStableId: "local:unknown:/Documents/\(folder)", readingRevision: "r", trackRevisions: ["t"])
        let store = PassageAlignmentStore(root: root)
        let saved = try await store.commit(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]), identity: long)
        #expect(saved?.mappings.count == 3)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: long) == saved)
        await store.retire()
    }

    @Test func failedWriteKeepsThePreviousReadableVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("pairs").path)
            try? FileManager.default.removeItem(at: root)
        }
        let store = PassageAlignmentStore(root: root)
        store.windowsPerSave = 1
        let first = try await store.commit(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]), identity: identity)
        let directory = root.appendingPathComponent("pairs/\(PassageAlignmentStore.pairKey(ebookStableId: "ebook", audiobookStableId: "audio"))")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        await #expect(throws: CocoaError.self) {
            try await store.commit(update([mapping(5, start: 40, end: 44), mapping(6, start: 45, end: 49), mapping(7, start: 50, end: 54)], window: 1, owned: 37.75..<67.75), identity: identity)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(await store.mappingSet(for: identity) == first)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == first)
        await store.retire()
    }

    @Test func mergedWindowsAreSavedInBatchesAndOnFlushOrRetirement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PassageAlignmentStore(root: root)
        store.windowsPerSave = 3
        _ = try await store.commit(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]), identity: identity)
        let second = try await store.commit(update([mapping(5, start: 40, end: 44), mapping(6, start: 45, end: 49), mapping(7, start: 50, end: 54)], window: 1, owned: 37.75..<67.75), identity: identity)
        #expect(second?.mappings.count == 6)
        #expect(await store.mappingSet(for: identity) == second)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity)?.mappings.count == 3)

        await store.flush()
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == second)

        let third = try await store.commit(update([mapping(9, start: 70, end: 74), mapping(10, start: 75, end: 79), mapping(11, start: 80, end: 84)], window: 2, owned: 67.75..<97.75), identity: identity)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == second)
        await store.retire()
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == third)
    }

    @Test func aCommitArrivingDuringRemovalIsDroppedAndOneAfterwardIsSaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PassageAlignmentStore(root: root)
        let mappings = [mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]
        _ = try await store.commit(update(mappings), identity: identity)

        let removal = Task { await store.removeAll() }
        await Task.yield()
        let late = try await store.commit(update(mappings), identity: identity)
        await removal.value
        #expect(late == nil)
        #expect(await store.mappingSet(for: identity) == nil)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == nil)

        #expect(try await store.commit(update(mappings), identity: identity) != nil)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity)?.mappings.count == 3)
        await store.retire()
    }

    @Test func removingAllKeepsAnalysisDataAndALoadStartedEarlierCannotRepopulate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = PassageAlignmentStore(root: root)
        _ = try await writer.commit(update([mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]), identity: identity)
        try FileManager.default.createDirectory(at: writer.acousticDirectory, withIntermediateDirectories: true)
        try Data(count: 64).write(to: writer.acousticDirectory.appendingPathComponent("window.plist"))

        // A fresh store reads from disk, so this load is suspended when the removal runs.
        let store = PassageAlignmentStore(root: root)
        let load = Task { await store.mappingSet(for: identity) }
        await Task.yield()
        await store.removeAll()
        #expect(await load.value == nil)
        #expect(store.cachedMappingSet(ebookStableId: "ebook", audiobookStableId: "audio") == nil)
        #expect(await store.mappingSet(for: identity) == nil)
        #expect(FileManager.default.fileExists(atPath: writer.acousticDirectory.appendingPathComponent("window.plist").path))

        await store.clearAcousticCheckpoints()
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.acousticDirectory.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.acousticDirectory.path).isEmpty)
        await store.retire()
        await writer.retire()
    }

    @Test func retiredStoreRejectsLateCommitsAndUnlinkRemovesOnlyThatPair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PassageAlignmentStore(root: root)
        let other = PassageMediaIdentity(ebookStableId: "ebook-2", audiobookStableId: "audio", readingRevision: "x", trackRevisions: ["t"])
        let mappings = [mapping(0, start: 1, end: 5), mapping(1, start: 6, end: 9), mapping(2, start: 10, end: 14)]
        _ = try await store.commit(update(mappings), identity: identity)
        _ = try await store.commit(update(mappings), identity: other)
        await store.removePair(ebookStableId: "ebook", audiobookStableId: "audio")
        #expect(await store.mappingSet(for: identity) == nil)
        #expect(await store.mappingSet(for: other)?.mappings.count == 3)
        await store.retire()
        #expect(try await store.commit(update(mappings), identity: identity) == nil)
        #expect(await PassageAlignmentStore(root: root).mappingSet(for: identity) == nil)
    }

    @Test func acousticEvictionRemovesLeastRecentlyUsedUnpinnedWindows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, name) in ["old.plist", "pinned.plist", "new.plist"].enumerated() {
            let url = directory.appendingPathComponent(name)
            try Data(count: 1_000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index) * 1_000)], ofItemAtPath: url.path)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: directory.appendingPathComponent("pinned.plist").path)
        #expect(PassageAlignmentStore.evict(directory: directory, pinned: ["pinned.plist"], limit: 2_000))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(remaining == ["new.plist", "pinned.plist"])
        #expect(!PassageAlignmentStore.evict(directory: directory, pinned: ["new.plist", "pinned.plist"], limit: 500))
    }

    @Test func mediaIdentityIsContentBasedAndRevalidatedByFileAttributes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let epub = directory.appendingPathComponent("book.epub")
        let audio = directory.appendingPathComponent("track.mp3")
        try Data("epub".utf8).write(to: epub)
        try Data("audio-one".utf8).write(to: audio)
        let resolver = PassageMediaIdentityResolver(cacheURL: directory.appendingPathComponent("identity.json"))
        #expect(await resolver.cachedIdentity(ebookStableId: "e", audiobookStableId: "a", epubURL: epub, audioURLs: [audio]) == nil)
        let first = try await resolver.identity(ebookStableId: "e", audiobookStableId: "a", epubURL: epub, audioURLs: [audio])
        #expect(await resolver.cachedIdentity(ebookStableId: "e", audiobookStableId: "a", epubURL: epub, audioURLs: [audio]) == first)
        // Same duration-like size and name, different recording.
        try Data("audio-two".utf8).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: audio.path)
        #expect(await resolver.cachedIdentity(ebookStableId: "e", audiobookStableId: "a", epubURL: epub, audioURLs: [audio]) == nil)
        let second = try await resolver.identity(ebookStableId: "e", audiobookStableId: "a", epubURL: epub, audioURLs: [audio])
        #expect(second.readingRevision == first.readingRevision)
        #expect(second.trackRevisions != first.trackRevisions)
        resolver.retire()
    }

    @Test func engineSelectionNeverExecutesASavedAppleSpeechPreferenceOnOlderSystems() {
        #expect(PassageAlignmentService.selectEngine(preferred: .appleSpeech, language: "en-US", quartzNetSupported: true, modelInstalled: true, appleSpeechSystem: false) == .success(.quartzNet))
        #expect(PassageAlignmentService.selectEngine(preferred: .appleSpeech, language: "fr", quartzNetSupported: true, modelInstalled: true, appleSpeechSystem: false) == .failure(.unsupportedSystem))
        #expect(PassageAlignmentService.selectEngine(preferred: nil, language: "fr", quartzNetSupported: true, modelInstalled: true, appleSpeechSystem: false) == .failure(.unsupportedLanguage))
        #expect(PassageAlignmentService.selectEngine(preferred: .quartzNet, language: "en", quartzNetSupported: true, modelInstalled: false, appleSpeechSystem: false) == .failure(.modelDownloadRequired))
        #expect(PassageAlignmentService.selectEngine(preferred: .appleSpeech, language: "fr", quartzNetSupported: true, modelInstalled: true, appleSpeechSystem: true) == .success(.appleSpeech))
        #expect(PassageAlignmentService.selectEngine(preferred: .quartzNet, language: "de", quartzNetSupported: true, modelInstalled: true, appleSpeechSystem: true) == .success(.appleSpeech))
        #expect(PassageAlignmentService.selectEngine(preferred: nil, language: "en", quartzNetSupported: false, modelInstalled: false, appleSpeechSystem: false) == .failure(.unsupportedHardware))
        // Without an explicit choice the built-in engine is used where the system has it: no model download.
        #expect(PassageAlignmentService.selectEngine(preferred: nil, language: "en", quartzNetSupported: true, modelInstalled: false, appleSpeechSystem: true) == .success(.appleSpeech))
        #expect(PassageAlignmentService.selectEngine(preferred: nil, language: "en", quartzNetSupported: true, modelInstalled: true, appleSpeechSystem: false) == .success(.quartzNet))
        // An explicit QuartzNet choice is kept for English, model download included.
        #expect(PassageAlignmentService.selectEngine(preferred: .quartzNet, language: "en", quartzNetSupported: true, modelInstalled: false, appleSpeechSystem: true) == .failure(.modelDownloadRequired))
    }

    @Test func bookTimeMapsToTrackLocalTimeUsingThePlayerLayout() {
        let layout = [
            AudioTrackInfo(index: 0, startOffset: 0, duration: 100, contentUrl: "file:///a.mp3", mimeType: "audio/mpeg"),
            AudioTrackInfo(index: 1, startOffset: 100, duration: 50, contentUrl: "file:///b.mp3", mimeType: "audio/mpeg"),
        ]
        #expect(PassageAlignmentService.localPosition(bookTime: 30, layout: layout)! == (0, 30))
        #expect(PassageAlignmentService.localPosition(bookTime: 120, layout: layout)! == (1, 20))
        #expect(PassageAlignmentService.localPosition(bookTime: 500, layout: layout)! == (1, 50))
    }

    @Test func wordMatcherUsesRecognizedBoundariesAndRefusesRepeatsAndUnrelatedSpeech() {
        let sentences = [
            "The old sailor opened the wooden door.",
            "He looked across the quiet harbor toward the lighthouse.",
            "A bright orange lantern stood beside the folded map.",
            "Nobody remembered when the keeper had arrived.",
        ]
        let words = sentences.joined(separator: " ").split(separator: " ").enumerated().map { offset, word in
            TranscribedWord(text: String(word), start: Double(offset) * 0.4 + 10, end: Double(offset) * 0.4 + 10.3)
        }
        let matcher = PassageWordMatcher(sentences: sentences)
        let matches = matcher.match(words) { _ in true }
        #expect(matches.map(\.sentenceIndex) == [0, 1, 2, 3])
        #expect(matches.first?.start == 10)
        #expect(abs((matches.first?.end ?? 0) - (6 * 0.4 + 10.3)) < 0.001)
        #expect(matcher.match(words) { $0 > 14 }.map(\.sentenceIndex) == [1, 2, 3])

        let repeated = PassageWordMatcher(sentences: sentences + sentences)
        #expect(repeated.match(words) { _ in true }.isEmpty)

        let unrelated = "Engineers designed the suspension bridge using steel cables and concrete towers near the canyon".split(separator: " ").enumerated().map {
            TranscribedWord(text: String($0.element), start: Double($0.offset), end: Double($0.offset) + 0.5)
        }
        #expect(matcher.match(unrelated) { _ in true }.isEmpty)
    }
}

private extension PassageMapping {
    func withKey(chapter: Int, sentence: Int) -> PassageMapping {
        PassageMapping(
            key: PassageSentenceKey(chapter: chapter, sentence: sentence), href: href, text: text, before: before, after: after,
            chapterProgression: chapterProgression, totalProgression: totalProgression, trackIndex: trackIndex,
            start: start, end: end, granularity: granularity, engine: engine, score: score
        )
    }
}

private extension PassageTextResolution {
    var mappingKey: Int? {
        if case .matched(let mapping) = self { return mapping.key.sentence }
        return nil
    }
}
