import Foundation
import Logging
import Observation

@MainActor
@Observable
final class ObsidianNotesCoordinator {
    static let shared = ObsidianNotesCoordinator()

    var lastError: NotesExportError?
    var lastSuccessAt: Date?
    var isExporting: Bool = false

    var vaultBookmarkIsStale: Bool = false

    private var pendingTasks: [String: Task<Void, Never>] = [:]

    private var inflightTasks: [String: Task<Void, Never>] = [:]

    private var lastWrittenHash: [String: Int] = [:]

    private let debounce: Duration = .seconds(3)

    private init() {}

    func manualExport(book: Book) {
        let stableId = book.stableId

        pendingTasks[stableId]?.cancel()
        pendingTasks.removeValue(forKey: stableId)
        enqueueExport(book: book)
    }

    func scheduleAutoExport(book: Book, source: ChangeSource = .local) {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard prefs.obsidianSyncEnabled, prefs.obsidianAutoExportEnabled else { return }
        guard prefs.obsidianVaultBookmarkData != nil else { return }
        if source == .remote { return }

        let stableId = book.stableId
        pendingTasks[stableId]?.cancel()
        pendingTasks[stableId] = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounce ?? .seconds(3))
            } catch {
                return
            }
            guard let self else { return }
            self.pendingTasks.removeValue(forKey: stableId)

            let currentPrefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            guard currentPrefs.obsidianSyncEnabled, currentPrefs.obsidianAutoExportEnabled else { return }
            guard currentPrefs.obsidianVaultBookmarkData != nil else { return }

            self.enqueueExport(book: book)
        }
    }

    func setVaultURL(_ url: URL) {
        do {
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            prefs.obsidianVaultBookmarkData = bookmark
            LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
            vaultBookmarkIsStale = false
            lastError = nil
        } catch {
            lastError = .transportFailed(error)
        }
    }

    func clearVault() {
        var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        prefs.obsidianVaultBookmarkData = nil
        LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
        vaultBookmarkIsStale = false
    }

    func renderPreview(book: Book) async -> String? {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard let payload = await buildPayload(book: book, prefs: prefs) else { return nil }
        return NotesTemplateEngine.render(template: prefs.obsidianTemplateBody, payload: payload)
    }

    private func enqueueExport(book: Book) {
        let stableId = book.stableId

        let previous = inflightTasks[stableId]
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.runExport(book: book)
        }
        inflightTasks[stableId] = task
    }

    private func runExport(book: Book) async {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard prefs.obsidianSyncEnabled,
            let bookmarkData = prefs.obsidianVaultBookmarkData
        else {
            lastError = .vaultNotConfigured
            return
        }
        guard let payload = await buildPayload(book: book, prefs: prefs) else { return }

        isExporting = true
        defer { isExporting = false }

        let template = prefs.obsidianTemplateBody
        let policy = prefs.obsidianUpdatePolicy
        let subfolder = prefs.obsidianSubfolder
        let atomic = prefs.obsidianAtomicHighlights
        let filenameTemplate = prefs.obsidianFilenameTemplate

        let rendered = NotesTemplateEngine.render(template: template, payload: payload)
        let filename = makeFilename(template: filenameTemplate, payload: payload)
        let stableId = book.stableId

        let stableContentHash = stableHash(of: rendered)
        if lastWrittenHash[stableId] == stableContentHash {
            return
        }

        let transport = FilesystemTransport(
            bookmarkData: bookmarkData,
            subfolder: subfolder,
            atomicHighlights: atomic
        )

        do {
            let existing = try await transport.loadExisting(for: stableId, filename: filename)
            let merged = NotesUpdatePolicyMerger.merge(
                existing: existing,
                rendered: rendered,
                policy: policy
            )
            try await transport.write(markdown: merged, for: stableId, filename: filename)
            lastWrittenHash[stableId] = stableContentHash

            var updatedPrefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            updatedPrefs.obsidianLastSyncDates[stableId] = Date()
            if let refreshed = transport.resolvedBookmarkRefresh {
                updatedPrefs.obsidianVaultBookmarkData = refreshed
            }
            LibraryDisplayPreferencesStore.shared.savePreferences(updatedPrefs)
            lastSuccessAt = Date()
            lastError = nil
            vaultBookmarkIsStale = false
            AppLogger.general.debug(
                "[ObsidianNotes] Exported bookId=\(DiagnosticLogSanitizer.identifier(for: stableId)) using \(policy.rawValue)"
            )
        } catch let error as NotesExportError {
            lastError = error
            if case .vaultBookmarkStale = error { vaultBookmarkIsStale = true }
            AppLogger.general.error(
                "[ObsidianNotes] Export failed for bookId=\(DiagnosticLogSanitizer.identifier(for: stableId)): \(error.localizedDescription)"
            )
        } catch {
            lastError = .transportFailed(error)
            AppLogger.general.error(
                "[ObsidianNotes] Export failed for bookId=\(DiagnosticLogSanitizer.identifier(for: stableId)): \(error.localizedDescription)"
            )
        }
    }

    private func buildPayload(book: Book, prefs: UserPreferences) async -> BookNotesPayload? {
        let stableId = book.stableId
        let annotations = await AppState.shared.bookStore.annotations(forBookStableId: stableId)
        let bookmarks = await AppState.shared.bookStore.bookmarks(forBookStableId: stableId)
        let lastSynced = prefs.obsidianLastSyncDates[stableId]
        return BookNotesPayloadBuilder.build(
            book: book,
            annotations: annotations,
            bookmarks: bookmarks,
            lastSyncedAt: lastSynced
        )
    }

    private func makeFilename(template: String, payload: BookNotesPayload) -> String {
        let values: [String: NotesTemplateEngine.TemplateValue] = [
            "book": .dict([
                "id": .string(payload.book.id),
                "title": .string(payload.book.title),
                "authors": .array(payload.book.authors.map { .string($0) }),
                "mediaType": .string(payload.book.mediaType),
            ])
        ]
        var name = NotesTemplateEngine.render(template: template, with: values)
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        name = NotesTemplateEngine.sanitizeFilename(name)
        if name.isEmpty || name == "Untitled" {
            name = NotesTemplateEngine.sanitizeFilename(payload.book.title)
            if name == "Untitled" {
                name = "Untitled_\(payload.book.id)"
            }
        }
        if !name.lowercased().hasSuffix(".md") {
            name += ".md"
        }
        return name
    }

    enum ChangeSource: Sendable {
        case local
        case remote
    }

    private func stableHash(of rendered: String) -> Int {
        let stripped =
            rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("last_synced:") && !trimmed.hasPrefix("*Exported from Enve")
            }
            .joined(separator: "\n")
        return stripped.hashValue
    }
}
