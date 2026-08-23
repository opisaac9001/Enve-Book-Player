import Foundation

final class FilesystemTransport: NotesExportTransport {

    private let bookmarkData: Data
    private let subfolder: String
    private let atomicHighlights: Bool

    private(set) var resolvedBookmarkRefresh: Data?

    init(bookmarkData: Data, subfolder: String, atomicHighlights: Bool) {
        self.bookmarkData = bookmarkData
        self.subfolder = subfolder
        self.atomicHighlights = atomicHighlights
    }

    func loadExisting(for bookStableId: String, filename: String) async throws -> String? {
        try await withVault { vault in
            let target = self.targetURL(in: vault, filename: filename)
            guard FileManager.default.fileExists(atPath: target.path) else { return nil }
            do {
                return try String(contentsOf: target, encoding: .utf8)
            } catch {
                throw NotesExportError.transportFailed(error)
            }
        }
    }

    func write(markdown: String, for bookStableId: String, filename: String) async throws {
        try await withVault { vault in
            let target = self.targetURL(in: vault, filename: filename)
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try markdown.write(to: target, atomically: true, encoding: .utf8)
            } catch CocoaError.fileWriteNoPermission {
                throw NotesExportError.vaultAccessDenied
            } catch {
                throw NotesExportError.transportFailed(error)
            }
        }
    }

    private func withVault<T>(_ body: (URL) throws -> T) async throws -> T {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw NotesExportError.vaultBookmarkStale
        }

        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        if !didStart {
            throw NotesExportError.vaultAccessDenied
        }

        if isStale {

            if let refreshed = try? url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                self.resolvedBookmarkRefresh = refreshed
            }
        }

        return try body(url)
    }

    private func targetURL(in vault: URL, filename: String) -> URL {
        let trimmedSub = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        var folder = vault
        if !trimmedSub.isEmpty {
            for component in trimmedSub.split(separator: "/").map(String.init) {
                folder.appendPathComponent(component)
            }
        }
        if atomicHighlights {
            folder.appendPathComponent("Highlights")
        }
        return folder.appendingPathComponent(filename)
    }
}
