import Foundation
import Logging

enum StorageMigrationHelper {

    private static let migrationKey = "StorageMigrationHelper.v1.completed"
    private static let placeholderPurgeKey = "StorageMigrationHelper.grimmoryPlaceholderCovers.purged"

    static func migrateIfNeeded() {
        purgeGrimmoryPlaceholderCoversIfNeeded()

        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }

        let migrations: [(old: String, new: String)] = [
            ("Narratarr/Audiobooks", "Enve/Audiobooks"),
            ("Narratarr/Metadata", "Enve/Metadata"),
            ("Narratarr/PlaybackState", "Enve/PlaybackState"),
            ("Narratarr/ListeningStats", "Enve/ListeningStats"),
            ("Narratarr/ImportStaging", "Enve/ImportStaging"),
            ("Narratarr/Covers", "Enve/Covers"),
            ("NarratarrCache", "EnveCache"),
        ]

        var anyFailed = false

        for (oldRel, newRel) in migrations {
            let oldURL = appSupport.appendingPathComponent(oldRel, isDirectory: true)
            let newURL = appSupport.appendingPathComponent(newRel, isDirectory: true)

            guard fm.fileExists(atPath: oldURL.path) else { continue }

            let newParent = newURL.deletingLastPathComponent()
            try? fm.createDirectory(at: newParent, withIntermediateDirectories: true)

            if fm.fileExists(atPath: newURL.path) {
                mergeDirectory(from: oldURL, into: newURL, fileManager: fm)
            } else {
                do {
                    try fm.moveItem(at: oldURL, to: newURL)
                    AppLogger.library.info("Moved \(oldRel) -> \(newRel)")
                } catch {
                    AppLogger.library.error("Failed to move \(oldRel): \(error.localizedDescription)")
                    anyFailed = true
                }
            }
        }

        let oldServers = appSupport.appendingPathComponent("Narratarr/webdav_servers.json")
        let newServers = appSupport.appendingPathComponent("Enve/webdav_servers.json")
        if fm.fileExists(atPath: oldServers.path) && !fm.fileExists(atPath: newServers.path) {
            try? fm.createDirectory(at: newServers.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: oldServers, to: newServers)
        }

        if !anyFailed {
            UserDefaults.standard.set(true, forKey: migrationKey)
            AppLogger.library.info("Storage migration complete")
        }
    }

    private static func purgeGrimmoryPlaceholderCoversIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: placeholderPurgeKey) else { return }

        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let coversDir = appSupport.appendingPathComponent("Enve/Covers", isDirectory: true)

        let contents =
            (try? fm.contentsOfDirectory(
                at: coversDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: .skipsHiddenFiles
            )) ?? []

        var purged = 0
        for fileURL in contents {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            guard size == BookloreProvider.missingCoverByteCount,
                let data = try? Data(contentsOf: fileURL),
                BookloreProvider.isMissingCoverPlaceholder(data)
            else { continue }
            try? fm.removeItem(at: fileURL)
            purged += 1
        }

        UserDefaults.standard.set(true, forKey: placeholderPurgeKey)
        if purged > 0 {
            AppLogger.library.info("Purged \(purged) Grimmory placeholder cover overrides")
        }
    }

    private static func mergeDirectory(from src: URL, into dst: URL, fileManager fm: FileManager) {
        guard let enumerator = fm.enumerator(at: src, includingPropertiesForKeys: nil) else { return }
        for case let fileURL as URL in enumerator {
            let relativePath = fileURL.path.replacingOccurrences(of: src.path + "/", with: "")
            let destURL = dst.appendingPathComponent(relativePath)

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fileURL.path, isDirectory: &isDir) && isDir.boolValue {
                try? fm.createDirectory(at: destURL, withIntermediateDirectories: true)
            } else if !fm.fileExists(atPath: destURL.path) {
                try? fm.moveItem(at: fileURL, to: destURL)
            }
        }
    }
}
