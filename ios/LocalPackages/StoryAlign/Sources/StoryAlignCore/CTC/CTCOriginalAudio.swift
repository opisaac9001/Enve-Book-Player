@preconcurrency import AVFoundation
import Foundation
import Darwin
import ZIPFoundation

extension AudioFileProcessor {
    func processOriginalAudio(audioURLs: [URL], epub: EpubDocument) async throws -> AudioBook {
        try Task.checkCancellation()
        guard !audioURLs.isEmpty else { throw StoryAlignError("No audio files to process.") }
        let manager = FileManager.default
        var unpackedDirectory: URL?
        defer {
            if let unpackedDirectory { try? manager.removeItem(at: unpackedDirectory) }
        }
        let sources: [URL]
        if audioURLs[0].pathExtension.lowercased() == "zip" {
            let directory = session.request.sessionDir.appendingPathComponent("ctc-audio-\(UUID().uuidString)", isDirectory: true)
            unpackedDirectory = directory
            try await Self.unpackOriginalAudio(from: audioURLs[0], to: directory)
            sources = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { (Self.supportedExtensions + ["m4a"]).contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
        } else {
            sources = audioURLs
        }
        guard !sources.isEmpty else { throw StoryAlignError("The audiobook archive has no supported audio files.") }
        let destination = epub.opfURL.deletingLastPathComponent().appendingPathComponent(AssetPaths.audio, isDirectory: true)
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        progressTracker.updateProgress(for: .audio, event: .start, total: sources.count)
        var files: [AudioFile] = []
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw StoryAlignError("The audiobook has no readable audio track or duration.")
            }
            let formats = try await track.load(.formatDescriptions)
            let codecs = formats.map { CMFormatDescriptionGetMediaSubType($0) }
            let videos = try await asset.loadTracks(withMediaType: .video)
            let originalExtension = Self.originalAudioExtension(sourceExtension: source.pathExtension, codecs: codecs, hasVideo: !videos.isEmpty)
            let output = destination.appendingPathComponent(String(format: "%05d.%@", index + 1, originalExtension ?? "m4a"))
            if originalExtension != nil {
                try Self.copyOriginalAudio(from: source, to: output)
            } else {
                let wholeFile = AudioFile(startTmeInterval: 0, endTmeInterval: duration, filePath: output, index: 0)
                try await AvAudioLoader(session: session).extractAudio(from: source, using: wholeFile)
            }
            try Task.checkCancellation()
            let outputDuration: Double
            if originalExtension != nil {
                outputDuration = duration
            } else {
                outputDuration = try await AVURLAsset(url: output, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]).load(.duration).seconds
                guard outputDuration.isFinite, outputDuration > 0 else { throw StoryAlignError("Converted audiobook audio has no valid duration.") }
            }
            files.append(AudioFile(startTmeInterval: 0, endTmeInterval: outputDuration, filePath: output, index: index))
            progressTracker.updateProgress(for: .audio, increment: 1, item: source.lastPathComponent)
        }
        progressTracker.updateProgress(for: .audio, event: .end)
        return AudioBook(audioFiles: files)
    }

    static func unpackOriginalAudio(from source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let progress = Progress(totalUnitCount: 0)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try FileManager.default.unzipItem(at: source, to: destination, progress: progress)
                try Task.checkCancellation()
            } onCancel: {
                progress.cancel()
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    static func copyOriginalAudio(from source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { clonefile(sourcePath, $0, 0) }
        }
        if result == 0 {
            do { try Task.checkCancellation() }
            catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
            return
        }
        if errno == EEXIST { throw POSIXError(.EEXIST) }
        try copyAudioBytes(from: source, to: destination)
    }

    static func copyAudioBytes(from source: URL, to destination: URL) throws {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let descriptor = destination.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 4 * 1_024 * 1_024), !bytes.isEmpty else { break }
            try Task.checkCancellation()
            try output.write(contentsOf: bytes)
        }
        try Task.checkCancellation()
        try output.close()
        complete = true
    }

    static func originalAudioExtension(sourceExtension: String, codecs: [FourCharCode], hasVideo: Bool) -> String? {
        guard !hasVideo, !codecs.isEmpty else { return nil }
        let fileExtension = sourceExtension.lowercased()
        if fileExtension == "mp3", codecs.allSatisfy({ $0 == kAudioFormatMPEGLayer3 }) { return "mp3" }
        let mp4Codecs: Set<FourCharCode> = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2]
        if ["m4a", "m4b", "mp4"].contains(fileExtension), codecs.allSatisfy({ mp4Codecs.contains($0) }) { return "m4a" }
        return nil
    }
}
