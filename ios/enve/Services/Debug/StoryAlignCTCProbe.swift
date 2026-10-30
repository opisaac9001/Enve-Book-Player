#if DEBUG && os(iOS)
import Foundation
import StoryAlignCore
import UIKit

@MainActor
enum StoryAlignCTCProbe {
    static func benchmark(profile: ProfileSession) async {
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        let directory = profile.storage.applicationSupportDirectory.appendingPathComponent("Enve/CTCBenchmark", isDirectory: true)
        do {
            let model = try await StoryAlignModelStore.shared.prepare()
            _ = try await QuartzNetBenchmark.run(
                pcmURL: directory.appendingPathComponent("seamage-38.f32"),
                modelDirectory: model,
                outputDirectory: directory
            )
        } catch {
            let report = ["domain": (error as NSError).domain, "code": String((error as NSError).code)]
            try? JSONEncoder().encode(report).write(to: directory.appendingPathComponent("error.json"), options: .atomic)
        }
    }

    static func probeLocalFiles(profile: ProfileSession, fullAlignment: Bool = false) async {
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        let documents = profile.storage.documentsDirectory
        let output = documents.appendingPathComponent(fullAlignment ? "storyalign-ctc-fixture-full.json" : "storyalign-ctc-probe.json")
        do {
            let model = try await StoryAlignModelStore.shared.prepare()
            let session = profile.storage.applicationSupportDirectory.appendingPathComponent("Enve/CTCTestFixture", isDirectory: true)
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            if fullAlignment {
                let working = session.appendingPathComponent("full-alignment", isDirectory: true)
                try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
                let request = try AlignmentRequest(
                    epubURL: session.appendingPathComponent("ctc-fixture.epub"),
                    audioBookURLs: [session.appendingPathComponent("ctc-fixture.mp3")],
                    sessionDir: working.path
                )
                let result = try await StoryAligner().alignStory(
                    session: AlignmentSession(request: request, config: AlignmentConfig(audioLoaderType: .avfoundation, concurrency: 1)),
                    ctcConfiguration: CTCAlignmentConfiguration(modelDirectory: model)
                )
                try JSONEncoder().encode(result.ctcQuality).write(to: output, options: .atomic)
                return
            }
            let result = try await StoryAligner().probeCTC(
                epubURL: session.appendingPathComponent("ctc-fixture.epub"),
                audioURL: session.appendingPathComponent("ctc-fixture.mp3"),
                modelDirectory: model, sessionDirectory: session, duration: 17
            )
            try JSONEncoder().encode(result).write(to: output, options: .atomic)
        } catch {
            let report: [String: String] = [
                "errorType": String(describing: type(of: error)),
                "domain": (error as NSError).domain,
                "code": String((error as NSError).code),
                "file": ((error as NSError).userInfo[NSFilePathErrorKey] as? String)
                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            ]
            try? JSONEncoder().encode(report).write(to: output, options: .atomic)
        }
    }

