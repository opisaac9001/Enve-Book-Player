import Foundation
import Logging
import ReadiumShared
import ReadiumZIPFoundation

enum OverlayGranularity: String, Sendable, Codable {
    case large
    case small
    case unspecified
}

struct TextFragment: Sendable, Codable {
    let textStart: String
    let textEnd: String?
    let prefix: String?
    let suffix: String?

    static func parse(_ directive: String) -> TextFragment? {
        var parts = directive.components(separatedBy: ",")
        guard !parts.isEmpty else { return nil }

        var rawPrefix: String?
        var rawSuffix: String?

        if let first = parts.first, first.hasSuffix("-") {
            rawPrefix = String(first.dropLast())
            parts.removeFirst()
        }

        if let last = parts.last, last.hasPrefix("-") {
            rawSuffix = String(last.dropFirst())
            parts.removeLast()
        }

        guard let rawTextStart = parts.first, !rawTextStart.isEmpty else { return nil }
        let decode: (String) -> String = { $0.removingPercentEncoding ?? $0 }
        let textStart = decode(rawTextStart)
        let textEnd = parts.count > 1 && !parts[1].isEmpty ? decode(parts[1]) : nil
        let prefix = rawPrefix.map(decode)
        let suffix = rawSuffix.map(decode)

        return TextFragment(textStart: textStart, textEnd: textEnd, prefix: prefix, suffix: suffix)
    }
}

struct AudioOverlayClip: Sendable, Codable {
    let fragmentId: String
    let textHref: String
    let audioSrc: String
    let clipBegin: TimeInterval
    let clipEnd: TimeInterval
    let granularity: OverlayGranularity
    let parentGroupIndex: Int?
    let textFragment: TextFragment?
    let skippableRole: String?

    var duration: TimeInterval { clipEnd - clipBegin }
    var isTextFragment: Bool { textFragment != nil }

    init(
        fragmentId: String,
        textHref: String,
        audioSrc: String,
        clipBegin: TimeInterval,
        clipEnd: TimeInterval,
        granularity: OverlayGranularity = .unspecified,
        parentGroupIndex: Int? = nil,
        textFragment: TextFragment? = nil,
        skippableRole: String? = nil
    ) {
        self.fragmentId = fragmentId
        self.textHref = textHref
        self.audioSrc = audioSrc
        self.clipBegin = clipBegin
        self.clipEnd = clipEnd
        self.granularity = granularity
        self.parentGroupIndex = parentGroupIndex
        self.textFragment = textFragment
        self.skippableRole = skippableRole
    }
}

enum EPUB3SMILParser {

