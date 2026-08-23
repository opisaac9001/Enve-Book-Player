#if DEBUG
import Foundation

struct ImportGuardrailFixtureResult: Identifiable {
    let id = UUID()
    let name: String
    let passed: Bool
    let detail: String
}

enum ImportGuardrailFixtureRunner {
    static func run() async -> [ImportGuardrailFixtureResult] {
        var results: [ImportGuardrailFixtureResult] = []

        results.append(await runDeepDirectoryFixture())
        results.append(runFileCountFixture())
        results.append(runPathTraversalFixture())
        results.append(runOversizedFileFixture())
        results.append(runLooseAudiobookGroupingFixture())
        results.append(runExplicitBookGroupingFixture())
        results.append(runBookChapterGroupingFixture())
        results.append(runNumberedAudiobookGroupingFixture())
        results.append(runTitledChapterGroupingFixture())
        results.append(runM4AChapterGroupingFixture())
        results.append(runPrefixTitleGroupingFixture())
        results.append(runManualSeparationFixture())
        results.append(await runMixedCollectionScanFixture())

        return results
    }

    private static func runDeepDirectoryFixture() async -> ImportGuardrailFixtureResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-import-depth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            var current = root
            for index in 0...ImportLimits.maxDirectoryDepth {
                current = current.appendingPathComponent("level-\(index)", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
            let audioURL = current.appendingPathComponent("too-deep.m4b")
            _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data(), attributes: nil)

            let library = LocalLibrary(name: "Guardrail Depth", folderPath: root.path)
            _ = try await LocalLibraryService.shared.scanLibrary(library)
            return ImportGuardrailFixtureResult(
                name: "Deep directory scan",
                passed: false,
                detail: "Scan unexpectedly completed"
            )
        } catch let error as ImportLimitError {
            return ImportGuardrailFixtureResult(
                name: "Deep directory scan",
                passed: true,
                detail: error.localizedDescription
            )
        } catch {
            return ImportGuardrailFixtureResult(
                name: "Deep directory scan",
                passed: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func runFileCountFixture() -> ImportGuardrailFixtureResult {
        do {
            var budget = ImportScanBudget(maxFiles: 1)
            try budget.record(path: "one.m4b", relativePath: "one.m4b")
            try budget.record(path: "two.m4b", relativePath: "two.m4b")
            return ImportGuardrailFixtureResult(
                name: "File count budget",
                passed: false,
                detail: "Budget unexpectedly accepted two files"
            )
        } catch let error as ImportLimitError {
            return ImportGuardrailFixtureResult(
                name: "File count budget",
                passed: true,
                detail: error.localizedDescription
            )
        } catch {
            return ImportGuardrailFixtureResult(
                name: "File count budget",
                passed: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func runPathTraversalFixture() -> ImportGuardrailFixtureResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-import-traversal-\(UUID().uuidString)", isDirectory: true)
        do {
            _ = try ImportLimits.validateArchiveEntryPath("../escape.m4b", destinationRoot: root)
            return ImportGuardrailFixtureResult(
                name: "Archive path traversal",
                passed: false,
                detail: "Traversal path was accepted"
            )
        } catch let error as ImportLimitError {
            return ImportGuardrailFixtureResult(
                name: "Archive path traversal",
                passed: true,
                detail: error.localizedDescription
            )
        } catch {
            return ImportGuardrailFixtureResult(
                name: "Archive path traversal",
                passed: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func runOversizedFileFixture() -> ImportGuardrailFixtureResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-import-size-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fileURL = root.appendingPathComponent("oversize.m4b")
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(ImportLimits.maxImportedMediaFileBytes + 1))

            try ImportLimits.validateImportedMediaFile(fileURL)
            return ImportGuardrailFixtureResult(
                name: "Oversized media file",
                passed: false,
                detail: "Oversized file was accepted"
            )
        } catch let error as ImportLimitError {
            return ImportGuardrailFixtureResult(
                name: "Oversized media file",
                passed: true,
                detail: error.localizedDescription
            )
        } catch {
            return ImportGuardrailFixtureResult(
                name: "Oversized media file",
                passed: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func runLooseAudiobookGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = ["Flawless.mp3", "Wild Card (Rose Hill #4) (Unabridged).mp3"]
        let groups = AudiobookFileGrouping.groups(
            files,
            name: { $0 },
            bookEvidence: { _ in true }
        )
        return ImportGuardrailFixtureResult(
            name: "Loose audiobook grouping",
            passed: groups.count == 2 && groups.allSatisfy { $0.count == 1 },
            detail: "Expected 2 books, found \(groups.count)"
        )
    }

    private static func runNumberedAudiobookGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = ["Book One 01.mp3", "Book One 02.mp3", "Book Two 01.mp3"]
        let groups = AudiobookFileGrouping.groups(files, name: { $0 })
        let sizes = groups.map(\.count).sorted()
        let groupedBookTitle = groups.first(where: { $0.count == 2 })
            .flatMap(\.first)
            .map(AudiobookFileGrouping.inferredTitle)
        return ImportGuardrailFixtureResult(
            name: "Numbered audiobook grouping",
            passed: sizes == [1, 2] && groupedBookTitle == "Book One",
            detail: "Expected group sizes [1, 2] and title Book One, found \(sizes) and \(groupedBookTitle ?? "nil")"
        )
    }

    private static func runExplicitBookGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = ["Book 1.mp3", "Book 2.mp3"]
        let groups = AudiobookFileGrouping.groups(files, name: { $0 })
        return ImportGuardrailFixtureResult(
            name: "Explicit book grouping",
            passed: groups.count == 2 && groups.allSatisfy { $0.count == 1 },
            detail: "Expected Book 1 and Book 2 to remain separate, found \(groups.count) group(s)"
        )
    }

    private static func runBookChapterGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = [
            "Book 1 - Chapter 1.mp3",
            "Book 2 - Chapter 1.mp3",
            "Book 1 - Chapter 2.mp3",
        ]
        let groups = AudiobookFileGrouping.groups(files, name: { $0 })
        let sizes = groups.map(\.count).sorted()
        return ImportGuardrailFixtureResult(
            name: "Book and chapter grouping",
            passed: sizes == [1, 2],
            detail: "Expected chapters grouped by book prefix, found group sizes \(sizes)"
        )
    }

    private static func runPrefixTitleGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = ["Dune.mp3", "Dune Messiah.mp3"]
        let groups = AudiobookFileGrouping.groups(files, name: { $0 })
        return ImportGuardrailFixtureResult(
            name: "Ambiguous grouping",
            passed: groups.count == 1,
            detail: "Expected one book when evidence is ambiguous, found \(groups.count)"
        )
    }

    private static func runTitledChapterGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = [
            "Chapter 16 - The Chamber of Secrets.mp3",
            "Credits.mp3",
            "Chapter 2 - Dobby's Warning.mp3",
            "Opening Credits.mp3",
            "Chapter 1 - The Worst Birthday.mp3",
        ]
        let groups = AudiobookFileGrouping.groups(files, name: { $0 })
        let expectedOrder = [
            "Opening Credits.mp3",
            "Chapter 1 - The Worst Birthday.mp3",
            "Chapter 2 - Dobby's Warning.mp3",
            "Chapter 16 - The Chamber of Secrets.mp3",
            "Credits.mp3",
        ]
        return ImportGuardrailFixtureResult(
            name: "Titled chapter grouping",
            passed: groups == [expectedOrder],
            detail: "Expected one ordered chapter sequence, found \(groups)"
        )
    }

    private static func runM4AChapterGroupingFixture() -> ImportGuardrailFixtureResult {
        let files = ["Chapter 1.m4a", "Chapter 2.m4a"]
        let groups = AudiobookFileGrouping.groups(files, name: { $0 })
        return ImportGuardrailFixtureResult(
            name: "M4A chapter grouping",
            passed: groups == [files],
            detail: "Expected explicit M4A chapters to remain one book, found \(groups.count) group(s)"
        )
    }

    private static func runManualSeparationFixture() -> ImportGuardrailFixtureResult {
        let files = ["First title.mp3", "Second title.mp3"]
        let groups = AudiobookFileGrouping.groups(
            files,
            name: { $0 },
            forcedStandalone: { $0 == "Second title.mp3" }
        )
        return ImportGuardrailFixtureResult(
            name: "Manual track separation",
            passed: groups.count == 2 && groups.allSatisfy { $0.count == 1 },
            detail: "Expected the selected track to become its own book, found \(groups.count) group(s)"
        )
    }

    private static func runMixedCollectionScanFixture() async -> ImportGuardrailFixtureResult {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enve-import-collection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try createFullBookFixture(at: root.appendingPathComponent("Flawless.mp3"))
            try createFullBookFixture(at: root.appendingPathComponent("Wild Card (Rose Hill #4) (Unabridged).mp3"))
            try Data(#"{"title":"Artemis","author":"Various Artists"}"#.utf8)
                .write(to: root.appendingPathComponent("metadata.json"))

            let library = LocalLibrary(name: "Mixed Collection", folderPath: root.path)
            let result = try await LocalLibraryService.shared.scanLibrary(library)
            let titles = Set(result.booksFound.map(\.displayTitle))
            let passed = result.booksFound.count == 2 && !titles.contains("Artemis")
            return ImportGuardrailFixtureResult(
                name: "Mixed collection scan",
                passed: passed,
                detail: "Expected 2 independent books without folder metadata, found \(result.booksFound.count): \(titles.sorted())"
            )
        } catch {
            return ImportGuardrailFixtureResult(
                name: "Mixed collection scan",
                passed: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func createFullBookFixture(at url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data([0])) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AudiobookFileGrouping.minimumStandaloneBookSize))
        try handle.close()
    }
}
#endif
