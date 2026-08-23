import AVFoundation
import CryptoKit
import Foundation
import Logging

extension LocalLibraryService {
    nonisolated func groupFilesIntoBooks(
        files: [(name: String, url: URL, relativePath: String)],
        forcedStandalonePaths: Set<String> = []
    ) -> [MultiFileAudiobook] {
        var folderGroups: [String: [(name: String, url: URL, relativePath: String)]] = [:]

        for file in files {
            let folderPath = file.url.deletingLastPathComponent().path
            folderGroups[folderPath, default: []].append(file)
        }

        var audiobooks: [MultiFileAudiobook] = []

        for (folderPath, folderFiles) in folderGroups {
            let groups = AudiobookFileGrouping.groups(
                folderFiles,
                name: { $0.name },
                bookEvidence: { file in
                    let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .map(Int64.init) ?? 0
                    return size >= AudiobookFileGrouping.minimumStandaloneBookSize
                },
                forcedStandalone: { file in
                    forcedStandalonePaths.contains(file.url.standardizedFileURL.path)
                }
            )
            let allowsFolderMetadata = groups.count == 1
            for group in groups {
                let isSingleFile = group.count == 1
                let sortedFiles = sortFilesByTrackOrder(group)
                audiobooks.append(
                    MultiFileAudiobook(
                        folderPath: folderPath,
                        folderName: isSingleFile
                            ? (group[0].name as NSString).deletingPathExtension
                            : allowsFolderMetadata
                                ? URL(fileURLWithPath: folderPath).lastPathComponent
                                : AudiobookFileGrouping.inferredTitle(for: group[0].name),
                        files: sortedFiles,
                        isSingleFile: isSingleFile,
                        allowsFolderMetadata: allowsFolderMetadata
                    )
                )
            }
        }

        return audiobooks
    }

    nonisolated func sortFilesByTrackOrder(
        _ files: [(name: String, url: URL, relativePath: String)]
    ) -> [(name: String, url: URL, relativePath: String, trackNumber: Int?)] {
        AudiobookFileGrouping.sorted(files, name: \.name).map { file in
            let trackNumber = extractTrackNumber(from: file.name)
            return (name: file.name, url: file.url, relativePath: file.relativePath, trackNumber: trackNumber)
        }
    }

    nonisolated func extractTrackNumber(from filename: String) -> Int? {
        let nameWithoutExtension = (filename as NSString).deletingPathExtension

        let patterns = [
            "^(\\d+)",
            "^[^\\d]*(\\d+)",
            "(?:track|part|chapter|disc|cd)[\\s_-]*(\\d+)",
            "(\\d+)\\s*$",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(
                    in: nameWithoutExtension,
                    options: [],
                    range: NSRange(nameWithoutExtension.startIndex..., in: nameWithoutExtension)
                ),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: nameWithoutExtension),
                let number = Int(nameWithoutExtension[range])
            {
                return number
            }
        }

