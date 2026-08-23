import Combine
import Foundation
import Logging

@MainActor
final class InstalledDictionariesStore: ObservableObject {
    static let shared = InstalledDictionariesStore()

    struct InstalledDictionary: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let wordCount: Int
        let folder: URL
    }

    @Published private(set) var dictionaries: [InstalledDictionary] = []

    private let rootURL: URL
    private var cache: [String: StarDictDictionary] = [:]

    private init() {
        let appSupport =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        rootURL = appSupport.appendingPathComponent("Enve/StarDict", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let installed = scan()
        dictionaries = installed
    }

    func lookup(_ word: String) -> StarDictDictionary.Definition? {
        for dictionary in dictionaries {
            guard let stardict = loaded(slug: dictionary.id) else { continue }
            let hits = stardict.lookupFuzzy(word)
            if let first = hits.first { return first }
        }
        return nil
    }

    func delete(_ dictionary: InstalledDictionary) {
        try? FileManager.default.removeItem(at: dictionary.folder)
        cache.removeValue(forKey: dictionary.id)
        refresh()
    }

    @discardableResult
    func installFromFolder(folderURL: URL) throws -> InstalledDictionary {
        let slug = freshSlug(preferredBase: folderURL.deletingPathExtension().lastPathComponent)
        let dest = rootURL.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let stardictFiles = try locateStarDictFiles(in: folderURL)
        guard stardictFiles.ifo != nil else {
            try? FileManager.default.removeItem(at: dest)
            throw InstallError.missingIfo
        }
        for src in stardictFiles.all {
            let destURL = dest.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.copyFile(at: src, to: destURL)
        }
        AppLogger.library.info("Installed StarDict dictionary: \(slug)")
        refresh()
        guard let result = dictionaries.first(where: { $0.id == slug }) else {

            throw InstallError.scanFailedAfterCopy
        }
        return result
    }

    enum InstallError: LocalizedError {
        case missingIfo
        case scanFailedAfterCopy

        var errorDescription: String? {
            switch self {
            case .missingIfo: return "No .ifo file found in the selected folder."
            case .scanFailedAfterCopy: return "Files were copied but the dictionary metadata could not be read."
            }
        }
    }

    private struct StarDictFiles {
        let ifo: URL?
        let all: [URL]
    }

    private func locateStarDictFiles(in folder: URL) throws -> StarDictFiles {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let ifo = contents.first { $0.pathExtension.lowercased() == "ifo" }
        let relevant = contents.filter {
            let ext = $0.pathExtension.lowercased()
            return ["ifo", "idx", "dict", "dz", "syn"].contains(ext) || $0.lastPathComponent.hasSuffix(".dict.dz")
        }
        return StarDictFiles(ifo: ifo, all: relevant)
    }

    private func loaded(slug: String) -> StarDictDictionary? {
        if let cached = cache[slug] { return cached }
        let folder = rootURL.appendingPathComponent(slug, isDirectory: true)
        guard
            let ifo =
                (try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil
                ))?.first(where: { $0.pathExtension.lowercased() == "ifo" })
        else {
            return nil
        }
        let dictionary = StarDictDictionary(ifoURL: ifo)
        do {
            try dictionary.load()
        } catch {
            AppLogger.library.warning("StarDict load failed for \(slug): \(error.localizedDescription)")
            return nil
        }
        cache[slug] = dictionary
        return dictionary
    }

    private func scan() -> [InstalledDictionary] {
        let folders =
            (try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return folders.compactMap { folder -> InstalledDictionary? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let slug = folder.lastPathComponent
            guard
                let ifoURL =
                    (try? FileManager.default.contentsOfDirectory(
                        at: folder,
                        includingPropertiesForKeys: nil
                    ))?.first(where: { $0.pathExtension.lowercased() == "ifo" })
            else {
                return nil
            }
            let dictionary = StarDictDictionary(ifoURL: ifoURL)
            try? dictionary.load()
            return InstalledDictionary(
                id: slug,
                displayName: dictionary.name,
                wordCount: dictionary.wordCount,
                folder: folder
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func freshSlug(preferredBase: String) -> String {
        let sanitized =
            preferredBase
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let base = sanitized.isEmpty ? "dictionary" : sanitized
        var candidate = base
        var n = 1
        while FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(candidate).path) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        return candidate
    }
}

private extension FileManager {
    func copyFile(at src: URL, to dst: URL) throws {
        if fileExists(atPath: dst.path) {
            try removeItem(at: dst)
        }
        try copyItem(at: src, to: dst)
    }
}
