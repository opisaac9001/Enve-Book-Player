import Foundation
import Testing

@testable import enve

@Suite(.serialized, .enabled(if: !EbookTTSEngineChoice.downloadableCases.isEmpty)) @MainActor
struct NarratorModelStoreTests {
    @Test func cancellingADownloadAbandonsTheRuntimePreparationAndIgnoresLateProgress() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = FakeNarratorRuntime(holdsPreparation: true)
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)

        store.download(.supertonic3)
        try await waitUntil { store.state(for: .supertonic3) == .downloading(0.4) }
        store.cancelDownload(.supertonic3)

        #expect(store.state(for: .supertonic3) == .cancelling)
        runtime.reportProgress(0.9)
        try await waitUntil { store.state(for: .supertonic3) == .notDownloaded }
        #expect(runtime.events == ["prepare supertonic3", "unload supertonic3"])
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.state(for: .supertonic3) == .notDownloaded)
        #expect(!defaults.bool(forKey: "ebookTTS.enhancedModelReady"))
    }

    @Test func aPreparationThatFinishesAfterCancellationIsNotAdopted() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = FakeNarratorRuntime(holdsPreparation: true)
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)
        let reader = Client(store: store)

        store.download(.pocket)
        try await waitUntil { runtime.isPreparing }
        store.cancelDownload(.pocket)
        runtime.finishPreparation()

        try await waitUntil { store.state(for: .pocket) == .notDownloaded }
        #expect(runtime.installed.contains(.pocket))
        #expect(!defaults.bool(forKey: "ebookTTS.pocketModelReady"))
        #expect(reader.events == ["cancelled pocket"])
    }

    @Test func retryAfterCancellingInstallsNotifiesReadersAndReleasesTheIdleRuntime() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = FakeNarratorRuntime(holdsPreparation: true)
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)
        let reader = Client(store: store)
        store.download(.kokoro)
        try await waitUntil { runtime.isPreparing }
        store.cancelDownload(.kokoro)
        try await waitUntil { store.state(for: .kokoro) == .notDownloaded }
        runtime.holdsPreparation = false
        runtime.events.removeAll()

        store.download(.kokoro)

        try await waitUntil { runtime.events.contains("unload kokoro") }
        #expect(store.state(for: .kokoro) == .ready)
        #expect(defaults.bool(forKey: "ebookTTS.kokoroModelReady"))
        #expect(reader.events == ["cancelled kokoro", "installed kokoro"])
        #expect(runtime.events.first == "prepare kokoro")
    }

    @Test func cancellingReaderDownloadDoesNotSelectALaterSettingsDownload() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = FakeNarratorRuntime(holdsPreparation: true)
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)
        let reader = EbookTTSService(userDefaults: defaults, models: store)

        reader.setEngineChoice(.supertonic3)
        try await waitUntil { runtime.isPreparing }
        store.cancelDownload(.supertonic3)
        try await waitUntil { store.state(for: .supertonic3) == .notDownloaded }
        runtime.holdsPreparation = false

        store.download(.supertonic3)
        try await waitUntil { store.state(for: .supertonic3) == .ready }

        #expect(reader.engineChoice == .apple)
        #expect(defaults.string(forKey: "ebookTTS.engine") != "supertonic3")
    }

    @Test func lowStorageFailsBeforeAnyDownloadStarts() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = FakeNarratorRuntime(
            storage: NarratorModelStorage(packageBytes: 300_000_000, remainingBytes: 200_000_000, installedBytes: 100_000_000, isEstimate: false),
            availableBytes: 50_000_000
        )
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)

        store.download(.supertonic3)

        try await waitUntil { if case .failed = store.state(for: .supertonic3) { true } else { false } }
        guard case .failed(let message) = store.state(for: .supertonic3) else { return }
        #expect(message.contains("Not enough free space for Supertonic 3"))
        #expect(runtime.events.isEmpty)
    }

    @Test func storageEstimatesComeFromTheRuntimeMeasurement() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let measured = NarratorModelStorage(packageBytes: 172_000_000, remainingBytes: 40_000_000, installedBytes: 132_000_000, isEstimate: false)
        let runtime = FakeNarratorRuntime(storage: measured, availableBytes: 9_000_000_000)
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)

        await store.refreshStorage()

        #expect(store.availableBytes == 9_000_000_000)
        #expect(EbookTTSEngineChoice.downloadableCases.allSatisfy { store.storage[$0] == measured })
    }

    @Test func readinessRequiresBothThePersistedFlagAndInstalledFiles() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ebookTTS.kokoroModelReady")
        defaults.set(true, forKey: "ebookTTS.enhancedModelReady")
        let runtime = FakeNarratorRuntime(installed: [.kokoro, .pocket])

        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)

        #expect(store.state(for: .kokoro) == .ready)
        #expect(store.state(for: .supertonic3) == .notDownloaded)
        #expect(store.state(for: .pocket) == .notDownloaded)
    }

    @Test func everyReaderSeesRemovalAndOnlyItsUserFallsBackToApple() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "ebookTTS.kokoroModelReady")
        let runtime = FakeNarratorRuntime(installed: [.kokoro])
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)
        let first = EbookTTSService(userDefaults: defaults, models: store)
        let (otherDefaults, otherSuite) = try makeDefaults()
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let second = EbookTTSService(userDefaults: otherDefaults, models: store)
        first.setEngineChoice(.kokoro)
        #expect(first.engineChoice == .kokoro)

        store.remove(.kokoro)

        #expect(first.engineChoice == .apple)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "apple")
        #expect(second.engineChoice == .apple)
        #expect(first.downloadState(for: .kokoro) == .removing)
        #expect(second.downloadState(for: .kokoro) == .removing)
        try await waitUntil { store.state(for: .kokoro) == .notDownloaded }
        #expect(runtime.events.contains("remove kokoro"))
        #expect(!runtime.events.contains("unload kokoro"))
        #expect(!defaults.bool(forKey: "ebookTTS.kokoroModelReady"))
        #expect(second.downloadState(for: .kokoro) == .notDownloaded)
    }

    @Test func unusedRuntimesUnloadWithoutTouchingOneInUseOrTransferring() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = FakeNarratorRuntime(holdsPreparation: true)
        let store = NarratorModelStore(defaults: defaults, runtime: runtime.runtime)
        let narrating = Client(store: store)
        let idle = Client(store: store)
        store.use([.kokoro], by: narrating)
        store.download(.pocket)
        try await waitUntil { runtime.isPreparing }
        runtime.events.removeAll()

        await store.use([], by: idle).value

        let unused = EbookTTSEngineChoice.downloadableCases.filter { $0 != .kokoro && $0 != .pocket }
        #expect(runtime.events.sorted() == unused.map { "unload \($0.rawValue)" }.sorted())
        runtime.finishPreparation()
        try await waitUntil { runtime.events.contains("unload pocket") }
        #expect(!runtime.events.contains("unload kokoro"))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "NarratorModelStoreTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@MainActor