        return nil
    }

    func extractMultiFileAudiobook(
        audiobook: MultiFileAudiobook,
        libraryId: String
    ) async throws -> LocalBookFile {
        guard !audiobook.files.isEmpty else {
            throw LocalLibraryError.metadataExtractionFailed
        }

        let primaryFile = audiobook.files[0]
        var primaryMetadata: LocalBookMetadata?
        var totalDuration: TimeInterval = 0
        var totalSize: Int64 = 0
        var audioFiles: [AudioFileInfo] = []

        var usedSidecarPath: String?
        for candidate in sidecarCandidatePaths(
            forAudioFilePath: primaryFile.url.path,
            includeFolderMetadata: audiobook.allowsFolderMetadata
        ) where fileManager.fileExists(atPath: candidate) {
            if let sidecar = try? await loadSidecarMetadata(from: candidate) {
                primaryMetadata = sidecar
                usedSidecarPath = candidate
                AppLogger.network.info("Loaded metadata sidecar for \(primaryFile.name)")
                break
            }
        }

        for (index, file) in audiobook.files.enumerated() {
            let fileAttributes = try? fileManager.attributesOfItem(atPath: file.url.path)
            let fileSize = (fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            let fileExtension = file.url.pathExtension.lowercased()
            totalSize += fileSize

            var fileDuration: TimeInterval = 0
            var fileTitle: String? = nil

            do {
                let asset = AVURLAsset(url: file.url)
                fileDuration = try await asset.load(.duration).seconds

                let commonMetadata = try? await asset.load(.commonMetadata)
                if let titleItem = commonMetadata?.first(where: { $0.commonKey == .commonKeyTitle }),
                    let title = try? await titleItem.load(.stringValue)
                {
                    fileTitle = title
                }

                if index == 0 && primaryMetadata == nil {
                    primaryMetadata = try? await metadataExtractor.extractMetadata(from: file.url.path)
                }
            } catch {
                AppLogger.network.error("Could not load duration for \(file.name): \(error)")
            }

            if fileDuration <= 0 {
                if let extracted = try? await metadataExtractor.extractMetadata(from: file.url.path) {
                    if let extractedDuration = extracted.duration, extractedDuration > 0 {
                        fileDuration = extractedDuration
                    }
                    if fileTitle == nil || fileTitle?.isEmpty == true {
                        fileTitle = extracted.title
                    }
                }
            }

            audioFiles.append(
                AudioFileInfo(
                    id: "\(libraryId):\(deterministicHash(canonicalLocalPath(file.url.path)))",
                    fileName: file.name,
                    filePath: file.url.path,
                    fileSize: fileSize,
                    format: fileExtension,
                    duration: fileDuration,
                    trackNumber: file.trackNumber,
                    title: fileTitle ?? file.name
                )
            )

            totalDuration += fileDuration
        }

        let combinedHash = calculateCombinedHash(for: audioFiles)

        let stableId = "\(libraryId):\(combinedHash ?? deterministicHash(canonicalLocalPath(audiobook.folderPath)))"

        var metadata = primaryMetadata ?? LocalBookMetadata(title: audiobook.folderName)

        if metadata.coverImagePath?.isEmpty != false {
            metadata.coverImagePath = companionCoverPath(
                forAudioFilePath: primaryFile.url.path,
                includeFolderCover: audiobook.allowsFolderMetadata
            )
        }

        if totalDuration > 0 {
            metadata.duration = totalDuration
        } else if (metadata.duration ?? 0) <= 0 {
            let existingChapterTotal = metadata.chapters?.last?.endTime ?? 0
            if existingChapterTotal > 0 {
                metadata.duration = existingChapterTotal
            }
        }

        let hasValidChapters =
            metadata.chapters?.contains(where: { chapter in
                chapter.duration > 0 && chapter.endTime > chapter.startTime
            }) ?? false

        if !hasValidChapters {
            var chapters: [LocalChapter] = []
            var cumulativeOffset: TimeInterval = 0
            let fallbackPerFileDuration: TimeInterval = {
                let total = metadata.duration ?? totalDuration
                guard total > 0, !audioFiles.isEmpty else { return 0 }
                return total / Double(audioFiles.count)
            }()

            for (index, file) in audioFiles.enumerated() {
                let rawDuration = file.duration ?? 0
                let duration = rawDuration > 0 ? rawDuration : fallbackPerFileDuration
                let chapterTitle = file.title ?? (file.fileName as NSString).deletingPathExtension

                let chapter = LocalChapter(
                    id: "ch_\(index)",
                    title: chapterTitle,
                    startTime: cumulativeOffset,
                    endTime: cumulativeOffset + duration,
                    duration: duration
                )
                chapters.append(chapter)
                cumulativeOffset += duration
            }

            if !chapters.isEmpty {
                metadata.chapters = chapters
                if cumulativeOffset > 0 {
                    metadata.duration = max(metadata.duration ?? 0, cumulativeOffset)
                }
                AppLogger.network.info("Auto-generated/normalized \(chapters.count) chapters from multi-file audiobook")
            }
        }

        return LocalBookFile(
            id: stableId,
            fileName: primaryFile.name,
            filePath: primaryFile.url.path,
            relativePath: primaryFile.relativePath,
            fileSize: totalSize,
            format: primaryFile.url.pathExtension.lowercased(),
            fileHash: combinedHash,
            metadata: metadata,
            sidecarPath: usedSidecarPath,
            extractedAt: Date(),
            audioFiles: audioFiles
        )
    }

    func calculateCombinedHash(for audioFiles: [AudioFileInfo]) -> String? {
        guard !audioFiles.isEmpty else { return nil }

        let sortedFiles = audioFiles.sorted { file1, file2 in
            if let t1 = file1.trackNumber, let t2 = file2.trackNumber {
                return t1 < t2
            }
            return file1.fileName < file2.fileName
        }

        var combinedSignature = ""
        for file in sortedFiles {
            let canonicalPath = canonicalLocalPath(file.filePath)
            combinedSignature += "\(file.fileSize):\(file.fileName):\(canonicalPath):"
        }

        guard let data = combinedSignature.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func deterministicHash(_ value: String) -> String {
        guard let data = value.data(using: .utf8) else { return UUID().uuidString.replacingOccurrences(of: "-", with: "") }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func canonicalLocalPath(_ path: String) -> String {
        if let range = path.range(of: "/Documents/") {
            return String(path[range.lowerBound...])
        }
        return path
    }
}

struct MultiFileAudiobook {
    let folderPath: String
    let folderName: String
    let files: [(name: String, url: URL, relativePath: String, trackNumber: Int?)]
    let isSingleFile: Bool
    let allowsFolderMetadata: Bool

    nonisolated var fileCount: Int { files.count }
}
