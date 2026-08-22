import AVFoundation
import Foundation
import Logging
import ReadiumZIPFoundation

@MainActor
enum StorytellerReadaloudOfflinePrep {

    struct Result {
        let extractedAudioCount: Int
        let chapters: [Chapter]
    }

    static func prepare(epubURL: URL, book: Book) async -> Result {
        let bookId = book.downloadKey
        let destinationDir = LocalStorageManager.shared.bookAudioDirectory(for: bookId)

        let extractedCount: Int
        do {
            extractedCount = try await extractAudioFiles(from: epubURL, into: destinationDir)
            AppLogger.network.debug(
                "[Storyteller Offline] Extracted \(extractedCount) audio files \(DiagnosticLogSanitizer.fileDescriptor(for: epubURL))"
            )
        } catch {
            AppLogger.network.error("[Storyteller Offline] Audio extraction failed: \(error)")
            extractedCount = 0
        }

        let chapters = await buildChapters(epubURL: epubURL, audiobookDir: destinationDir, audioCount: extractedCount)
        if !chapters.isEmpty {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: chapters)
            if book.id != book.stableId {
                ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: chapters)
            }
        }

        _ = await MediaOverlayPlaybackService.shared.buildPersistentIndex(for: book, epubURL: epubURL)

        return Result(extractedAudioCount: extractedCount, chapters: chapters)
    }

    private static func extractAudioFiles(from epubURL: URL, into destinationDir: URL) async throws -> Int {
        let archive = try await Archive(url: epubURL, accessMode: .read)
        let allEntries = try await archive.entries()

        let audioEntries =
            allEntries
            .filter { entry in
                guard entry.type == .file else { return false }
                let pathLower = entry.path.lowercased()
                let ext = (pathLower as NSString).pathExtension
                guard !ext.isEmpty, AudiobookFormat.from(fileExtension: ext) != nil else { return false }

                return true
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        guard !audioEntries.isEmpty else { return 0 }

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let previousExtractions =
            ((try? FileManager.default.contentsOfDirectory(
                at: destinationDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).filter {
                $0.lastPathComponent.hasPrefix("chapter_")
                    && AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil
            }
        for fileURL in previousExtractions {
            try FileManager.default.removeItem(at: fileURL)
        }

        for (index, entry) in audioEntries.enumerated() {
            let ext = (entry.path as NSString).pathExtension.lowercased()
            let destURL = destinationDir.appendingPathComponent("chapter_\(index).\(ext)", isDirectory: false)
            _ = try await archive.extract(entry, to: destURL)
        }

        return audioEntries.count
    }

    private static func buildChapters(epubURL: URL, audiobookDir: URL, audioCount: Int) async -> [Chapter] {
        let localChapters = (try? await LocalEbookImporter.shared.extractChapters(from: epubURL)) ?? []
        let tocChapters: [Chapter] = localChapters.enumerated().map { index, chapter in
            Chapter(id: chapter.id, start: chapter.startTime, end: chapter.endTime, title: chapter.title, index: index)
        }

        if !tocChapters.isEmpty {
            let durationMap = await EPUB3SMILParser.parseChapterDurations(epubFileURL: epubURL)
            if let overlayChapters = EPUB3SMILParser.buildChaptersFromDurations(
                durationMap: durationMap,
                tocChapters: tocChapters
            ) {
                return overlayChapters
            }
        }

        guard audioCount > 0 else { return [] }
        var chapters: [Chapter] = []
        var cumulative: TimeInterval = 0
        let urls =
            (try? FileManager.default.contentsOfDirectory(at: audiobookDir, includingPropertiesForKeys: nil))?
            .filter {
                $0.lastPathComponent.hasPrefix("chapter_") && AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []

        for (index, fileURL) in urls.enumerated() {
            let asset = AVURLAsset(url: fileURL)
            let seconds: TimeInterval
            if let duration = try? await asset.load(.duration) {
                let value = CMTimeGetSeconds(duration)
                seconds = value.isFinite && value > 0 ? value : 0
            } else {
                seconds = 0
            }
            let start = cumulative
            cumulative += seconds
            chapters.append(
                Chapter(
                    id: "audio-\(index)",
                    start: start,
                    end: cumulative,
                    title: "Chapter \(index + 1)",
                    index: index
                )
            )
        }
        return chapters
    }
}