private final class Client {
    private(set) var events: [String] = []

    init(store: NarratorModelStore) {
        store.register(self) { [weak self] event in
            switch event {
            case .installed(let engine): self?.events.append("installed \(engine.rawValue)")
            case .cancelled(let engine): self?.events.append("cancelled \(engine.rawValue)")
            case .willRemove(let engine): self?.events.append("willRemove \(engine.rawValue)")
            }
        }
    }
}

/// Mirrors the real runtimes: preparation is unstructured and only `unload` abandons it.
@MainActor
final class FakeNarratorRuntime {
    var installed: Set<EbookTTSEngineChoice>
    var holdsPreparation: Bool
    var events: [String] = []
    private let storage: NarratorModelStorage
    private let availableBytes: Int64?
    private var pendingPreparations: [EbookTTSEngineChoice: CheckedContinuation<Void, Error>] = [:]
    private var progress: (@Sendable (Double) -> Void)?

    init(
        installed: Set<EbookTTSEngineChoice> = [],
        holdsPreparation: Bool = false,
        storage: NarratorModelStorage = .empty,
        availableBytes: Int64? = nil
    ) {
        self.installed = installed
        self.holdsPreparation = holdsPreparation
        self.storage = storage
        self.availableBytes = availableBytes
    }

    var isPreparing: Bool { !pendingPreparations.isEmpty }

    var runtime: NarratorModelStore.Runtime {
        let storage = storage
        let availableBytes = availableBytes
        return NarratorModelStore.Runtime(
            isInstalled: { self.installed.contains($0) },
            prepare: { engine, progress in try await self.prepare(engine, progress: progress) },
            unload: { engine in self.unload(engine) },
            remove: { engine in
                self.events.append("remove \(engine.rawValue)")
                self.installed.remove(engine)
            },
            storage: { _ in storage },
            availableBytes: { availableBytes }
        )
    }

    func reportProgress(_ value: Double) {
        progress?(value)
    }

    func finishPreparation() {
        let pending = pendingPreparations.values
        pendingPreparations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func prepare(_ engine: EbookTTSEngineChoice, progress: @escaping @Sendable (Double) -> Void) async throws {
        events.append("prepare \(engine.rawValue)")
        self.progress = progress
        progress(0.4)
        if holdsPreparation {
            try await withCheckedThrowingContinuation { pendingPreparations[engine] = $0 }
        }
        installed.insert(engine)
    }

    private func unload(_ engine: EbookTTSEngineChoice) {
        events.append("unload \(engine.rawValue)")
        pendingPreparations.removeValue(forKey: engine)?.resume(throwing: CancellationError())
    }
}
