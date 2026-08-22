import Foundation
import Logging

extension WebDAVProvider {

    static let videoExtensions: Set<String> = [
        "mkv", "avi", "mp4", "m4v", "mov", "wmv", "flv", "webm",
        "ts", "vob", "mpg", "mpeg", "3gp", "ogv", "divx", "rmvb",
    ]

    func isVideoOnlyFolder(entries: [RemoteFileEntry]) -> Bool {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return false }

        var hasVideo = false
        for file in files {
            if file.isAudioFile || file.isEbookFile { return false }
            let ext = (file.name as NSString).pathExtension.lowercased()
            if Self.videoExtensions.contains(ext) { hasVideo = true }
        }
        return hasVideo
    }

    func isLikelyVideoFolderName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if lower.range(of: #"^s(eason)?\s*\d+"#, options: .regularExpression) != nil { return true }

        let videoFolderNames: Set<String> = [
            "subs", "subtitles", "extras", "featurettes", "behind the scenes",
            "deleted scenes", "bonus", "sample", "trailers", "bdmv", "video_ts",
            "certificate", "interviews",
        ]
        if videoFolderNames.contains(lower) { return true }

        if lower.hasPrefix("subs") { return true }

        return false
    }

    static let selfContainedExtensions: Set<String> = ["m4b", "mp4"]

    func isSelfContainedFormat(_ entry: RemoteFileEntry) -> Bool {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        if Self.selfContainedExtensions.contains(ext) { return true }
        let pathExt = (entry.path as NSString).pathExtension.lowercased()
        return Self.selfContainedExtensions.contains(pathExt)
    }

    struct BookUnit {
        let folder: WebDAVBookFolder
        let audioFiles: [RemoteFileEntry]
        let isSingleFileSplit: Bool
    }

    func resolveBookUnits(
        from folders: [WebDAVBookFolder],
        server: WebDAVServerConfig,
        rootPath: String,
        parentsOfBookFolders: Set<String>
    ) -> [BookUnit] {
        var units: [BookUnit] = []

        for folder in folders {
            let isContainer = parentsOfBookFolders.contains(folder.path)

            let audio = folder.audioFiles
            let selfContained = audio.filter { isSelfContainedFormat($0) }
            let partFiles = audio.filter { !isSelfContainedFormat($0) }

            if isContainer {
                if !selfContained.isEmpty {
                    for file in selfContained {
                        units.append(BookUnit(folder: folder, audioFiles: [file], isSingleFileSplit: true))
                    }
                }
                if !partFiles.isEmpty {
                    units.append(BookUnit(folder: folder, audioFiles: partFiles, isSingleFileSplit: false))
                }
                if !audio.isEmpty {
                    AppLogger.network.info(
                        "Container folder grouped as \(selfContained.count) individual + \(partFiles.count) part-file set(s): \(folder.path)"
                    )
                }
            } else if selfContained.count > 1 && partFiles.isEmpty {
                for file in selfContained {
                    units.append(BookUnit(folder: folder, audioFiles: [file], isSingleFileSplit: true))
                }
                AppLogger.network.debug(
                    "Split \(selfContained.count) self-contained files folderDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: folder.path))"
                )
            } else if !selfContained.isEmpty && !partFiles.isEmpty {
                for file in selfContained {
                    units.append(BookUnit(folder: folder, audioFiles: [file], isSingleFileSplit: true))
                }
                units.append(BookUnit(folder: folder, audioFiles: partFiles, isSingleFileSplit: false))
                AppLogger.network.info(
                    "Mixed folder: \(selfContained.count) individual + \(partFiles.count) part-files as one book: \(folder.path)"
                )
            } else {
                units.append(BookUnit(folder: folder, audioFiles: audio, isSingleFileSplit: false))
            }
        }

        return units
    }

    func collapseDiscSubfolders(_ folders: [WebDAVBookFolder], rootPath: String) -> [WebDAVBookFolder] {
        let normalizedRoot = normalizedServerPath(rootPath)
        var childrenByParent: [String: [WebDAVBookFolder]] = [:]

        for folder in folders {
            let parentPath = normalizedServerPath((folder.path as NSString).deletingLastPathComponent)
            guard !parentPath.isEmpty, parentPath != folder.path else { continue }
            childrenByParent[parentPath, default: []].append(folder)
        }

        var consumedChildPaths = Set<String>()
        var mergedFolders: [WebDAVBookFolder] = []

        for (parentPath, children) in childrenByParent {
            guard parentPath != normalizedRoot else { continue }

            let discChildren = children.filter { isDiscOrPartFolderName(folderName(from: $0.path)) }
            guard !discChildren.isEmpty else { continue }

            let sortedDiscChildren = discChildren.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let mergedAudioFiles =
                sortedDiscChildren
                .flatMap { $0.audioFiles }
                .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let mergedEntries = sortedDiscChildren.flatMap { $0.entries }
            guard !mergedAudioFiles.isEmpty else { continue }

            let parentFolder = folders.first(where: { $0.path == parentPath })
            var finalAudioFiles = (parentFolder?.audioFiles ?? []) + mergedAudioFiles
            finalAudioFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let finalEntries = (parentFolder?.entries ?? []) + mergedEntries

            mergedFolders.append(
                WebDAVBookFolder(path: parentPath, audioFiles: finalAudioFiles, entries: finalEntries)
            )
            consumedChildPaths.formUnion(discChildren.map { $0.path })
            if parentFolder != nil {
                consumedChildPaths.insert(parentPath)
            }
            AppLogger.network.info(
                "Collapsed \(discChildren.count) disc/part subfolders into one book: \(parentPath) (\(finalAudioFiles.count) tracks)"
            )
        }

        if mergedFolders.isEmpty { return folders }

        var result = folders.filter { !consumedChildPaths.contains($0.path) }
        result.append(contentsOf: mergedFolders)
        return result
    }

    func isDiscOrPartFolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"(?i)^(disc|cd|disk|part)\s*\d+$"#, options: .regularExpression) != nil
            || trimmed.range(of: #"(?i)^(part)\s+(one|two|three|four|five|six|seven|eight|nine|ten)$"#, options: .regularExpression) != nil
    }

    func normalizedServerPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "/" }
        var result = trimmed
        if !result.hasPrefix("/") { result = "/" + result }
        if result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
