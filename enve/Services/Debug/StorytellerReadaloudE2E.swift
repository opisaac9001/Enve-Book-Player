#if DEBUG && os(iOS)
import Foundation
import ReadiumZIPFoundation

@MainActor
enum StorytellerReadaloudE2E {

    private struct Report {
        var lines: [String] = []
        var pass = 0
        var fail = 0
        var skip = 0

        mutating func ok(_ m: String) { lines.append("[PASS] \(m)"); pass += 1 }
        mutating func bad(_ m: String) { lines.append("[FAIL] \(m)"); fail += 1 }
        mutating func na(_ m: String) { lines.append("[SKIP] \(m)"); skip += 1 }
        mutating func note(_ m: String) { lines.append("       \(m)") }

        func write() {
            let header = "STORYTELLER READ-ALOUD E2E - \(pass) pass, \(fail) fail, \(skip) skip"
            let body =
                ([header, String(repeating: "-", count: header.count)]
                + lines
                + ["SUMMARY: \(pass) pass, \(fail) fail, \(skip) skip"]).joined(separator: "\n")
            try? body.write(
                to: URL.documentsDirectory.appendingPathComponent("enve_storyteller_readaloud.txt"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    static func run(
        serverURL: String?,
        titleNeedle: String?,
        engine: EnveEngine,
        appState: AppState
    ) async {
        var report = Report()
        defer { report.write() }

        let candidates = appState.providerConnections.connections.filter { $0.type == .storyteller && !$0.isArchived }
        guard
            let connection = candidates.first(where: { serverURL == nil || $0.url == serverURL })
                ?? candidates.first
        else {
            report.bad("No Storyteller connection. Pass -imagineSourceType storyteller -imagineSourceURL/User/Password, or add one in Settings.")
            return
        }
        report.ok("Connection: \"\(connection.name)\" \(connection.url)")

        guard let provider = appState.getProvider(connection.id) as? StorytellerProvider else {
            report.bad("Connection has no live StorytellerProvider instance.")
            return
        }

        var books: [Book] = []
        do {
            books = try await provider.fetchBooks(libraryId: "storyteller-library")
            books.isEmpty ? report.bad("Books: server returned 0") : report.ok("Books: \(books.count)")
        } catch {
            report.bad("Books: \(error.localizedDescription)")
            return
        }

        let readalouds = books.filter { $0.epub3Features?.hasMediaOverlay == true }
        guard let seed = pick(readalouds, needle: titleNeedle) else {
            report.bad("No book reported a read-aloud (epub3Features.hasMediaOverlay).")
            report.note("Titles seen: \(books.prefix(10).map(\.title).joined(separator: ", "))")
            return
        }
        report.ok("Read-aloud book: \"\(seed.title)\" id=\(seed.id) mediaType=\(seed.mediaType.rawValue)")

        await LibraryCatalogCoordinator.shared.refreshConnectionLibraries(providerId: connection.id)
        let stored = await engine.library.books(source: Book.BookSource.storyteller.rawValue, providerId: connection.id)
        guard let book = stored.first(where: { $0.id == seed.id }) else {
            report.bad("Synced store: read-aloud book missing after import")
            return
        }
        book.epub3Features?.hasMediaOverlay == true
            ? report.ok("Synced store: read-aloud flag survived import")
            : report.bad("Synced store: read-aloud flag lost on import")

        verifyLibraryMetadata(book: book, report: &report)
        await runDownload(book: book, engine: engine, report: &report)
        report.note("Footprint after download: \(footprint())")
        let asset = await verifyOfflineAsset(book: book, report: &report)
        await verifyOverlayPlayback(book: book, asset: asset, provider: provider, report: &report)
        report.note("Footprint after playback prep: \(footprint())")
        await verifyReaderOpen(book: book, engine: engine, report: &report)
        report.note("Footprint after reader: \(footprint())")
    }

    private static func footprint() -> String {
        let importer = LocalEbookImporter.shared
        let overlayTemp = FileManager.default.temporaryDirectory.appendingPathComponent("enve-overlay")
        let audiobooks = URL.documentsDirectory.appendingPathComponent("Audiobooks", isDirectory: true)
        let parts = [
            ("readaloud", importer.readaloudCacheRoot),
            ("ebooks", importer.serverEbooksRoot),
            ("overlay-tmp", overlayTemp),
            ("audiobooks", audiobooks),
        ]
        return
            parts
            .map { "\($0.0)=\(ByteCountFormatter.string(fromByteCount: directorySize($0.1), countStyle: .file))" }
            .joined(separator: " ")
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else { return 0 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private static func verifyLibraryMetadata(book: Book, report: inout Report) {
        let tracks = book.audioTracks ?? []
        let textTracks = tracks.filter {
            $0.format?.contains("xhtml") == true
                || $0.contentUrl?.lowercased().contains(".xhtml") == true
        }
        if tracks.isEmpty {
            report.ok("Library record: no streamable audio tracks (audio is inside the EPUB)")
        } else if !textTracks.isEmpty {
            report.bad(
                "Library record: \(textTracks.count)/\(tracks.count) 'audio tracks' are XHTML chapters from the read-aloud web manifest"
            )
        } else {
            report.ok("Library record: \(tracks.count) real audio track(s)")
        }

        if let duration = book.duration, duration > 0 {
            report.ok("Library record: duration \(Int(duration))s")
        } else {
            report.bad("Library record: duration is \(book.duration.map { String(Int($0)) } ?? "nil")")
        }

        let chapters = book.chapters ?? []
        if chapters.isEmpty {
            report.na("Library record: no chapters yet (built on open)")
        } else {
            let degenerate = chapters.filter { $0.end <= $0.start }
            degenerate.isEmpty
                ? report.ok("Library record: \(chapters.count) chapter(s), all non-empty")
                : report.bad("Library record: \(degenerate.count)/\(chapters.count) chapter(s) are zero-length")
        }
    }

    private static func runDownload(book: Book, engine: EnveEngine, report: inout Report) async {
        await engine.downloads.removeDownload(for: book)
        LocalEbookImporter.shared.removeReadaloudCache(forBookId: book.id, stableId: book.stableId)

        await engine.downloads.download(book)

        for _ in 0..<720 {
            if let task = engine.downloads.mostRelevantTask(for: book) {
                if task.status == .completed { break }
                if task.status == .failed {
                    report.bad("Download: task failed - \(task.errorMessage ?? "unknown")")
                    return
                }
            }
            if engine.downloads.isDownloaded(book) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }

        engine.downloads.isDownloaded(book)
            ? report.ok("Download: reported complete")
            : report.bad("Download: never reported complete")
    }

    private static func verifyOfflineAsset(book: Book, report: inout Report) async -> URL? {
        guard let url = LocalEbookImporter.shared.resolveEbookForOverlay(book: book) else {
            report.bad("Offline asset: nothing on disk after download")
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        report.note("Offline asset: \(url.lastPathComponent) (\(size) bytes)")

        guard let archive = try? await Archive(url: url, accessMode: .read),
            let entries = try? await archive.entries()
        else {
            report.bad("Offline asset: not a readable EPUB archive")
            return nil
        }
        let paths = entries.filter { $0.type == .file }.map { $0.path.lowercased() }
        let smilCount = paths.filter { $0.hasSuffix(".smil") }.count
        let audioCount = paths.filter { path in
            let ext = (path as NSString).pathExtension
            return !ext.isEmpty && AudiobookFormat.from(fileExtension: ext) != nil
        }.count

        smilCount > 0
            ? report.ok("Offline asset: \(smilCount) SMIL overlay file(s)")
            : report.bad("Offline asset: no SMIL - this is the text-only ebook, not the read-aloud EPUB")
        audioCount > 0
            ? report.ok("Offline asset: \(audioCount) embedded audio file(s)")
            : report.bad("Offline asset: no embedded audio - this is the text-only ebook, not the read-aloud EPUB")

        return url
    }

    private static func verifyOverlayPlayback(
        book: Book,
        asset: URL?,
        provider: StorytellerProvider,
        report: inout Report
    ) async {
        guard asset != nil else {
            report.na("Overlay playback: skipped, no offline asset")
            return
        }

        let result: MediaOverlayPlaybackService.OverlayAudioResult
        let started = CFAbsoluteTimeGetCurrent()
        do {
            result = try await MediaOverlayPlaybackService.shared.prepareAudioTracks(for: book)
        } catch {
            report.bad("Overlay prepare: \(error.localizedDescription)")
            return
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        report.ok(
            "Overlay prepare: \(result.timeline.clips.count) clip(s), \(result.tracks.count) track(s), \(String(format: "%.1f", result.totalDuration))s in \(String(format: "%.1f", elapsed))s"
        )
        result.chapters.isEmpty
            ? report.bad("Overlay prepare: 0 chapters built")
            : report.ok("Overlay prepare: \(result.chapters.count) chapter(s)")

        let missingAudio = result.tracks.filter { track in
            guard let url = URL(string: track.contentUrl) else { return true }
            return !FileManager.default.fileExists(atPath: url.path)
        }
        missingAudio.isEmpty
            ? report.ok("Overlay prepare: every track extracted to disk")
            : report.bad("Overlay prepare: \(missingAudio.count) track(s) missing on disk")

        do {
            try await MediaOverlayPlaybackService.shared.play(book, presentPlayer: false)
            ActivePlayback.controller.snapshot.isOverlayPlaybackActive
                ? report.ok("Overlay playback: session active")
                : report.bad("Overlay playback: session did not activate")
        } catch {
            report.bad("Overlay playback: \(error.localizedDescription)")
            return
        }

        let originalPosition = try? await provider.fetchPipelinePosition(for: book)
        let probeTime = result.totalDuration * 0.5
        guard let clipIndex = result.timeline.clipIndex(atAudioTime: probeTime) else {
            report.bad("Position round-trip: no clip at \(String(format: "%.1f", probeTime))s")
            return
        }
        report.note(
            "Position probe: t=\(String(format: "%.2f", probeTime))s → clip \(clipIndex) \(result.timeline.clips[clipIndex].textHref)"
        )

        MediaOverlayPlaybackService.shared.syncEbookPositionFromAudio(
            audioTime: probeTime,
            book: book,
            authoritative: true
        )
        try? await Task.sleep(for: .seconds(2))

        let live = AppState.shared.bookInMemory(uniqueId: book.uniqueId) ?? book
        if let locator = live.epubLocator,
            let resolved = result.timeline.resolveEPUB3Locator(locatorJSON: locator)
        {
            resolved.clipIndex == clipIndex
                ? report.ok(
                    "Position round-trip: locator restored clip \(resolved.clipIndex) at \(String(format: "%.2f", resolved.audioTime))s"
                )
                : report.bad("Position round-trip: locator restored clip \(resolved.clipIndex), expected \(clipIndex)")
        } else {
            report.bad("Position round-trip: no locator written locally")
        }

        do {
            if let server = try await provider.fetchPipelinePosition(for: live),
                let resolved = result.timeline.resolveEPUB3Locator(locatorJSON: server.locatorJSON)
            {
                resolved.clipIndex == clipIndex
                    ? report.ok("Server position: round-tripped to clip \(resolved.clipIndex)")
                    : report.bad("Server position: round-tripped to clip \(resolved.clipIndex), expected \(clipIndex)")
            } else {
                report.bad("Server position: server returned nothing after a read-aloud sync")
            }
        } catch {
            report.bad("Server position: \(error.localizedDescription)")
        }

        ActivePlayback.controller.pause()

        if let originalPosition {
            do {
                _ = try await provider.sendPipelinePosition(originalPosition, for: live)
                report.ok("Server position: original restored")
            } catch {
                report.bad("Server position: could not restore original - \(error.localizedDescription)")
            }
        } else {
            report.note("Server position: book had no prior server position to restore")
        }
    }

    private static func verifyReaderOpen(book: Book, engine: EnveEngine, report: inout Report) async {
        let live = AppState.shared.bookInMemory(uniqueId: book.uniqueId) ?? book
        engine.playback.presentReader(for: live)
        try? await Task.sleep(for: .seconds(6))
        AppState.shared.presentation.selectedEbookForDetail != nil
            ? report.ok("Reader: presented without crashing")
            : report.bad("Reader: never presented")
    }

    private static func pick(_ books: [Book], needle: String?) -> Book? {
        guard let needle, !needle.isEmpty else { return books.first }
        return books.first { $0.title.localizedCaseInsensitiveContains(needle) } ?? books.first
    }
}
#endif

#if DEBUG && os(iOS)

@MainActor
enum StorytellerPositionProbe {

    static func run(
        fraction: Double?,
        titleNeedle: String?,
        engine: EnveEngine,
        appState: AppState
    ) async {
        var lines: [String] = ["STORYTELLER POSITION PROBE"]
        func emit(_ line: String) { lines.append(line) }
        defer {
            try? lines.joined(separator: "\n").write(
                to: URL.documentsDirectory.appendingPathComponent("enve_storyteller_position.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        guard let connection = appState.providerConnections.connections.first(where: { $0.type == .storyteller && !$0.isArchived }),
            let provider = appState.getProvider(connection.id) as? StorytellerProvider
        else {
            emit("no Storyteller connection")
            return
        }

        let stored = await engine.library.books(
            source: Book.BookSource.storyteller.rawValue,
            providerId: connection.id
        )
        guard
            let book = stored.first(where: { candidate in
                guard let titleNeedle, !titleNeedle.isEmpty else { return candidate.epub3Features?.hasMediaOverlay == true }
                return candidate.title.localizedCaseInsensitiveContains(titleNeedle)
            })
        else {
            emit("book not found for needle \(titleNeedle ?? "-")")
            return
        }
        emit("book: \(book.title)")

        guard LocalEbookImporter.shared.resolveEbookForOverlay(book: book) != nil else {
            emit("not downloaded - download it first")
            return
        }

        let result: MediaOverlayPlaybackService.OverlayAudioResult
        do {
            result = try await MediaOverlayPlaybackService.shared.prepareAudioTracks(for: book)
        } catch {
            emit("overlay prepare failed: \(error.localizedDescription)")
            return
        }
        emit("total duration: \(Int(result.totalDuration))s across \(result.timeline.clips.count) clips")

        func describe(_ label: String, locatorJSON: String?) {
            guard let locatorJSON else { emit("\(label): nil"); return }
            if let resolved = result.timeline.resolveEPUB3Locator(locatorJSON: locatorJSON) {
                let percent = result.totalDuration > 0 ? resolved.audioTime / result.totalDuration * 100 : 0
                emit("\(label): clip \(resolved.clipIndex) · \(Int(resolved.audioTime))s · \(String(format: "%.2f", percent))%")
            } else {
                emit("\(label): UNRESOLVABLE")
            }
            emit("    raw: \(locatorJSON.prefix(220))")
        }

        let serverBefore = try? await provider.fetchPipelinePosition(for: book)
        describe("server position", locatorJSON: serverBefore?.locatorJSON)
        describe("local locator", locatorJSON: book.epubLocator)
        emit("local ebookProgress: \(String(describing: book.ebookProgress))")

        guard let fraction else {
            emit("read-only probe (pass -imagineSeekFraction to move it)")
            return
        }

        let target = result.totalDuration * min(max(fraction, 0), 1)
        emit("--- seeking to \(String(format: "%.0f", fraction * 100))% = \(Int(target))s ---")
        _ = try? await MediaOverlayPlaybackService.shared.play(book, presentPlayer: false)
        ActivePlayback.controller.pause()
        MediaOverlayPlaybackService.shared.syncEbookPositionFromAudio(
            audioTime: target,
            book: book,
            authoritative: true
        )
        try? await Task.sleep(for: .seconds(4))

        let live = appState.bookInMemory(uniqueId: book.uniqueId) ?? book
        describe("local locator after seek", locatorJSON: live.epubLocator)
        let serverAfter = try? await provider.fetchPipelinePosition(for: live)
        describe("server position after seek", locatorJSON: serverAfter?.locatorJSON)
    }
}
#endif