    enum ParseError: Error, LocalizedError {
        case noSMILResources
        case smilReadFailed(String)
        case xmlParseFailed(String)
        case audioExtractionFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSMILResources: return "No SMIL media overlay resources found in this EPUB."
            case .smilReadFailed(let d): return "Failed to read SMIL resource: \(d)"
            case .xmlParseFailed(let d): return "Failed to parse SMIL XML: \(d)"
            case .audioExtractionFailed(let d): return "Audio extraction failed: \(d)"
            }
        }
    }

    static func resolvePathDots(_ path: String) -> String {
        var resolved: [String] = []
        for component in path.components(separatedBy: "/") {
            switch component {
            case "..":
                if !resolved.isEmpty { resolved.removeLast() }
            case ".", "":
                break
            default:
                resolved.append(component)
            }
        }
        return resolved.joined(separator: "/")
    }

    private static func normalizeHref(_ href: String) -> String {
        href.hasPrefix("/") ? String(href.dropFirst()) : href
    }

    static func localAudioFilename(for src: String) -> String {
        resolvePathDots(src).replacingOccurrences(of: "/", with: "_")
    }

    static func localAudioURL(for src: String, in audioDir: URL) -> URL {
        audioDir.appendingPathComponent(localAudioFilename(for: src))
    }

    @MainActor private static var clipCache: (key: String, clips: [AudioOverlayClip])?
    @MainActor private static var clipParseTasks: [String: Task<[AudioOverlayClip], Error>] = [:]

    @MainActor
    static func parse(publication: Publication, epubFileURL: URL? = nil) async throws -> [AudioOverlayClip] {
        guard let epubFileURL else {
            return try await parseUncached(publication: publication, epubFileURL: nil)
        }

        let key = publicationKey(for: epubFileURL)
        if let clipCache, clipCache.key == key {
            return clipCache.clips
        }
        if let running = clipParseTasks[key] {
            return try await running.value
        }

        let task = Task { @MainActor in
            try await parseUncached(publication: publication, epubFileURL: epubFileURL)
        }
        clipParseTasks[key] = task
        defer { clipParseTasks[key] = nil }

        let clips = try await task.value
        if !clips.isEmpty {
            clipCache = (key: key, clips: clips)
        }
        return clips
    }

    @MainActor
    private static func parseUncached(publication: Publication, epubFileURL: URL?) async throws -> [AudioOverlayClip] {
        let mediaTypeLinks = publication.resources.filterByMediaType(.smil)
        let extensionLinks = publication.resources.filter {
            let href = normalizeHref($0.href).lowercased()
            return href.hasSuffix(".smil") || href.contains(".smil#")
        }
        let smilLinksByHref = Dictionary(
            (mediaTypeLinks + extensionLinks).map { (normalizeHref($0.href), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let smilLinks = Array(smilLinksByHref.values)

        guard !smilLinks.isEmpty else {
            AppLogger.library.info("EPUB3SMILParser: No SMIL resources in publication (mediaType + .smil fallback)")
            if let epubFileURL {
                AppLogger.library.debug(
                    "EPUB3SMILParser: Falling back to ZIP scan \(DiagnosticLogSanitizer.fileDescriptor(for: epubFileURL))"
                )
                let zipClips = try await parseSMILFromArchive(epubFileURL: epubFileURL)
                let sortedZipClips = sortClipsBySpine(zipClips, publication: publication)
                AppLogger.library.info("EPUB3SMILParser: ZIP fallback parsed \(sortedZipClips.count) clip(s)")
                return sortedZipClips
            }
            throw ParseError.noSMILResources
        }

        AppLogger.library.info("EPUB3SMILParser: Found \(smilLinks.count) SMIL resource(s)")

        var allClips: [AudioOverlayClip] = []

        for link in smilLinks {
            guard let resource = publication.get(link) else {
                AppLogger.library.warning("EPUB3SMILParser: Could not get resource for SMIL link: \(link.href)")
                continue
            }

            let data: Data
            do {
                nonisolated(unsafe) let unsafeResource = resource
                data = try await unsafeResource.read().get()
            } catch {
                AppLogger.library.warning("EPUB3SMILParser: Failed to read SMIL data for \(link.href): \(error)")
                continue
            }

            let baseHref = normalizeHref(link.href)
            AppLogger.library.info("EPUB3SMILParser: Parsing SMIL \(baseHref) (\(data.count) bytes)")

            let clips = SmilXMLParser(data: data, baseHref: baseHref).parseAndReturn()
            AppLogger.library.info("EPUB3SMILParser: Parsed \(clips.count) clips from \(baseHref)")
            allClips.append(contentsOf: clips)
        }

        guard !allClips.isEmpty else {
            AppLogger.library.warning("EPUB3SMILParser: Parsed 0 clips total from \(smilLinks.count) SMIL file(s)")
            if let epubFileURL {
                AppLogger.library.info("EPUB3SMILParser: Retrying via direct ZIP SMIL scan")
                let zipClips = try await parseSMILFromArchive(epubFileURL: epubFileURL)
                let sortedZipClips = sortClipsBySpine(zipClips, publication: publication)
                AppLogger.library.info("EPUB3SMILParser: ZIP retry parsed \(sortedZipClips.count) clip(s)")
                return sortedZipClips
            }
            return []
        }

        allClips = sortClipsBySpine(allClips, publication: publication)

        AppLogger.library.info("EPUB3SMILParser: Total clips: \(allClips.count), sorted by spine order")
        return allClips
    }

    private static func sortClipsBySpine(_ clips: [AudioOverlayClip], publication: Publication) -> [AudioOverlayClip] {
        let readingOrderHrefs = publication.readingOrder.map { normalizeHref($0.href) }
        let hrefToSpineIndex: [String: Int] = {
            var map: [String: Int] = [:]
            for (idx, href) in readingOrderHrefs.enumerated() {
                map[href] = idx
            }
            return map
        }()

        func spinePosition(for textHref: String) -> Int {
            let normalized = normalizeHref(textHref)
            if let exact = hrefToSpineIndex[normalized] { return exact }
            for (href, idx) in hrefToSpineIndex {
                if href.hasSuffix(normalized) || normalized.hasSuffix(href) { return idx }
                let hrefFile = (href as NSString).lastPathComponent
                let normalizedFile = (normalized as NSString).lastPathComponent
                if hrefFile == normalizedFile { return idx }
            }
            return Int.max
        }

        return clips.enumerated()
            .sorted { a, b in
                let spineA = spinePosition(for: a.element.textHref)
                let spineB = spinePosition(for: b.element.textHref)
                if spineA != spineB { return spineA < spineB }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    private static func parseSMILFromArchive(epubFileURL: URL) async throws -> [AudioOverlayClip] {
        let fileSize: Int64 = {
            let attrs = try? FileManager.default.attributesOfItem(atPath: epubFileURL.path)
            return attrs?[.size] as? Int64 ?? -1
        }()
        AppLogger.library.debug(
            "EPUB3SMILParser: ZIP scan \(DiagnosticLogSanitizer.fileDescriptor(for: epubFileURL)) bytes=\(fileSize)"
        )

        let archive = try await Archive(url: epubFileURL, accessMode: .read)
        let allEntries = try await archive.entries()
        AppLogger.library.info("EPUB3SMILParser: ZIP scan found \(allEntries.count) total entries")

        var smilEntries =
            allEntries
            .filter { entry in
                guard entry.type == .file else { return false }
                let path = normalizeHref(resolvePathDots(entry.path)).lowercased()
                return path.hasSuffix(".smil") || path.contains(".smil#")
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        if smilEntries.isEmpty {
            let tmpRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("enve-opf-scan-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpRoot) }

            let normalizedEntries =
                allEntries
                .filter { $0.type == .file }
                .map { (normalized: normalizeHref(resolvePathDots($0.path)), entry: $0) }

            let containerEntry = normalizedEntries.first { pair in
                pair.normalized.lowercased() == "meta-inf/container.xml"
            }

            if let containerEntry {
                let containerTmp = tmpRoot.appendingPathComponent("container.xml")
                if (try? await archive.extract(containerEntry.entry, to: containerTmp)) != nil,
                    let containerData = try? Data(contentsOf: containerTmp),
                    let containerXML = String(data: containerData, encoding: .utf8)
                {
                    let rootfileRegex = try? NSRegularExpression(
                        pattern: "full-path\\s*=\\s*\"([^\"]+)\"",
                        options: [.caseInsensitive]
                    )

                    var opfPath: String?
                    if let rootfileRegex,
                        let match = rootfileRegex.firstMatch(
                            in: containerXML,
                            options: [],
                            range: NSRange(containerXML.startIndex..<containerXML.endIndex, in: containerXML)
                        ),
                        let range = Range(match.range(at: 1), in: containerXML)
                    {
                        opfPath = normalizeHref(resolvePathDots(String(containerXML[range])))
                    }

                    if let opfPath {
                        let opfEntry = normalizedEntries.first { pair in
                            pair.normalized == opfPath
                                || pair.normalized.hasSuffix(opfPath)
                                || opfPath.hasSuffix(pair.normalized)
                        }

                        if let opfEntry {
                            let opfTmp = tmpRoot.appendingPathComponent("content.opf")
                            if (try? await archive.extract(opfEntry.entry, to: opfTmp)) != nil,
                                let opfData = try? Data(contentsOf: opfTmp),
                                let opfXML = String(data: opfData, encoding: .utf8)
                            {
                                let itemTagRegex = try? NSRegularExpression(
                                    pattern: "<item\\b[^>]*>",
                                    options: [.caseInsensitive]
                                )
                                let attrRegex = try? NSRegularExpression(
                                    pattern: "([A-Za-z_:][A-Za-z0-9_.:-]*)\\s*=\\s*\"([^\"]*)\"",
                                    options: []
                                )

                                var idToHref: [String: String] = [:]
                                var overlayIds = Set<String>()

                                if let itemTagRegex {
                                    let nsRange = NSRange(opfXML.startIndex..<opfXML.endIndex, in: opfXML)
                                    let matches = itemTagRegex.matches(in: opfXML, options: [], range: nsRange)
                                    for match in matches {
                                        guard let tagRange = Range(match.range, in: opfXML) else { continue }
                                        let tag = String(opfXML[tagRange])

                                        var attrs: [String: String] = [:]
                                        if let attrRegex {
                                            let attrMatches = attrRegex.matches(
                                                in: tag,
                                                options: [],
                                                range: NSRange(tag.startIndex..<tag.endIndex, in: tag)
                                            )
                                            for attrMatch in attrMatches {
                                                guard
                                                    let keyRange = Range(attrMatch.range(at: 1), in: tag),
                                                    let valRange = Range(attrMatch.range(at: 2), in: tag)
                                                else { continue }
                                                attrs[String(tag[keyRange]).lowercased()] = String(tag[valRange])
                                            }
                                        }

                                        let itemId = attrs["id"]
                                        let href = attrs["href"]
                                        let mediaType = attrs["media-type"]?.lowercased() ?? ""
                                        let mediaOverlayRef = attrs["media-overlay"]

                                        if let itemId, let href {
                                            idToHref[itemId] = href
                                        }

                                        if mediaType.contains("smil") || mediaType.contains("application/smil+xml") {
                                            if let itemId {
                                                overlayIds.insert(itemId)
                                            }
                                        }

                                        if let mediaOverlayRef, !mediaOverlayRef.isEmpty {
                                            overlayIds.insert(mediaOverlayRef)
                                        }
                                    }
                                }

                                let opfDir = (opfPath as NSString).deletingLastPathComponent
                                func resolveFromOPF(_ href: String) -> String {
                                    let joined = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
                                    return normalizeHref(resolvePathDots(joined))
                                }

                                let candidatePaths = Set(
                                    overlayIds.compactMap { idToHref[$0] }.map(resolveFromOPF)
                                )

                                if !candidatePaths.isEmpty {
                                    let discovered = normalizedEntries.compactMap { pair in
                                        let matchesCandidate =
                                            candidatePaths.contains(pair.normalized)
                                            || candidatePaths.contains { cand in
                                                pair.normalized.hasSuffix(cand) || cand.hasSuffix(pair.normalized)
                                            }
                                        return matchesCandidate ? pair.entry : nil
                                    }
                                    smilEntries = discovered.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                                    if !smilEntries.isEmpty {
                                        let discoveredPaths = smilEntries.map { $0.path }.joined(separator: ", ")
                                        AppLogger.library.info(
                                            "EPUB3SMILParser: OPF fallback discovered overlay resources: \(discoveredPaths)"
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        if smilEntries.isEmpty {
            let sample = allEntries.prefix(25).map { $0.path }.joined(separator: ", ")
            AppLogger.library.warning("EPUB3SMILParser: ZIP scan found 0 SMIL entries. Entry sample: \(sample)")
        } else {
            let listed = smilEntries.map { $0.path }.joined(separator: ", ")
            AppLogger.library.info("EPUB3SMILParser: ZIP scan SMIL entries: \(listed)")
        }

        guard !smilEntries.isEmpty else {
            throw ParseError.noSMILResources
        }

        let tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-smil-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        var allClips: [AudioOverlayClip] = []

        for (idx, entry) in smilEntries.enumerated() {

            try Task.checkCancellation()
            let tmpFile = tmpRoot.appendingPathComponent("\(idx)-\((entry.path as NSString).lastPathComponent)")
            _ = try await archive.extract(entry, to: tmpFile)
            let data = try Data(contentsOf: tmpFile)
            let baseHref = normalizeHref(resolvePathDots(entry.path))
            let clips = SmilXMLParser(data: data, baseHref: baseHref).parseAndReturn()
            allClips.append(contentsOf: clips)
        }

        AppLogger.library.info("EPUB3SMILParser: ZIP parsed total \(allClips.count) clips")
        return allClips
    }

    @MainActor
    static func extractAudio(
        clips: [AudioOverlayClip],
        publication: Publication,
        bookId: String,
        epubFileURL: URL? = nil
    ) async throws -> URL {

        let audioDir = overlayAudioDirectory(bookId: bookId, epubFileURL: epubFileURL)
        pruneOverlayAudio(keeping: audioDir)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        let uniqueAudioSrcs = Array(Set(clips.map(\.audioSrc)))
        AppLogger.library.info("EPUB3SMILParser: Extracting \(uniqueAudioSrcs.count) unique audio file(s)")

        let allLinks = publication.resources + publication.readingOrder
        let linksByHref: [(normalized: String, link: ReadiumShared.Link)] = allLinks.map {
            (normalized: normalizeHref($0.href), link: $0)
        }

        var extractedCount = 0
        var failedSrcs: [String] = []

        var zipArchive: Archive?
        if let epubFileURL,
            let archive = try? await Archive(url: epubFileURL, accessMode: .read),
            (try? await archive.entries()) != nil
        {
            zipArchive = archive
        }

        for src in uniqueAudioSrcs {
            try Task.checkCancellation()
            let cleanSrc = resolvePathDots(src)
            let destURL = audioDir.appendingPathComponent(localAudioFilename(for: src))

            guard !FileManager.default.fileExists(atPath: destURL.path) else {
                extractedCount += 1
                continue
            }

            if let zipArchive,
                try await extractAudioFromArchive(cleanSrc: cleanSrc, archive: zipArchive, destURL: destURL)
            {
                extractedCount += 1
                continue
            }

            let matchedLink = findMatchingLink(for: cleanSrc, in: linksByHref)

            guard let link = matchedLink else {
                if let zipArchive,
                    try await extractAudioFromArchive(cleanSrc: cleanSrc, archive: zipArchive, destURL: destURL)
                {
                    extractedCount += 1
                    continue
                } else {
                    AppLogger.library.warning(
                        "EPUB3SMILParser: No resource matched sourceId=\(DiagnosticLogSanitizer.identifier(for: cleanSrc))"
                    )
                    failedSrcs.append(src)
                    continue
                }
            }

            guard let resource = publication.get(link) else {
                AppLogger.library.warning(
                    "EPUB3SMILParser: Could not get resource sourceId=\(DiagnosticLogSanitizer.identifier(for: String(describing: link.href)))"
                )
                failedSrcs.append(src)
                continue
            }

            let audioData: Data
            do {
                nonisolated(unsafe) let unsafeResource = resource
                audioData = try await unsafeResource.read().get()
            } catch {
                if let zipArchive,
                    try await extractAudioFromArchive(cleanSrc: cleanSrc, archive: zipArchive, destURL: destURL)
                {
                    extractedCount += 1
                    continue
                } else {
                    AppLogger.library.warning(
                        "EPUB3SMILParser: Failed to read audio sourceId=\(DiagnosticLogSanitizer.identifier(for: cleanSrc)): \(error)"
                    )
                    failedSrcs.append(src)
                    continue
                }
            }

            guard audioData.count >= 100 else {
                AppLogger.library.warning(
                    "EPUB3SMILParser: Audio data suspiciously small (\(audioData.count) bytes) sourceId=\(DiagnosticLogSanitizer.identifier(for: cleanSrc)) - skipping"
                )
                failedSrcs.append(src)
                continue
            }
            try Task.checkCancellation()

            do {
                try audioData.write(to: destURL, options: .atomic)
                extractedCount += 1
                AppLogger.library.debug(
                    "EPUB3SMILParser: Extracted \(DiagnosticLogSanitizer.fileDescriptor(for: destURL))"
                )
            } catch {
                AppLogger.library.error(
                    "EPUB3SMILParser: Failed to write audio pathId=\(DiagnosticLogSanitizer.identifier(for: destURL.standardizedFileURL.path)): \(error)"
                )
                failedSrcs.append(src)
            }
        }

        AppLogger.library.info("EPUB3SMILParser: Audio extraction complete. \(extractedCount)/\(uniqueAudioSrcs.count) succeeded")

        if extractedCount != uniqueAudioSrcs.count {
            throw ParseError.audioExtractionFailed(
                "Extracted \(extractedCount) of \(uniqueAudioSrcs.count) audio files. Failed sources: \(failedSrcs.prefix(5).joined(separator: ", "))"
            )
        }

        return audioDir
    }

    private static func overlayAudioRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("enve-overlay")
    }

    private static func publicationKey(for epubFileURL: URL?) -> String {
        let values = epubFileURL.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        }
        let size = values?.fileSize ?? 0
        let modified = Int((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return "\(epubFileURL?.lastPathComponent ?? "-")-\(size)-\(modified)"
    }

    private static func overlayAudioDirectory(bookId: String, epubFileURL: URL?) -> URL {
        let values = epubFileURL.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        }
        let size = values?.fileSize ?? 0
        let modified = Int((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return overlayAudioRoot()
            .appendingPathComponent(bookId)
            .appendingPathComponent("\(size)-\(modified)")
    }

    private static func pruneOverlayAudio(keeping audioDir: URL) {
        let fileManager = FileManager.default
        let keep = audioDir.standardizedFileURL.path
        let bookDir = audioDir.deletingLastPathComponent().standardizedFileURL.path

        func prune(_ root: URL, survivor: String) {
            let contents =
                (try? fileManager.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
            for url in contents where url.standardizedFileURL.path != survivor {
                try? fileManager.removeItem(at: url)
            }
        }

        prune(overlayAudioRoot(), survivor: bookDir)
        prune(audioDir.deletingLastPathComponent(), survivor: keep)
    }

    private static func extractAudioFromArchive(
        cleanSrc: String,
        archive: Archive,
        destURL: URL
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard let entries = try? await archive.entries() else {
            return false
        }

        let normalizedEntries =
            entries
            .filter { $0.type == .file }
            .map { (normalized: normalizeHref(resolvePathDots($0.path)), entry: $0) }

        let matched =
            normalizedEntries.first(where: { $0.normalized == cleanSrc })
            ?? normalizedEntries.first(where: {
                $0.normalized.hasSuffix(cleanSrc) || cleanSrc.hasSuffix($0.normalized)
            })
            ?? {
                let srcFilename = (cleanSrc as NSString).lastPathComponent
                return normalizedEntries.first(where: {
                    ($0.normalized as NSString).lastPathComponent == srcFilename
                })
            }()
            ?? {
                let lowercasedSrc = cleanSrc.lowercased()
                return normalizedEntries.first(where: {
                    let cand = $0.normalized.lowercased()
                    return cand == lowercasedSrc || cand.hasSuffix(lowercasedSrc) || lowercasedSrc.hasSuffix(cand)
                })
            }()

        guard let matched else {
            return false
        }

        let partURL = destURL.appendingPathExtension("part")
        do {
            try? FileManager.default.removeItem(at: destURL)
            try? FileManager.default.removeItem(at: partURL)
            _ = try await archive.extract(matched.entry, to: partURL)
            let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path)
            let size = attrs?[.size] as? Int64 ?? 0
            guard size >= 100 else {
                try? FileManager.default.removeItem(at: partURL)
                return false
            }
            try FileManager.default.moveItem(at: partURL, to: destURL)
            AppLogger.library.debug(
                "EPUB3SMILParser: ZIP fallback extracted sourceId=\(DiagnosticLogSanitizer.identifier(for: cleanSrc)) bytes=\(size)"
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            if error is CancellationError { throw error }
            AppLogger.library.warning(
                "EPUB3SMILParser: ZIP fallback failed sourceId=\(DiagnosticLogSanitizer.identifier(for: cleanSrc)): \(error)"
            )
            return false
        }
    }

    private static func findMatchingLink(
        for cleanSrc: String,
        in links: [(normalized: String, link: ReadiumShared.Link)]
    ) -> ReadiumShared.Link? {
        if let match = links.first(where: { $0.normalized == cleanSrc }) {
            return match.link
        }

        if let match = links.first(where: {
            $0.normalized.hasSuffix(cleanSrc) || cleanSrc.hasSuffix($0.normalized)
        }) {
            return match.link
        }

        let srcFilename = (cleanSrc as NSString).lastPathComponent
        if let match = links.first(where: {
            ($0.normalized as NSString).lastPathComponent == srcFilename
        }) {
            return match.link
        }

        let lowercasedSrc = cleanSrc.lowercased()
        if let match = links.first(where: {
            $0.normalized.lowercased() == lowercasedSrc || $0.normalized.lowercased().hasSuffix(lowercasedSrc)
                || lowercasedSrc.hasSuffix($0.normalized.lowercased())
        }) {
            return match.link
        }

        return nil
    }

    static func clipIndex(from clips: [AudioOverlayClip]) -> [String: AudioOverlayClip] {
        Dictionary(clips.map { ($0.fragmentId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func detectFeatures(epubFileURL: URL) async -> EPUB3Features? {
        do {
            return try await _detectFeaturesFromZIP(epubFileURL: epubFileURL)
        } catch {
            AppLogger.library.warning(
                "EPUB3SMILParser: Feature detection failed \(DiagnosticLogSanitizer.fileDescriptor(for: epubFileURL)): \(error)"
            )
            return nil
        }
    }

    private static func _detectFeaturesFromZIP(epubFileURL: URL) async throws -> EPUB3Features? {
        let archive = try await Archive(url: epubFileURL, accessMode: .read)
        let allEntries = try await archive.entries()
        let normalizedEntries =
            allEntries
            .filter { $0.type == .file }
            .map { (normalized: normalizeHref(resolvePathDots($0.path)), entry: $0) }

        let smilCount = normalizedEntries.filter { $0.normalized.lowercased().hasSuffix(".smil") }.count

        guard
            let containerPair = normalizedEntries.first(where: {
                $0.normalized.lowercased() == "meta-inf/container.xml"
            })
        else { return smilCount > 0 ? EPUB3Features(hasMediaOverlay: true, smilFileCount: smilCount) : nil }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-detect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let containerTmp = tmpDir.appendingPathComponent("container.xml")
        _ = try await archive.extract(containerPair.entry, to: containerTmp)
        let containerXML = (try? String(contentsOf: containerTmp, encoding: .utf8)) ?? ""

        let rootfileRegex = try NSRegularExpression(pattern: #"full-path\s*=\s*"([^"]+)""#, options: [.caseInsensitive])
        guard let rootMatch = rootfileRegex.firstMatch(in: containerXML, range: NSRange(containerXML.startIndex..., in: containerXML)),
            let rootRange = Range(rootMatch.range(at: 1), in: containerXML)
        else {
            return smilCount > 0 ? EPUB3Features(hasMediaOverlay: true, smilFileCount: smilCount) : nil
        }

        let opfPath = normalizeHref(resolvePathDots(String(containerXML[rootRange])))
        guard
            let opfPair = normalizedEntries.first(where: {
                $0.normalized == opfPath || $0.normalized.hasSuffix(opfPath) || opfPath.hasSuffix($0.normalized)
            })
        else { return smilCount > 0 ? EPUB3Features(hasMediaOverlay: true, smilFileCount: smilCount) : nil }

        let opfTmp = tmpDir.appendingPathComponent("content.opf")
        _ = try await archive.extract(opfPair.entry, to: opfTmp)
        let opfXML = (try? String(contentsOf: opfTmp, encoding: .utf8)) ?? ""

        let hasMediaOverlay =
            opfXML.range(
                of: #"\bmedia-overlay\s*="#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil

        let isFixed =
            opfXML.range(
                of: #"rendition:layout[^"]*"[^"]*fixed"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            || opfXML.range(
                of: #"rendition:layout\s*>\s*pre-paginated"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil

        guard hasMediaOverlay || isFixed || smilCount > 0 else { return nil }
        return EPUB3Features(
            hasMediaOverlay: hasMediaOverlay || smilCount > 0,
            hasFixedLayout: isFixed,
            smilFileCount: smilCount
        )
    }

    static func buildChaptersFromDurations(
        durationMap: [String: TimeInterval],
        tocChapters: [Chapter]
    ) -> [Chapter]? {
        guard !durationMap.isEmpty, !tocChapters.isEmpty else { return nil }

        var cumulativeStart: TimeInterval = 0
        var anyDurationAssigned = false

        let result: [Chapter] = tocChapters.map { chapter in
            let rawHref = hrefFromChapterId(chapter.id)
            let href = rawHref.components(separatedBy: "#").first ?? rawHref

            let duration: TimeInterval = {
                if let d = durationMap[href], d > 0 { return d }
                if let match = durationMap.first(where: {
                    $0.key.hasSuffix("/\(href)") || href.hasSuffix("/\($0.key)") || $0.key == href
                }), match.value > 0 {
                    return match.value
                }
                return 0
            }()

            let start = cumulativeStart
            cumulativeStart += duration
            if duration > 0 { anyDurationAssigned = true }
            return Chapter(id: chapter.id, start: start, end: cumulativeStart, title: chapter.title, index: chapter.index)
        }

        return anyDurationAssigned ? result : nil
    }

    private static func hrefFromChapterId(_ id: String) -> String {
        var dashCount = 0
        for (offset, char) in id.enumerated() where char == "-" {
            dashCount += 1
            if dashCount == 3 {
                return String(id[id.index(id.startIndex, offsetBy: offset + 1)...])
            }
        }
        return id
    }

    static func parseChapterDurations(epubFileURL: URL) async -> [String: TimeInterval] {
        do {
            return try await _parseChapterDurationsFromZIP(epubFileURL: epubFileURL)
        } catch {
            AppLogger.library.warning("EPUB3SMILParser: parseChapterDurations failed: \(error)")
            return [:]
        }
    }

    private static func _parseChapterDurationsFromZIP(epubFileURL: URL) async throws -> [String: TimeInterval] {
        let archive = try await Archive(url: epubFileURL, accessMode: .read)
        let allEntries = try await archive.entries()
        let normalizedEntries =
            allEntries
            .filter { $0.type == .file }
            .map { (normalized: normalizeHref(resolvePathDots($0.path)), entry: $0) }

        guard
            let containerPair = normalizedEntries.first(where: {
                $0.normalized.lowercased() == "meta-inf/container.xml"
            })
        else { return [:] }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-opf-dur-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let containerTmp = tmpDir.appendingPathComponent("container.xml")
        _ = try await archive.extract(containerPair.entry, to: containerTmp)
        let containerXML = (try? String(contentsOf: containerTmp, encoding: .utf8)) ?? ""

        let rootfileRegex = try NSRegularExpression(
            pattern: #"full-path\s*=\s*"([^"]+)""#,
            options: [.caseInsensitive]
        )
        guard
            let rootMatch = rootfileRegex.firstMatch(
                in: containerXML,
                range: NSRange(containerXML.startIndex..., in: containerXML)
            ),
            let rootRange = Range(rootMatch.range(at: 1), in: containerXML)
        else { return [:] }

        let opfPath = normalizeHref(resolvePathDots(String(containerXML[rootRange])))
        guard
            let opfPair = normalizedEntries.first(where: {
                $0.normalized == opfPath
                    || $0.normalized.hasSuffix(opfPath)
                    || opfPath.hasSuffix($0.normalized)
            })
        else { return [:] }

        let opfTmp = tmpDir.appendingPathComponent("content.opf")
        _ = try await archive.extract(opfPair.entry, to: opfTmp)
        let opfXML = (try? String(contentsOf: opfTmp, encoding: .utf8)) ?? ""
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        let attrRegex = try NSRegularExpression(
            pattern: #"([A-Za-z_:][A-Za-z0-9_.:-]*)\s*=\s*"([^"]*)""#,
            options: []
        )

        func extractAttrs(from tag: String) -> [String: String] {
            var attrs: [String: String] = [:]
            let matches = attrRegex.matches(
                in: tag,
                range: NSRange(tag.startIndex..., in: tag)
            )
            for m in matches {
                guard let kR = Range(m.range(at: 1), in: tag),
                    let vR = Range(m.range(at: 2), in: tag)
                else { continue }
                attrs[String(tag[kR]).lowercased()] = String(tag[vR])
            }
            return attrs
        }

        var overlayDurations: [String: TimeInterval] = [:]
        let metaTagRegex = try NSRegularExpression(
            pattern: #"<meta\b([^>]*)>([^<]*)</meta>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        for m in metaTagRegex.matches(in: opfXML, range: NSRange(opfXML.startIndex..., in: opfXML)) {
            guard let attrsRange = Range(m.range(at: 1), in: opfXML),
                let valRange = Range(m.range(at: 2), in: opfXML)
            else { continue }
            let attrs = extractAttrs(from: String(opfXML[attrsRange]))
            let value = String(opfXML[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard attrs["property"]?.lowercased() == "media:duration",
                let refines = attrs["refines"], !refines.isEmpty
            else { continue }
            let overlayId = refines.hasPrefix("#") ? String(refines.dropFirst()) : refines
            if let secs = parseMediaDuration(value) {
                overlayDurations[overlayId] = secs
            }
        }

        guard !overlayDurations.isEmpty else { return [:] }

        let itemTagRegex = try NSRegularExpression(
            pattern: #"<item\b[^>]*>"#,
            options: [.caseInsensitive]
        )
        var result: [String: TimeInterval] = [:]
        for m in itemTagRegex.matches(in: opfXML, range: NSRange(opfXML.startIndex..., in: opfXML)) {
            guard let tagRange = Range(m.range, in: opfXML) else { continue }
            let attrs = extractAttrs(from: String(opfXML[tagRange]))
            guard let href = attrs["href"],
                let overlayRef = attrs["media-overlay"],
                let duration = overlayDurations[overlayRef]
            else { continue }
            let resolvedHref = normalizeHref(
                resolvePathDots(
                    opfDir.isEmpty ? href : "\(opfDir)/\(href)"
                )
            )
            result[resolvedHref] = duration
        }

        AppLogger.library.info("EPUB3SMILParser: Parsed \(result.count) chapter duration(s) from OPF")
        return result
    }

    private static func parseMediaDuration(_ value: String) -> TimeInterval? {
        let s = value.trimmingCharacters(in: .whitespaces)
        let parts = s.components(separatedBy: ":")
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 1:
            return Double(s)
        default:
            return nil
        }
    }
}

private final class SmilXMLParser: NSObject, XMLParserDelegate {
    let data: Data
    let baseHref: String
    private(set) var clips: [AudioOverlayClip] = []

    private var currentTextHref: String?
    private var currentFragmentId: String?
    private var currentAudioSrc: String?
    private var currentClipBegin: TimeInterval?
    private var currentClipEnd: TimeInterval?
    private var currentTextFragment: TextFragment?

    private var granularityStack: [OverlayGranularity] = []
    private var groupCounter: Int = 0
    private var currentGroupIndex: Int?

    private var skippableRoleStack: [String?] = []
    private static let skippableRoles: Set<String> = [
        "footnote", "endnote", "pagebreak", "note",
        "rearnote", "sidebar", "marginalia", "annotation",
    ]
    private var currentSkippableRole: String? {
        skippableRoleStack.last(where: { $0 != nil }) ?? nil
    }

    init(data: Data, baseHref: String) {
        self.data = data
        self.baseHref = baseHref
    }

    func parseAndReturn() -> [AudioOverlayClip] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.parse()
        return clips
    }

    private var currentGranularity: OverlayGranularity {
        granularityStack.last ?? .unspecified
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

        switch localName {
        case "seq":
            let epubType = attributes["epub:type"] ?? attributes["type"] ?? ""
            if epubType.contains("text-range-large") {
                granularityStack.append(.large)
                groupCounter += 1
                currentGroupIndex = groupCounter
            } else if epubType.contains("text-range-small") {
                granularityStack.append(.small)
            } else {
                granularityStack.append(.unspecified)
            }
            let skippable = epubType.components(separatedBy: .whitespaces)
                .first(where: { SmilXMLParser.skippableRoles.contains($0) })
            skippableRoleStack.append(skippable)

        case "par":
            currentTextHref = nil
            currentFragmentId = nil
            currentAudioSrc = nil
            currentClipBegin = nil
            currentClipEnd = nil
            currentTextFragment = nil

        case "text":
            if let src = attributes["src"] {
                let parts = src.components(separatedBy: "#")
                let rawHref = parts.first ?? src
                currentTextHref = resolveHref(rawHref)
                if parts.count > 1 {
                    let fragment = parts[1]
                    if fragment.hasPrefix(":~:text=") {
                        let directive = String(fragment.dropFirst(":~:text=".count))
                        currentTextFragment = TextFragment.parse(directive)
                        currentFragmentId = fragment
                    } else {
                        currentFragmentId = fragment
                        currentTextFragment = nil
                    }
                }
            }

        case "audio":
            if let src = attributes["src"] {
                currentAudioSrc = resolveHref(src)
            }
            if let begin = attributes["clipBegin"] ?? attributes["clip-begin"] {
                currentClipBegin = parseSmilClock(begin)
            }
            if let end = attributes["clipEnd"] ?? attributes["clip-end"] {
                currentClipEnd = parseSmilClock(end)
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        let localName = (elementName.components(separatedBy: ":").last ?? elementName).lowercased()

        switch localName {
        case "seq":
            let popped = granularityStack.popLast() ?? .unspecified
            if popped == .large {
                currentGroupIndex = nil
            }
            skippableRoleStack.removeLast()

        case "par":
            if let frag = currentFragmentId,
                let textHref = currentTextHref,
                let audioSrc = currentAudioSrc,
                let begin = currentClipBegin,
                let end = currentClipEnd, end > begin
            {
                clips.append(
                    AudioOverlayClip(
                        fragmentId: frag,
                        textHref: textHref,
                        audioSrc: audioSrc,
                        clipBegin: begin,
                        clipEnd: end,
                        granularity: currentGranularity,
                        parentGroupIndex: currentGranularity == .small ? currentGroupIndex : nil,
                        textFragment: currentTextFragment,
                        skippableRole: currentSkippableRole
                    )
                )
            }

            currentTextHref = nil
            currentFragmentId = nil
            currentAudioSrc = nil
            currentClipBegin = nil
            currentClipEnd = nil
            currentTextFragment = nil

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        AppLogger.library.warning("EPUB3SMILParser: XML parse error: \(parseError.localizedDescription)")
    }

    private func resolveHref(_ href: String) -> String {
        guard !href.hasPrefix("/") else {
            return EPUB3SMILParser.resolvePathDots(href)
        }

        let baseDir = (baseHref as NSString).deletingLastPathComponent
        if baseDir.isEmpty || baseDir == "." {
            return EPUB3SMILParser.resolvePathDots(href)
        }

        let joined = baseDir + "/" + href
        return EPUB3SMILParser.resolvePathDots(joined)
    }

    private func parseSmilClock(_ value: String) -> TimeInterval? {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("npt=") { s = String(s.dropFirst(4)) }

        if s.hasSuffix("ms"), let ms = Double(s.dropLast(2)) {
            return ms / 1000.0
        }
        if s.hasSuffix("s"), let sec = Double(s.dropLast(1)) {
            return sec
        }
        if s.hasSuffix("min"), let min = Double(s.dropLast(3)) {
            return min * 60.0
        }
        if s.hasSuffix("h"), let h = Double(s.dropLast(1)) {
            return h * 3600.0
        }

        let parts = s.components(separatedBy: ":")
        switch parts.count {
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        case 2:
            guard let m = Double(parts[0]), let sec = Double(parts[1]) else { return nil }
            return m * 60 + sec
        case 1:
            return Double(s)
        default:
            return nil
        }
    }
}
