import Foundation
import Logging
import Zip

extension PlaybackManager {
    static func downloadedTracks(for book: Book, files: [URL]) -> [AudioTrackInfo] {
        if files.count == 1, let url = files.first {
            return [AudioTrackInfo(index: 0, startOffset: 0, duration: book.duration ?? 0,
                                   contentUrl: url.absoluteString, mimeType: mimeType(forFileExtension: url.pathExtension))]
        }
        let metadata = (book.audioTracks ?? []).sorted {
            $0.startOffset == $1.startOffset ? $0.index < $1.index : $0.startOffset < $1.startOffset
        }
        let fallback = book.duration.flatMap { $0 > 0 ? $0 / Double(files.count) : nil } ?? 3600
        var offset: TimeInterval = 0
        return files.enumerated().map { index, url in
            let duration = index < metadata.count && metadata[index].duration > 0 ? metadata[index].duration : fallback
            defer { offset += duration }
            return AudioTrackInfo(index: index, startOffset: offset, duration: duration,
                                  contentUrl: url.absoluteString, mimeType: mimeType(forFileExtension: url.pathExtension))
        }
    }

    func buildLocalTrackInfos(from book: Book) -> [AudioTrackInfo]? {
        guard let tracks = book.audioTracks, !tracks.isEmpty else { return nil }

        let sortedTracks = tracks.sorted { lhs, rhs in
            if lhs.index == rhs.index {
                return lhs.startOffset < rhs.startOffset
            }
            return lhs.index < rhs.index
        }

        var result: [AudioTrackInfo] = []
        for track in sortedTracks {
            guard let trackPath = track.filePath else { continue }
            let resolvedURL = Self.resolveLocalPath(trackPath)
            guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
                AppLogger.player.warning(
                    "Track file not found: \(DiagnosticLogSanitizer.fileDescriptor(for: resolvedURL))"
                )
                continue
            }

            result.append(
                AudioTrackInfo(
                    index: track.index,
                    startOffset: track.startOffset,
                    duration: track.duration,
                    contentUrl: resolvedURL.absoluteString,
                    mimeType: Self.mimeType(forFileExtension: resolvedURL.pathExtension)
                )
            )
        }

        return result.isEmpty ? nil : result
    }

    static func resolveLocalPath(_ storedPath: String) -> URL {
        if FileManager.default.fileExists(atPath: storedPath) {
            return URL(fileURLWithPath: storedPath)
        }

        let markers = ["/Documents/", "/Documents"]
        for marker in markers {
            if let range = storedPath.range(of: marker) {
                let relativePart = String(storedPath[range.upperBound...])
                if !relativePart.isEmpty {
                    let resolved = URL.documentsDirectory.appendingPathComponent(relativePart)
                    if FileManager.default.fileExists(atPath: resolved.path) {
                        return resolved
                    }
                }
            }
        }

        return URL(fileURLWithPath: storedPath)
    }

    static func mimeType(forFileExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4b", "m4a", "mp4":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        case "wav":
            return "audio/wav"
        default:
            return "audio/mpeg"
        }
    }

    static func correctFileExtensionIfNeeded(for fileURL: URL) -> URL? {
        guard let detectedExt = UnifiedDownloadService.detectExtensionFromMagicBytes(at: fileURL) else {
            return nil
        }
        let currentExt = fileURL.pathExtension.lowercased()
        guard detectedExt != currentExt else { return nil }

        AppLogger.player.info("Format mismatch: file has .\(currentExt) extension but content is .\(detectedExt)")
        let correctedURL = fileURL.deletingPathExtension().appendingPathExtension(detectedExt)
        do {
            if FileManager.default.fileExists(atPath: correctedURL.path) {
                try FileManager.default.removeItem(at: correctedURL)
            }
            try FileManager.default.moveItem(at: fileURL, to: correctedURL)
            return correctedURL
        } catch {
            AppLogger.player.error("Failed to rename file: \(error.localizedDescription)")
            return nil
        }
    }

    static func logLocalFileInfo(_ url: URL) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int64
        {
            AppLogger.player.info("File size: \(size) bytes (\(size / 1024)KB)")
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        if let header = try? handle.read(upToCount: 16) {
            let hex = header.map { String(format: "%02X", $0) }.joined(separator: " ")
            AppLogger.player.info("File header bytes: \(hex)")
        }
    }

    func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 4)
        return header == Data([0x50, 0x4B, 0x03, 0x04])
    }

    func extractZipAndRebuild(at zipURL: URL, destinationDir: URL) throws {
        let unzipDir = destinationDir.appendingPathComponent("temp_unzip")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        try Zip.unzipFile(zipURL, destination: unzipDir, overwrite: true, password: nil)

        let audioExtensions = Set(["m4b", "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"])
        var extractedCount = 0
        let enumerator = FileManager.default.enumerator(at: unzipDir, includingPropertiesForKeys: nil)

        while let itemURL = enumerator?.nextObject() as? URL {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir), !isDir.boolValue {
                let ext = itemURL.pathExtension.lowercased()
                if audioExtensions.contains(ext) {
                    let outputURL = destinationDir.appendingPathComponent("chapter_\(extractedCount).\(ext)")
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.moveItem(at: itemURL, to: outputURL)
                    extractedCount += 1
                }
            }
        }

        try? FileManager.default.removeItem(at: unzipDir)
        try? FileManager.default.removeItem(at: zipURL)
        if extractedCount == 0 {
            throw PlaybackError.downloadedFileEmpty(path: zipURL.path)
        }
    }
}
