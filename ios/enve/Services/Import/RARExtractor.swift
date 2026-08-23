import Foundation
import Logging

final class RARExtractor {

    struct ExtractionSelection {
        let filePaths: Set<String>
        let folderNames: Set<String>
        let fileBaseNames: Set<String>

        var isEmpty: Bool {
            filePaths.isEmpty && folderNames.isEmpty && fileBaseNames.isEmpty
        }
    }

    enum RARError: LocalizedError {
        case notRARFile
        case corruptHeader
        case unsupportedCompression(String)
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .notRARFile: return "Not a valid RAR archive"
            case .corruptHeader: return "RAR archive has corrupt headers"
            case .unsupportedCompression(let detail): return "Unsupported RAR compression: \(detail)"
            case .ioError(let detail): return "I/O error: \(detail)"
            }
        }
    }

    struct RAREntry {
        let filename: String
        let uncompressedSize: UInt64
        let compressedSize: UInt64
        let isDirectory: Bool
        let isStored: Bool
        let dataOffset: UInt64
    }

    static let rar5Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]
    static let rar4Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]

    static func isRARFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let header = [UInt8](handle.readData(ofLength: 8))
        return header.starts(with: rar5Signature) || header.starts(with: rar4Signature)
    }

    static func extractAudioFiles(
        from rarURL: URL,
        to destinationDir: URL,
        selection: ExtractionSelection? = nil,
        removeArchiveAfterExtraction: Bool = true
    ) throws -> [URL] {
        let data = try Data(contentsOf: rarURL, options: .mappedIfSafe)
        let bytes = [UInt8](data)

        let isRAR5 = bytes.count >= 8 && [UInt8](bytes[0..<8]) == rar5Signature
        let isRAR4 = !isRAR5 && bytes.count >= 7 && [UInt8](bytes[0..<7]) == rar4Signature

        guard isRAR5 || isRAR4 else {
            throw RARError.notRARFile
        }

        let entries: [RAREntry]
        if isRAR5 {
            entries = try parseRAR5Entries(bytes)
        } else {
            entries = try parseRAR4Entries(bytes)
        }

        let audioExtensions: Set<String> = ["mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav", "wma"]
        let companionExtensions: Set<String> = ["json", "jpg", "jpeg", "png", "webp", "cue", "txt", "rtf", "nfo"]

        let audioEntries = entries.filter { entry in
            guard !entry.isDirectory else { return false }
            let ext = (entry.filename as NSString).pathExtension.lowercased()
            guard audioExtensions.contains(ext) else { return false }
            return matchesSelection(entry: entry, selection: selection, isCompanion: false)
        }.sorted { a, b in
            a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }

        let companionEntries = entries.filter { entry in
            guard !entry.isDirectory else { return false }
            let ext = (entry.filename as NSString).pathExtension.lowercased()
            guard companionExtensions.contains(ext) else { return false }
            return matchesSelection(entry: entry, selection: selection, isCompanion: true)
        }.sorted { a, b in
            a.filename.localizedStandardCompare(b.filename) == .orderedAscending
        }

        guard !audioEntries.isEmpty else {
            throw RARError.ioError("RAR archive contains no audio files")
        }

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var extractedURLs: [URL] = []
        var audioAliasMap: [String: URL] = [:]
        for (index, entry) in audioEntries.enumerated() {
            let ext = (entry.filename as NSString).pathExtension.lowercased()
            let destURL = destinationDir.appendingPathComponent("chapter_\(index).\(ext)")
            try? FileManager.default.removeItem(at: destURL)

            guard try extractEntry(entry, from: bytes, to: destURL) else { continue }
            extractedURLs.append(destURL)
            audioAliasMap[(entry.filename as NSString).deletingPathExtension.lowercased()] = destURL.deletingPathExtension()
        }

        for entry in companionEntries {
            let fileName = (entry.filename as NSString).lastPathComponent
            let destURL = destinationDir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destURL)

            guard try extractEntry(entry, from: bytes, to: destURL) else { continue }

            let companionBase = baseNameForCompanion(fileName)
            if let audioAliasBase = audioAliasMap[companionBase] {
                let aliasURL = aliasedCompanionURL(for: fileName, baseURL: audioAliasBase)
                if aliasURL.path != destURL.path {
                    try? FileManager.default.removeItem(at: aliasURL)
                    try? FileManager.default.copyItem(at: destURL, to: aliasURL)
                }
            }
        }

        if removeArchiveAfterExtraction {
            try? FileManager.default.removeItem(at: rarURL)
        }

        if extractedURLs.isEmpty {
            throw RARError.ioError("Could not extract any audio files from RAR archive")
        }

        return extractedURLs
    }

    private static func extractEntry(_ entry: RAREntry, from bytes: [UInt8], to destinationURL: URL) throws -> Bool {
        if entry.isStored {
            let start = Int(entry.dataOffset)
            let end = start + Int(entry.compressedSize)
            guard end <= bytes.count else {
                AppLogger.network.warning(
                    "RAR entryId=\(DiagnosticLogSanitizer.identifier(for: entry.filename)) extends beyond file bounds"
                )
                return false
            }
            let fileData = Data(bytes[start..<end])
            try fileData.write(to: destinationURL)
            AppLogger.network.debug(
                "Extracted stored RAR entryId=\(DiagnosticLogSanitizer.identifier(for: entry.filename)) bytes=\(fileData.count)"
            )
            return true
        }

        AppLogger.network.debug(
            "RAR entryId=\(DiagnosticLogSanitizer.identifier(for: entry.filename)) is compressed (size: \(entry.compressedSize) -> \(entry.uncompressedSize))"
        )
        let start = Int(entry.dataOffset)
        let end = start + Int(entry.compressedSize)
        guard end <= bytes.count else {
            AppLogger.network.warning(
                "Compressed RAR entryId=\(DiagnosticLogSanitizer.identifier(for: entry.filename)) extends beyond file bounds"
            )
            return false
        }
        let compressedData = [UInt8](bytes[start..<end])
        do {
            let decompressed = try decompressRARData(compressedData, uncompressedSize: Int(entry.uncompressedSize))
            try Data(decompressed).write(to: destinationURL)
            AppLogger.network.debug(
                "Decompressed RAR entryId=\(DiagnosticLogSanitizer.identifier(for: entry.filename)) bytes=\(decompressed.count)"
            )
            return true
        } catch {
            AppLogger.network.error(
                "Cannot decompress RAR entryId=\(DiagnosticLogSanitizer.identifier(for: entry.filename)): \(error.localizedDescription)"
            )
            return false
        }
    }

    private static func baseNameForCompanion(_ fileName: String) -> String {
        let lowercased = fileName.lowercased()
        let knownSuffixes = [".metadata.json", ".chapters.json", ".json", ".jpg", ".jpeg", ".png", ".webp", ".cue", ".txt", ".rtf", ".nfo"]

        for suffix in knownSuffixes where lowercased.hasSuffix(suffix) {
            return String(lowercased.dropLast(suffix.count))
        }

        return (lowercased as NSString).deletingPathExtension
    }

    private static func matchesSelection(entry: RAREntry, selection: ExtractionSelection?, isCompanion: Bool) -> Bool {
        guard let selection, !selection.isEmpty else { return true }

        let normalizedPath = normalizeArchivePath(entry.filename)
        let lastPathComponent = (normalizedPath as NSString).lastPathComponent
        let folderName = folderNameForArchivePath(normalizedPath)
        let baseName =
            isCompanion
            ? baseNameForCompanion(lastPathComponent)
            : ((lastPathComponent as NSString).deletingPathExtension.lowercased())

        if selection.filePaths.contains(normalizedPath) { return true }
        if let folderName, selection.folderNames.contains(folderName) { return true }
        if selection.fileBaseNames.contains(baseName) { return true }
        return false
    }

    private static func normalizeArchivePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private static func folderNameForArchivePath(_ path: String) -> String? {
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != "." else { return nil }
        return (directory as NSString).lastPathComponent.lowercased()
    }

    private static func aliasedCompanionURL(for originalFileName: String, baseURL: URL) -> URL {
        let lowercased = originalFileName.lowercased()
        if lowercased.hasSuffix(".metadata.json") {
            return URL(fileURLWithPath: baseURL.path + ".metadata.json")
        }
        if lowercased.hasSuffix(".chapters.json") {
            return URL(fileURLWithPath: baseURL.path + ".chapters.json")
        }
        let ext = (originalFileName as NSString).pathExtension
        return URL(fileURLWithPath: baseURL.path + ".\(ext)")
    }

    private static func parseRAR5Entries(_ bytes: [UInt8]) throws -> [RAREntry] {
        var entries: [RAREntry] = []
        var pos = 8

        while pos < bytes.count - 7 {
            guard pos + 4 <= bytes.count else { break }
            pos += 4

            let (headerSize, hsLen) = readVInt(bytes, offset: pos)
            guard hsLen > 0 else { break }
            pos += hsLen

            let headerEnd = pos + Int(headerSize)
            guard headerEnd <= bytes.count else { break }

            let (headerType, htLen) = readVInt(bytes, offset: pos)
            guard htLen > 0 else { break }
            pos += htLen

            let (headerFlags, hfLen) = readVInt(bytes, offset: pos)
            guard hfLen > 0 else { break }
            pos += hfLen

            let hasExtraArea = (headerFlags & 0x01) != 0
            let hasDataArea = (headerFlags & 0x02) != 0

            if hasExtraArea {
                let (_, easLen) = readVInt(bytes, offset: pos)
                guard easLen > 0 else { break }
                pos += easLen
            }

            var dataAreaSize: UInt64 = 0
            if hasDataArea {
                let (das, dasLen) = readVInt(bytes, offset: pos)
                guard dasLen > 0 else { break }
                pos += dasLen
                dataAreaSize = das
            }

            if headerType == 2 {
                let (fileFlags, ffLen) = readVInt(bytes, offset: pos)
                guard ffLen > 0 else { break }
                var fPos = pos + ffLen

                let (unpackedSize, usLen) = readVInt(bytes, offset: fPos)
                guard usLen > 0 else { break }
                fPos += usLen

                let (_, attrLen) = readVInt(bytes, offset: fPos)
                guard attrLen > 0 else { break }
                fPos += attrLen

                if (fileFlags & 0x02) != 0 {
                    fPos += 4
                }

                if (fileFlags & 0x04) != 0 {
                    fPos += 4
                }

                let (compressionInfo, ciLen) = readVInt(bytes, offset: fPos)
                guard ciLen > 0 else { break }
                fPos += ciLen

                let algorithm = compressionInfo & 0x3F
                let isStored = (algorithm == 0)
                let isDirectory = (fileFlags & 0x01) != 0

                let (_, osLen) = readVInt(bytes, offset: fPos)
                guard osLen > 0 else { break }
                fPos += osLen

                let (nameLength, nlLen) = readVInt(bytes, offset: fPos)
                guard nlLen > 0 else { break }
                fPos += nlLen

                let nameEnd = fPos + Int(nameLength)
                guard nameEnd <= bytes.count else { break }
                let nameBytes = [UInt8](bytes[fPos..<nameEnd])
                let filename = String(bytes: nameBytes, encoding: .utf8) ?? "unknown"

                let dataOffset = UInt64(headerEnd)

                entries.append(
                    RAREntry(
                        filename: filename,
                        uncompressedSize: unpackedSize,
                        compressedSize: dataAreaSize,
                        isDirectory: isDirectory,
                        isStored: isStored,
                        dataOffset: dataOffset
                    )
                )
            }

            if headerType == 5 {
                break
            }

            pos = headerEnd + Int(dataAreaSize)
        }

        return entries
    }

    private static func parseRAR4Entries(_ bytes: [UInt8]) throws -> [RAREntry] {
        var entries: [RAREntry] = []
        var pos = 7

        while pos < bytes.count - 7 {
            guard pos + 7 <= bytes.count else { break }

            pos += 2

            let headType = bytes[pos]
            pos += 1

            let headFlags = UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            pos += 2

            let headSize = UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
            pos += 2

            let headerStart = pos - 7
            guard headSize >= 7 else { break }

            if headType == 0x74 {
                guard pos + 21 <= bytes.count else { break }

                let packSizeLo = readUInt32LE(bytes, offset: pos)
                pos += 4

                let unpSizeLo = readUInt32LE(bytes, offset: pos)
                pos += 4

                pos += 1

                pos += 4

                pos += 4

                pos += 1

                let method = bytes[pos]
                pos += 1

                let nameSize = UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
                pos += 2

                pos += 4

                var packSize = UInt64(packSizeLo)
                var unpSize = UInt64(unpSizeLo)

                if (headFlags & 0x0100) != 0 {
                    guard pos + 8 <= bytes.count else { break }
                    let highPack = UInt64(readUInt32LE(bytes, offset: pos))
                    pos += 4
                    let highUnp = UInt64(readUInt32LE(bytes, offset: pos))
                    pos += 4
                    packSize |= (highPack << 32)
                    unpSize |= (highUnp << 32)
                }

                guard pos + Int(nameSize) <= bytes.count else { break }
                let nameBytes = [UInt8](bytes[pos..<(pos + Int(nameSize))])
                let filename =
                    String(bytes: nameBytes, encoding: .utf8)
                    ?? String(bytes: nameBytes, encoding: .ascii)
                    ?? "unknown"
                pos += Int(nameSize)

                let isDirectory = (headFlags & 0x00E0) == 0x00E0
                let isStored = (method == 0x30)
                let dataOffset = UInt64(headerStart + Int(headSize))

                entries.append(
                    RAREntry(
                        filename: filename,
                        uncompressedSize: unpSize,
                        compressedSize: packSize,
                        isDirectory: isDirectory,
                        isStored: isStored,
                        dataOffset: dataOffset
                    )
                )

                pos = headerStart + Int(headSize) + Int(packSize)
            } else {
                var addSize: UInt64 = 0
                if (headFlags & 0x8000) != 0 {
                    guard pos <= bytes.count - 4 else { break }
                    addSize = UInt64(readUInt32LE(bytes, offset: pos))
                }
                pos = headerStart + Int(headSize) + Int(addSize)
            }

            if headType == 0x7B {
                break
            }
        }

        return entries
    }

    private static func decompressRARData(_ compressed: [UInt8], uncompressedSize: Int) throws -> [UInt8] {
        throw RARError.unsupportedCompression(
            "RAR compression detected. Add libarchive-for-swift package for full RAR decompression support."
        )
    }

    private static func readVInt(_ bytes: [UInt8], offset: Int) -> (UInt64, Int) {
        var result: UInt64 = 0
        var shift = 0
        var pos = offset

        for i in 0..<10 {
            guard pos < bytes.count else { return (0, 0) }
            let b = bytes[pos]
            pos += 1
            result |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 {
                return (result, i + 1)
            }
            shift += 7
        }
        return (0, 0)
    }

    private static func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}