    static func downloadAssets(title: String, engine: EnveEngine, profile: ProfileSession, probeStart: Double? = nil, fullAlignment: Bool = false, installPreparedBook: Bool = false) async {
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        let reportURL = profile.storage.documentsDirectory.appendingPathComponent("storyalign-ctc-assets.json")
        func report(_ status: String, paths: [String] = []) {
            let body: [String: Any] = [
                "status": status, "paths": paths,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue
            ]
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: reportURL, options: .atomic)
            }
        }

        report("Searching library")
        let candidates = await engine.library.searchBooks(query: title, limit: 100)
        guard let audio = candidates.first(where: { $0.mediaType == .audiobook }),
              let ebook = candidates.first(where: { $0.mediaType == .ebook && $0.readAloudSourceStableId == nil && $0.providerId == audio.providerId })
                ?? candidates.first(where: { $0.mediaType == .ebook && $0.readAloudSourceStableId == nil }) else {
            report("Matching ebook and audiobook were not found in this profile")
            return
        }
        for book in [ebook, audio] {
            if !engine.downloads.isDownloaded(book) {
                report("Downloading \(book.mediaType.rawValue)")
                await engine.downloads.download(book)
            }
            let deadline = Date().addingTimeInterval(3_600)
            while !engine.downloads.isDownloaded(book) {
                guard !Task.isCancelled, !profile.isRetired else { report("Cancelled"); return }
                if let task = engine.downloads.mostRelevantTask(for: book) {
                    if task.status == .failed { report("Download failed for \(book.mediaType.rawValue)"); return }
                    report("Downloading \(book.mediaType.rawValue): \(Int(task.progress * 100))%")
                }
                guard Date() < deadline else { report("Download timed out"); return }
                do { try await Task.sleep(for: .seconds(2)) }
                catch { report("Cancelled"); return }
            }
        }
        let audioFiles = profile.localStorage.localAudiobookFilesIfExists(for: audio) ?? []
        let ebookFile = profile.ebooks.resolveEbookForOverlay(book: ebook)
        let paths = (ebookFile.map { [$0] } ?? []) + audioFiles
        guard !audioFiles.isEmpty, ebookFile != nil else { report("Downloaded files could not be resolved"); return }
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path + "/"
        let relativePaths = paths.map { $0.resolvingSymlinksInPath().path.replacingOccurrences(of: home, with: "") }
        report("Ready", paths: relativePaths)
        if installPreparedBook {
            let incoming = profile.storage.documentsDirectory.appendingPathComponent("storyalign-corrected.epub")
            let imported = profile.storage.documentsDirectory.appendingPathComponent("Ebooks/local/storyalign-corrected.epub")
            let prepared = FileManager.default.fileExists(atPath: incoming.path) ? incoming : imported
            guard FileManager.default.fileExists(atPath: prepared.path),
                  let existing = profile.storyAlignService.cachedNarratedEpubURL(ebook: ebook, audiobook: audio) else {
                report("Prepared book or existing alignment was not found")
                return
            }
            do {
                try engine.storyAlign.cancelConversion()
                _ = try FileManager.default.replaceItemAt(existing, withItemAt: prepared)
                report("Installed validated narrated book; reading position retained")
            } catch { report("Prepared book installation failed: \(String(describing: type(of: error)))") }
            return
        }
        if fullAlignment {
            do {
                engine.storyAlign.method = .quartzNet
                try engine.storyAlign.startConversion(ebook: ebook, audiobook: audio)
                while !Task.isCancelled, !profile.isRetired {
                    if let state = engine.storyAlign.activeConversion {
                        if state.error != nil { report("Alignment failed; inspect StoryAlign in the app"); return }
                        if state.isComplete { report("Alignment complete: \(state.detailText ?? "")"); return }
                        report("\(state.stage): \(Int(state.progress * 100))%")
                    } else if let paused = engine.storyAlign.pausedConversion {
                        report("Paused: \(paused.reason)"); return
                    } else { report("Cancelled"); return }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch { report("Alignment failed: \(String(describing: type(of: error)))") }
            return
        }
        if let probeStart, let ebookFile, let audioFile = audioFiles.first {
            do {
                report("Preparing model", paths: relativePaths)
                let directory = try await StoryAlignModelStore.shared.prepare()
                let session = profile.storage.documentsDirectory.appendingPathComponent("StoryAlignProbe", isDirectory: true)
                try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                report("Analyzing excerpt")
                let result = try await StoryAligner().probeCTC(
                    epubURL: ebookFile, audioURL: audioFile, modelDirectory: directory,
                    sessionDirectory: session, start: probeStart, duration: 38
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(result).write(
                    to: profile.storage.documentsDirectory.appendingPathComponent("storyalign-ctc-probe.json"), options: .atomic
                )
                report("Probe complete")
            } catch {
                report("Probe failed: \(String(describing: type(of: error)))")
            }
        }
    }
}
#endif
