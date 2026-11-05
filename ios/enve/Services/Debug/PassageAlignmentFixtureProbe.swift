#if DEBUG && os(iOS)
import AVFoundation
import Foundation
@preconcurrency import ReadiumShared
import StoryAlignCore
import UIKit

/// Runs the production passage analyzer, mapping builder and store against a generated fixture in
/// `Library/Application Support/Enve/PassageFixture` and writes counts and timings to
/// `Documents/passage-fixture-report.json`. It never downloads a model or requests Speech permission.
@MainActor
enum PassageAlignmentFixtureProbe {
    private struct Truth: Decodable {
        struct Track: Decodable {
            let file: String
            let duration: Double
            let sentences: [Sentence]
        }

        struct Sentence: Decodable {
            let text: String
            let chapter: Int
            let start: Double
            let end: Double
        }

        struct Unrelated: Decodable {
            let file: String
        }

        let tracks: [Track]
        let unrelated: Unrelated
        let unspoken: [String]
    }

    static func run(profile: ProfileSession) async {
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        let input = profile.storage.applicationSupportDirectory.appendingPathComponent("Enve/PassageFixture", isDirectory: true)
        let output = profile.storage.documentsDirectory.appendingPathComponent("passage-fixture-report.json")
        var report: [String: Any] = [
            "systemVersion": UIDevice.current.systemVersion,
            "appleSpeechSystemAvailable": PassageAlignmentService.appleSpeechSystemAvailable,
        ]
        do {
            report.merge(try await evaluate(input: input)) { $1 }
        } catch {
            report["error"] = String(describing: error)
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }

    private static func evaluate(input: URL) async throws -> [String: Any] {
        let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: input.appendingPathComponent("ground-truth.json")))
        guard let model = StoryAlignModelStore.shared.installedModelDirectory else { return ["result": "model not installed"] }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("passage-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let epub = input.appendingPathComponent("passage-fixture.epub")
        let clock = ContinuousClock()
        let started = clock.now

        let analyzer = try await CTCPassageAnalyzer(
            epubURL: epub, modelDirectory: model, workingDirectory: work,
            checkpointDirectory: work.appendingPathComponent("acoustic", isDirectory: true)
        )
        let setup = clock.now - started
        let sentences = PassageAlignmentService.passageSentences(analyzer.sentences)
        let engine = QuartzNetPassageEngine(analyzer: analyzer)
        var tracks: [PassageTrack] = []
        for (index, track) in truth.tracks.enumerated() {
            let url = input.appendingPathComponent(track.file)
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            tracks.append(PassageTrack(index: index, url: url, digest: try PassageMediaIdentityResolver.sha256(url), duration: duration, bookOffset: 0))
        }
        let identity = PassageMediaIdentity(ebookStableId: "fixture-ebook", audiobookStableId: "fixture-audio", readingRevision: try PassageMediaIdentityResolver.sha256(epub), trackRevisions: tracks.map(\.digest))
        let store = PassageAlignmentStore(root: work.appendingPathComponent("store", isDirectory: true))

        var windowTimings: [Double] = []
        var windowsAccepted = 0
        func analyze(_ track: PassageTrack, _ window: CTCPassageWindow) async throws -> PassageMappingSet? {
            let grid = CTCPassageWindow.grid(trackDuration: track.duration)
            let previous = window.index > 0 ? grid[window.index - 1] : nil
            let windowStart = clock.now
            let matches = try await engine.analyze(window: window, previous: previous, track: track)
            windowTimings.append(seconds(clock.now - windowStart))
            let update = PassageWindowUpdate(
                trackIndex: track.index, windowIndex: window.index, ownedEnds: window.ownedEndStart..<min(window.ownedEndLimit, track.duration + 0.05), engine: engine.id,
                mappings: PassageAlignmentService.mappings(from: matches, sentences: sentences, track: track.index, engine: engine.id, granularity: .sentence)
            )
            if update.isAccepted { windowsAccepted += 1 }
            return try await store.commit(update, identity: identity)
        }

        // A current passage in the middle of the first track, analyzed before any look-ahead.
        let firstTarget = truth.tracks[0].sentences[truth.tracks[0].sentences.count / 2]
        let target = (firstTarget.start + firstTarget.end) / 2
        let grid0 = CTCPassageWindow.grid(trackDuration: tracks[0].duration)
        let owner = try requireWindow(CTCPassageWindow.owner(ofEnd: firstTarget.end, in: grid0))
        var set = try await analyze(tracks[0], owner)
        let firstResolution = set?.resolve(trackIndex: 0, time: target)
        let firstPassage = seconds(clock.now - started)

        // Remaining windows out of order: look-ahead first, then behind, then the second track.
        var order = grid0.filter { $0.index > owner.index } + grid0.filter { $0.index < owner.index }.reversed()
        var queue = order.map { (tracks[0], $0) }
        order = CTCPassageWindow.grid(trackDuration: tracks[1].duration)
        queue += order.map { (tracks[1], $0) }
        for (track, window) in queue {
            set = try await analyze(track, window) ?? set
        }
        let total = seconds(clock.now - started)
        guard let set else { return ["result": "no mapping committed"] }

        var correct = 0, wrong = 0, abstained = 0, pauses = 0
        var startErrors: [Double] = []
        var textCorrect = 0, textWrong = 0, textAbstained = 0
        var textErrors: [Double] = []
        for (trackIndex, track) in truth.tracks.enumerated() {
            for sentence in track.sentences {
                let midpoint = (sentence.start + sentence.end) / 2
                switch set.resolve(trackIndex: trackIndex, time: midpoint) {
                case .matched(let mapping):
                    if Self.same(mapping, sentence) {
                        correct += 1
                        startErrors.append(abs(mapping.start - sentence.start))
                    } else {
                        wrong += 1
                    }
                case .pause: pauses += 1
                case .gap, .unprepared: abstained += 1
                }
                let candidate = sentences.first { $0.key.chapter == sentence.chapter && PassageMappingSet.normalized($0.text) == PassageMappingSet.normalized(sentence.text) }
                guard let candidate else { textAbstained += 1; continue }
                switch set.resolve(href: candidate.href, quote: sentence.text, chapterProgression: candidate.chapterProgression, sentences: sentences) {
                case .matched(let mapping):
                    if mapping.trackIndex == trackIndex, Self.same(mapping, sentence) {
                        textCorrect += 1
                        textErrors.append(abs(mapping.start - sentence.start))
                    } else {
                        textWrong += 1
                    }
                default: textAbstained += 1
                }
            }
        }
        let unspoken = truth.unspoken.map { title -> String in
            guard let sentence = sentences.first(where: { PassageMappingSet.normalized($0.text) == PassageMappingSet.normalized(title) }) else { return "missing" }
            return String(describing: set.resolve(href: sentence.href, quote: sentence.text, chapterProgression: sentence.chapterProgression, sentences: sentences)).components(separatedBy: "(").first ?? ""
        }

        // Adversarial: narration of unrelated text must not produce an accepted passage.
        let unrelatedURL = input.appendingPathComponent(truth.unrelated.file)
        let unrelatedDuration = try await AVURLAsset(url: unrelatedURL).load(.duration).seconds
        let unrelated = PassageTrack(index: 9, url: unrelatedURL, digest: try PassageMediaIdentityResolver.sha256(unrelatedURL), duration: unrelatedDuration, bookOffset: 0)
        var adversarialMatches = 0
        var adversarialAccepted = 0
        for window in CTCPassageWindow.grid(trackDuration: unrelatedDuration) {
            let matches = try await engine.analyze(window: window, previous: nil, track: unrelated)
            adversarialMatches += matches.count
            if matches.count >= 3 { adversarialAccepted += 1 }
        }

        // Validated cached resume: a fresh store instance loads the saved mapping and resolves the target.
        let resumeStart = clock.now
        let reopened = PassageAlignmentStore(root: work.appendingPathComponent("store", isDirectory: true))
        let restored = await reopened.mappingSet(for: identity)
        let resumed = restored?.resolve(trackIndex: 0, time: target).mapping
        let cachedResume = seconds(clock.now - resumeStart)
        await store.retire()
        await reopened.retire()

        let spoken = truth.tracks.reduce(0) { $0 + $1.sentences.count }
        return [
            "result": "completed",
            "executionProvider": await analyzer.executionProvider?.rawValue ?? "none",
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "setupSeconds": seconds(setup),
            "firstPassageSeconds": firstPassage,
            "firstPassageCorrect": firstResolution?.mapping.map { Self.same($0, firstTarget) } ?? false,
            "totalSeconds": total,
            "windowsAnalyzed": windowTimings.count,
            "windowsAccepted": windowsAccepted,
            "windowSecondsMedian": percentile(windowTimings, 0.5),
            "windowSecondsMax": windowTimings.max() ?? 0,
            "spokenSentences": spoken,
            "audioToText": ["correct": correct, "wrong": wrong, "abstained": abstained, "pause": pauses],
            "startErrorSeconds": ["p50": percentile(startErrors, 0.5), "p95": percentile(startErrors, 0.95), "max": startErrors.max() ?? 0],
            "textToAudio": ["correct": textCorrect, "wrong": textWrong, "abstained": textAbstained],
            "textStartErrorSeconds": ["p95": percentile(textErrors, 0.95), "max": textErrors.max() ?? 0],
            "unspokenHeading": unspoken,
            "coverageSeconds": set.coverage.reduce(0) { $0 + $1.end - $1.start },
            "audioSeconds": tracks.reduce(0) { $0 + $1.duration },
            "adversarialMatches": adversarialMatches,
            "adversarialAcceptedWindows": adversarialAccepted,
            "cachedResumeSeconds": cachedResume,
            "cachedResumeCorrect": resumed.map { Self.same($0, firstTarget) } ?? false,
        ]
    }

