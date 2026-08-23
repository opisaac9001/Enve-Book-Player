import Foundation
import Logging

enum StoreBackup {

    @discardableResult
    static func backup(storeURL: URL, label: String, retainCount: Int = 2) -> URL? {
        let fm = FileManager.default
        let parent = storeURL.deletingLastPathComponent()
        let basePath = storeURL.path

        let companions: [URL] = [
            storeURL,
            URL(fileURLWithPath: basePath + "-wal"),
            URL(fileURLWithPath: basePath + "-shm"),
            storeURL.appendingPathExtension("wal"),
            storeURL.appendingPathExtension("shm"),
        ]
        let existing = companions.filter { fm.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }

        pruneOldBackups(in: parent, label: label, keep: max(retainCount - 1, 0))

        let backupDir = parent.appendingPathComponent("\(label).corrupt-\(timestampString())")
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            for src in existing {
                let dst = backupDir.appendingPathComponent(src.lastPathComponent)
                try fm.copyItem(at: src, to: dst)
            }
            AppLogger.general.warning(
                "StoreBackup: copied \(existing.count) file(s) for \(label) to \(backupDir.lastPathComponent) before corruption reset"
            )
            return backupDir
        } catch {
            AppLogger.general.error("StoreBackup: failed to back up \(label): \(error)")
            return nil
        }
    }

    static func existingBackups(in parent: URL, label: String) -> [URL] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        let prefix = "\(label).corrupt-"
        return
            entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { lhs, rhs in
                let lmod = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rmod = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lmod > rmod
            }
    }

    private static func pruneOldBackups(in parent: URL, label: String, keep: Int) {
        let backups = existingBackups(in: parent, label: label)
        guard backups.count > keep, keep >= 0 else { return }
        let fm = FileManager.default
        for old in backups.dropFirst(keep) {
            try? fm.removeItem(at: old)
        }
    }

    private static func timestampString() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        df.timeZone = TimeZone(identifier: "UTC")
        df.locale = Locale(identifier: "en_US_POSIX")
        return df.string(from: Date())
    }
}
