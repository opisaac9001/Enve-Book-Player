import Foundation
import Zip

enum DownloadArchiveFileSystem {
    nonisolated struct StagedArchive: Sendable {
        let url: URL
        fileprivate let directory: URL

        func discard() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated static func stageForDistribution(at archiveURL: URL) throws -> StagedArchive {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("download-archive-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let stagedURL = directory.appendingPathComponent(archiveURL.lastPathComponent)
            try fileManager.moveItem(at: archiveURL, to: stagedURL)
            return StagedArchive(url: stagedURL, directory: directory)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    nonisolated static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 4)
        return header.count >= 4
            && header[0] == 0x50
            && header[1] == 0x4B
            && header[2] == 0x03
            && header[3] == 0x04
    }

    nonisolated static func isRarFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let bytes = [UInt8](handle.readData(ofLength: 8))
        guard bytes.count >= 7 else { return false }
        let commonPrefix =
            bytes[0] == 0x52 && bytes[1] == 0x61
            && bytes[2] == 0x72 && bytes[3] == 0x21
            && bytes[4] == 0x1A && bytes[5] == 0x07
        guard commonPrefix else { return false }
        if bytes[6] == 0x00 { return true }
        return bytes.count >= 8 && bytes[6] == 0x01 && bytes[7] == 0x00
    }

    @discardableResult
    nonisolated static func extractZip(at archiveURL: URL, to destinationDirectory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let stagingDirectory = destinationDirectory.appendingPathComponent("archive-staging", isDirectory: true)
        try? fileManager.removeItem(at: stagingDirectory)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: archiveURL)
        }

        try Zip.unzipFile(archiveURL, destination: stagingDirectory, overwrite: true, password: nil)
        let enumerator = fileManager.enumerator(at: stagingDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        var audioFiles: [URL] = []
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory != true,
                AudiobookFormat.from(fileExtension: item.pathExtension.lowercased()) != nil
            else { continue }
            audioFiles.append(item)
        }
        audioFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var extracted: [URL] = []
        for (index, item) in audioFiles.enumerated() {
            let output = DownloadDestinationFileSystem.chapterFile(
                in: destinationDirectory,
                index: index,
                fileExtension: item.pathExtension.lowercased()
            )
            try DownloadDestinationFileSystem.replaceItem(at: output, with: item)
            extracted.append(output)
        }
        guard !extracted.isEmpty else {
            throw NSError(
                domain: "DownloadArchiveFileSystem",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ZIP archive contains no supported audio files"]
            )
        }
        return extracted
    }

    @discardableResult
    static func extractRar(
        at archiveURL: URL,
        to destinationDirectory: URL,
        selection: RARExtractor.ExtractionSelection? = nil
    ) throws -> [URL] {
        let extracted = try RARExtractor.extractAudioFiles(
            from: archiveURL,
            to: destinationDirectory,
            selection: selection
        )
        guard !extracted.isEmpty else {
            throw NSError(
                domain: "DownloadArchiveFileSystem",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "RAR archive contains no extractable audio files"]
            )
        }
        return extracted
    }
}