    /// Drives the shipping read-along flow on fixture books imported through file sharing: link, prepare,
    /// play, open the reader, follow, browse, resume, seek across tracks and Listen from here. Writes
    /// `Documents/readalong-fixture-report.json` after every stage so screenshots can be taken alongside.
    static func runReadAlong(profile: ProfileSession, engine: EnveEngine) async {
        let output = profile.storage.documentsDirectory.appendingPathComponent("readalong-fixture-report.json")
        var stages: [[String: Any]] = []
        func note(_ stage: String, _ details: [String: Any] = [:]) {
            stages.append(details.merging(["stage": stage]) { $1 })
            let body: [String: Any] = ["systemVersion": UIDevice.current.systemVersion, "stages": stages]
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: .atomic)
            }
        }
        func wait(_ seconds: Double, until condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return await condition()
        }

        var ebook: Book?
        var audiobook: Book?
        _ = await wait(90) {
            let books = await engine.library.searchBooks(query: "Lantern Keeper", limit: 20)
            ebook = books.first { $0.mediaType == .ebook && $0.readAloudSourceStableId == nil }
            audiobook = books.first { $0.mediaType == .audiobook }
            return ebook != nil && audiobook != nil
        }
        guard var ebook, let audiobook else { note("books not imported"); return }
        if ebook.linkedAudiobookStableId != audiobook.stableId {
            _ = await engine.library.linkAudiobook(audiobook, to: ebook)
            ebook = profile.appState.libraryCache.bookInMemory(stableId: ebook.stableId) ?? ebook
        }
        let passages = profile.passageAlignment
        note("linked", ["capability": String(describing: passages.capability(ebook: ebook, audiobook: audiobook))])

        let started = Date()
        passages.prepare(ebook: ebook, audiobook: audiobook, around: 0, reason: .handoff, ahead: 400)
        let prepared = await wait(180) { passages.status(ebook: ebook, audiobook: audiobook).coveredSeconds >= 150 }
        let status = passages.status(ebook: ebook, audiobook: audiobook)
        note("prepared", ["complete": prepared, "seconds": Date().timeIntervalSince(started), "covered": status.coveredSeconds, "total": status.totalSeconds, "activity": String(describing: status.activity)])

        let saved = profile.appState.libraryCache.bookInMemory(stableId: ebook.stableId) ?? ebook
        note("saved position", [
            "storedLocator": saved.epubLocator.map { String($0.prefix(240)) } ?? "none",
            "storedProgress": saved.canonicalEbookProgress,
            "audiobookPosition": profile.appState.libraryCache.bookInMemory(stableId: audiobook.stableId)?.currentTime ?? -1,
        ])
        engine.playback.presentReader(for: ebook)
        var reader: ClassicReaderModel?
        let opened = await wait(60) {
            reader = profile.playback.openReaders.first { $0.book.stableId == ebook.stableId }
            return reader?.isLinkedReadAlongAvailable == true
        }
        guard opened, let reader else { note("reader not ready", ["readerOpen": reader != nil]); return }
        try? await Task.sleep(for: .seconds(2))
        let opening = await reader.activeReaderEngineAdapter?.ttsLocator(at: nil)
        note("reader open", [
            "renderer": reader.activeReaderEngineAdapter.map { String(describing: $0.kind) } ?? "none",
            "visibleHref": opening?.href.string ?? "none",
            "visibleQuote": opening?.text.highlight.map { String($0.prefix(80)) } ?? "none",
        ])

        let controller = profile.playback.composition.controller
        engine.playback.play(audiobook, presentPlayer: false)
        _ = await wait(30) { controller.currentBook?.stableId == audiobook.stableId && controller.snapshot.isLoaded }
        controller.seek(to: 30)
        if !controller.isPlaying { controller.play() }
        reader.toggleLinkedReadAlong()

        func sample(_ label: String, count: Int) async {
            for _ in 0..<count {
                try? await Task.sleep(for: .seconds(1))
                let readAlong = reader.debugLinkedReadAlong
                note(label, [
                    "status": String(describing: readAlong.status),
                    "playhead": controller.progress,
                    "playing": controller.isPlaying,
                    "highlighted": readAlong.highlighted.map { "\($0.key.chapter):\($0.key.sentence)" } ?? "none",
                    "highlightStart": readAlong.highlighted?.start ?? -1,
                    "readerHref": reader.lastKnownLocator?.href.string ?? "none",
                    "readerProgression": reader.lastKnownLocator?.locations.totalProgression ?? -1,
                ])
            }
        }
        await sample("following", count: 6)
        try? await Task.sleep(for: .seconds(1))
        await reader.pageForward()
        await sample("browsing after page turn", count: 4)
        reader.resumeLinkedReadAlong()
        await sample("resumed", count: 3)

        // Renderer check only: QuartzNet prepares sentences, so these underlines carry no timing claim.
        if let mapping = reader.debugLinkedReadAlong.highlighted, let adapter = reader.activeReaderEngineAdapter {
            var drawn = 0
            for chunk in PassageWordMatcher.printedWords(mapping.text).prefix(6) {
                guard let locatorJSON = mapping.locatorJSON(location: chunk.location, length: chunk.length) else { continue }
                await adapter.applyReadAlongWordDecoration(locatorJSON: locatorJSON, color: .gold)
                drawn += 1
                try? await Task.sleep(for: .milliseconds(500))
            }
            note("word renderer", [
                "renderer": String(describing: adapter.kind), "sentence": "\(mapping.key.chapter):\(mapping.key.sentence)",
                "wordsDrawn": drawn, "mappingHasTimedWords": mapping.words != nil,
            ])
            await adapter.applyReadAlongWordDecoration(locatorJSON: nil, color: .gold)
        }
        controller.seek(to: 125)
        await sample("seek to second track", count: 6)

        controller.pause()
        try? await Task.sleep(for: .seconds(1))
        let before = controller.progress
        let result = await reader.listenFromHere()
        try? await Task.sleep(for: .seconds(1))
        note("listen from here", ["result": String(describing: result), "playheadBefore": before, "playheadAfter": controller.progress, "playing": controller.isPlaying])

        controller.pause()
        controller.seek(to: 10)
        try? await Task.sleep(for: .seconds(1))
        let beforeCancel = controller.progress
        let cancelled = Task { await reader.listenFromHere() }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        try? await Task.sleep(for: .seconds(1))
        note("listen cancelled", ["result": String(describing: cancelledResult), "playheadBefore": beforeCancel, "playheadAfter": controller.progress, "playing": controller.isPlaying])
        controller.pause()
        reader.toggleLinkedReadAlong()
        note("stopped", ["status": String(describing: reader.linkedReadAlongStatus)])

        // The fixture repeats this sentence in chapters 1 and 3. Pausing on the chapter 3 occurrence must save
        // that passage as the reading position, and the next launch must reopen at it rather than chapter 1.
        if case .matched(let repeated) = await passages.textResolution(
            ebook: ebook, audiobook: audiobook, href: "OEBPS/Text/ch3.xhtml",
            quote: "The bell above the harbor office rang three times before anyone answered it.", chapterProgression: nil
        ), let time = passages.bookTime(of: repeated, audiobook: audiobook) {
            controller.seek(to: time + 0.3)
            let stored = await wait(15) {
                profile.appState.libraryCache.bookInMemory(stableId: ebook.stableId)?.epubLocator == repeated.locatorJSON
            }
            note("restore target saved", [
                "href": repeated.href, "key": "\(repeated.key.chapter):\(repeated.key.sentence)",
                "audioTime": time, "storedLocatorIsMapping": stored,
            ])
        }
    }

    /// Older-system compatibility: a saved Apple Speech selection and paused job must survive unexecuted,
    /// cached passages must resolve both ways, and an English request must still prepare with QuartzNet.
    /// Writes `Documents/compatibility-report.json`.
    static func runCompatibility(profile: ProfileSession, engine: EnveEngine) async {
        var report: [String: Any] = [
            "systemVersion": UIDevice.current.systemVersion,
            "continuedProcessingClassPresent": NSClassFromString("BGContinuedProcessingTaskRequest") != nil,
            "appleSpeechSystemAvailable": PassageAlignmentService.appleSpeechSystemAvailable,
            "storedMethod": profile.defaults.string(forKey: "storyalign.method") ?? "none",
            "pausedJobBefore": profile.defaults.data(forKey: "storyalign.pausedConversion").map { String(decoding: $0, as: UTF8.self) } ?? "none",
        ]
        let storyAlign = profile.storyAlignService
        storyAlign.loadPausedConversion()
        report["activeMethod"] = storyAlign.method.rawValue
        report["pausedMethod"] = storyAlign.pausedConversion?.method.rawValue ?? "none"
        let books = await engine.library.searchBooks(query: "Lantern Keeper", limit: 20)
        guard let ebook = books.first(where: { $0.mediaType == .ebook && $0.readAloudSourceStableId == nil }),
            let audiobook = books.first(where: { $0.mediaType == .audiobook })
        else {
            report["result"] = "fixture books missing"
            write(report, to: profile.storage.documentsDirectory.appendingPathComponent("compatibility-report.json"))
            return
        }
        storyAlign.resumeConversion(ebook: ebook, audiobook: audiobook)
        report["resumeStartedJob"] = storyAlign.activeConversion != nil
        let passages = profile.passageAlignment
        report["capability"] = String(describing: passages.capability(ebook: ebook, audiobook: audiobook))
        report["frenchSelection"] = String(describing: PassageAlignmentService.selectEngine(
            preferred: .appleSpeech, language: "fr", quartzNetSupported: true, modelInstalled: true,
            appleSpeechSystem: PassageAlignmentService.appleSpeechSystemAvailable
        ))
        let cached = await passages.audioResolution(ebook: ebook, audiobook: audiobook, bookTime: 40)
        report["cachedAudioToText"] = cached.mapping.map { "\($0.key.chapter):\($0.key.sentence)" } ?? String(describing: cached)
        if let mapping = cached.mapping {
            let text = await passages.textResolution(ebook: ebook, audiobook: audiobook, href: mapping.href, quote: mapping.text, chapterProgression: mapping.chapterProgression)
            report["cachedTextToAudio"] = text == .matched(mapping)
        }

        await passages.removePair(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
        let removed = await passages.audioResolution(ebook: ebook, audiobook: audiobook, bookTime: 40)
        report["afterRemoval"] = String(describing: removed)
        let started = Date()
        let prepared = await passages.findReadingPosition(ebook: ebook, audiobook: audiobook, playhead: { 40 })
        report["foregroundQuartzNet"] = prepared.handoffMapping.map { "\($0.engine) \($0.key.chapter):\($0.key.sentence)" } ?? String(describing: prepared)
        report["foregroundSeconds"] = Date().timeIntervalSince(started)
        report["storedMethodAfter"] = profile.defaults.string(forKey: "storyalign.method") ?? "none"
        report["pausedJobAfter"] = profile.defaults.data(forKey: "storyalign.pausedConversion").map { String(decoding: $0, as: UTF8.self) } ?? "none"
        report["result"] = "completed"
        write(report, to: profile.storage.documentsDirectory.appendingPathComponent("compatibility-report.json"))
    }

    private static func write(_ report: [String: Any], to url: URL) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func same(_ mapping: PassageMapping, _ sentence: Truth.Sentence) -> Bool {
        mapping.key.chapter == sentence.chapter && PassageMappingSet.normalized(mapping.text) == PassageMappingSet.normalized(sentence.text)
    }

    private static func requireWindow(_ window: CTCPassageWindow?) throws -> CTCPassageWindow {
        guard let window else { throw CocoaError(.featureUnsupported) }
        return window
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }
}
#endif
