#if os(iOS)
import Foundation
import Observation

nonisolated struct NarratorModelStorage: Equatable, Sendable {
    var packageBytes: Int64
    var remainingBytes: Int64
    var installedBytes: Int64
    var isEstimate: Bool

    static let empty = NarratorModelStorage(packageBytes: 0, remainingBytes: 0, installedBytes: 0, isEstimate: false)
}

// Model files are device-wide, so readers and Settings share download and residency ownership.
@Observable @MainActor
final class NarratorModelStore {
    static let shared = NarratorModelStore()

    enum Event {
        case installed(EbookTTSEngineChoice)
        case cancelled(EbookTTSEngineChoice)
        case willRemove(EbookTTSEngineChoice)
    }

    struct Runtime {
        var isInstalled: @MainActor (EbookTTSEngineChoice) -> Bool
        var prepare: @MainActor (EbookTTSEngineChoice, @escaping @Sendable (Double) -> Void) async throws -> Void
        /// Must cancel the runtime's own unstructured preparation, which outlives a cancelled caller.
        var unload: @MainActor (EbookTTSEngineChoice) async -> Void
        var remove: @MainActor (EbookTTSEngineChoice) async throws -> Void
        var storage: @Sendable (EbookTTSEngineChoice) -> NarratorModelStorage
        var availableBytes: @Sendable () -> Int64?
    }

    private struct Client {
        weak var owner: AnyObject?
        var engines: Set<EbookTTSEngineChoice>
        let handle: @MainActor (Event) -> Void
    }

    private(set) var states: [EbookTTSEngineChoice: TTSModelDownloadState] = [:]
    private(set) var storage: [EbookTTSEngineChoice: NarratorModelStorage] = [:]
    private(set) var availableBytes: Int64?

    private let defaults: UserDefaults
    private let runtime: Runtime
    @ObservationIgnored private var transfers: [EbookTTSEngineChoice: Task<Void, Never>] = [:]
    @ObservationIgnored private var generations: [EbookTTSEngineChoice: Int] = [:]
    @ObservationIgnored private var runtimeQueues: [EbookTTSEngineChoice: Task<Void, Never>] = [:]
    @ObservationIgnored private var clients: [ObjectIdentifier: Client] = [:]

    /// Readiness keys predate this store and stay in the owner's standard defaults, beside the device-level files.
    init(defaults: UserDefaults = .standard, runtime: Runtime = .live) {
        self.defaults = defaults
        self.runtime = runtime
        for engine in EbookTTSEngineChoice.downloadableCases {
            states[engine] = installedState(for: engine)
        }
    }

    func state(for engine: EbookTTSEngineChoice) -> TTSModelDownloadState {
        engine == .apple ? .ready : states[engine] ?? .notDownloaded
    }

    func isReady(_ engine: EbookTTSEngineChoice) -> Bool {
        switch engine {
        case .apple: true
        case .kokoro: state(for: .kokoro) == .ready && KokoroTTSRuntime.isSupportedOnCurrentOS
        case .supertonic3, .pocket: state(for: engine) == .ready
        case .phonon: state(for: engine) == .ready && PhononTTSRuntime.isSupportedOnCurrentOS
        }
    }

    // Check disk state: preparing a runtime downloads any missing files.
    func hasInstalledFiles(_ engine: EbookTTSEngineChoice) -> Bool {
        engine == .apple || runtime.isInstalled(engine)
    }

    func download(_ engine: EbookTTSEngineChoice) {
        guard engine != .apple else { return }
        guard engine != .phonon || PhononTTSRuntime.isSupportedOnCurrentOS else { return }
        if engine == .kokoro, !KokoroTTSRuntime.isSupportedOnCurrentOS {
            if state(for: .kokoro) != .ready {
                states[.kokoro] = .failed(NeuralTTSError.unsupportedOS.localizedDescription)
            }
            return
        }
        switch state(for: engine) {
        case .notDownloaded, .failed: break
        case .downloading, .cancelling, .removing, .ready: return
        }
        let generation = beginTransfer(.downloading(0), for: engine)
        transfers[engine] = enqueue(engine) { [weak self] in
            await self?.performDownload(engine, generation: generation)
        }
    }

    /// Complete files stay on disk so a retry only fetches what is missing.
    func cancelDownload(_ engine: EbookTTSEngineChoice) {
        guard case .downloading = state(for: engine) else { return }
        let transfer = transfers[engine]
        let generation = beginTransfer(.cancelling, for: engine)
        notify(.cancelled(engine))
        transfers[engine] = Task { [weak self] in
            await self?.runtime.unload(engine)
            await transfer?.value
            guard let self else { return }
            finish(engine, generation: generation, state: installedState(for: engine))
        }
    }

    func remove(_ engine: EbookTTSEngineChoice) {
        guard engine != .apple, state(for: engine) == .ready else { return }
        let generation = beginTransfer(.removing, for: engine)
        notify(.willRemove(engine))
        transfers[engine] = enqueue(engine) { [weak self] in
            guard let self else { return }
            do {
                try await runtime.remove(engine)
                guard isCurrent(engine, generation) else { return }
                defaults.set(false, forKey: Self.readyKey(for: engine))
                finish(engine, generation: generation, state: .notDownloaded)
            } catch {
                finish(engine, generation: generation, state: .failed(error.localizedDescription))
            }
        }
    }

    func refreshStorage() async {
        let measure = runtime.storage
        let available = runtime.availableBytes
        let engines = EbookTTSEngineChoice.downloadableCases
        let (measured, free) = await Task.detached(priority: .utility) {
            (Dictionary(uniqueKeysWithValues: engines.map { ($0, measure($0)) }), available())
        }.value
        storage = measured
        availableBytes = free
    }

    func register(_ owner: AnyObject, using engines: Set<EbookTTSEngineChoice> = [], handle: @escaping @MainActor (Event) -> Void) {
        clients[ObjectIdentifier(owner)] = Client(owner: owner, engines: engines, handle: handle)
    }

    // Readers wait for unused runtimes to release memory before starting the selected engine.
    @discardableResult
    func use(_ engines: Set<EbookTTSEngineChoice>, by owner: AnyObject) -> Task<Void, Never> {
        clients[ObjectIdentifier(owner)]?.engines = engines
        return unloadIdleRuntimes()
    }

    func unregister(_ owner: AnyObject) {
        clients[ObjectIdentifier(owner)] = nil
        unloadIdleRuntimes()
    }

    private func performDownload(_ engine: EbookTTSEngineChoice, generation: Int) async {
        let measure = runtime.storage
        let available = runtime.availableBytes
        let (needed, free) = await Task.detached(priority: .userInitiated) {
            (measure(engine), available())
        }.value
        guard isCurrent(engine, generation) else { return }
        if let free, needed.remainingBytes > free {
            finish(engine, generation: generation, state: .failed(Self.insufficientStorageMessage(engine, needed: needed, available: free)))
            return
        }
        do {
            try await runtime.prepare(engine) { [weak self] progress in
                Task { @MainActor [weak self] in self?.report(progress, for: engine, generation: generation) }
            }
            guard isCurrent(engine, generation) else { return }
            defaults.set(true, forKey: Self.readyKey(for: engine))
            finish(engine, generation: generation, state: .ready)
            notify(.installed(engine))
            // A model installed from Settings should not stay resident until a reader uses it.
            unloadIdleRuntimes()
        } catch {
            guard isCurrent(engine, generation) else { return }
            finish(engine, generation: generation, state: error is CancellationError ? installedState(for: engine) : .failed(error.localizedDescription))
        }
    }

    private func report(_ progress: Double, for engine: EbookTTSEngineChoice, generation: Int) {
        guard isCurrent(engine, generation), case .downloading = state(for: engine) else { return }
        states[engine] = .downloading(min(max(progress, 0), 1))
    }

    private func beginTransfer(_ state: TTSModelDownloadState, for engine: EbookTTSEngineChoice) -> Int {
        let generation = (generations[engine] ?? 0) &+ 1
        generations[engine] = generation
        transfers[engine]?.cancel()
        states[engine] = state
        return generation
    }

    private func finish(_ engine: EbookTTSEngineChoice, generation: Int, state: TTSModelDownloadState) {
        guard isCurrent(engine, generation) else { return }
        states[engine] = state
        transfers[engine] = nil
        Task { await refreshStorage() }
    }

    private func isCurrent(_ engine: EbookTTSEngineChoice, _ generation: Int) -> Bool {
        generations[engine] == generation
    }

    private func installedState(for engine: EbookTTSEngineChoice) -> TTSModelDownloadState {
        defaults.bool(forKey: Self.readyKey(for: engine)) && runtime.isInstalled(engine) ? .ready : .notDownloaded
    }

    private func notify(_ event: Event) {
        clients = clients.filter { $0.value.owner != nil }
        for client in clients.values { client.handle(event) }
    }

    @discardableResult
    private func unloadIdleRuntimes() -> Task<Void, Never> {
        let unloads = EbookTTSEngineChoice.downloadableCases.filter(isIdle).map { engine in
            enqueue(engine) { [weak self] in
                // Recheck once queued work for this engine has finished.
                guard let self, isIdle(engine) else { return }
                await runtime.unload(engine)
            }
        }
        return Task { for unload in unloads { await unload.value } }
    }

    private func isIdle(_ engine: EbookTTSEngineChoice) -> Bool {
        !state(for: engine).isTransferring
            && !clients.values.contains { $0.owner != nil && $0.engines.contains(engine) }
    }

    /// Runtime work for one engine runs in order; engines never wait on each other.
    private func enqueue(_ engine: EbookTTSEngineChoice, _ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = runtimeQueues[engine]
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await operation()
        }
        runtimeQueues[engine] = task
        return task
    }

    private static func readyKey(for engine: EbookTTSEngineChoice) -> String {
        switch engine {
        case .apple: ""
        case .kokoro: "ebookTTS.kokoroModelReady"
        case .supertonic3: "ebookTTS.enhancedModelReady"
        case .pocket: "ebookTTS.pocketModelReady"
        case .phonon: "ebookTTS.phononModelReady"
        }
    }

    private static func insufficientStorageMessage(
        _ engine: EbookTTSEngineChoice,
        needed: NarratorModelStorage,
        available: Int64
    ) -> String {
        let size = ByteCountFormatter.string(fromByteCount: needed.remainingBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return "Not enough free space for \(engine.modelName). It needs \(needed.isEstimate ? "about " : "")\(size) and \(free) is available."
    }
}

extension NarratorModelStore.Runtime {
    static var live: Self {
        Self(
            isInstalled: { engine in
                switch engine {
                case .apple: true
                case .kokoro: KokoroTTSRuntime.hasDownloadedVoices
                case .supertonic3: SupertonicTTSRuntime.hasDownloadedVoices
                case .pocket: PocketTTSRuntime.hasDownloadedVoices
                case .phonon: PhononTTSRuntime.hasDownloadedVoices
                }
            },
            prepare: { engine, progress in
                switch engine {
                case .apple: return
                case .kokoro: try await KokoroTTSRuntime.shared.prepare(progress: progress)
                case .supertonic3: try await SupertonicTTSRuntime.shared.prepareVoicePack(progress: progress)
                case .pocket: try await PocketTTSRuntime.shared.prepare(progress: progress)
                case .phonon: try await PhononTTSRuntime.shared.prepare(progress: progress)
                }
            },
            unload: { engine in
                switch engine {
                case .apple: return
                case .kokoro: await KokoroTTSRuntime.shared.unload()
                case .supertonic3: await SupertonicTTSRuntime.shared.unload()
                case .pocket: await PocketTTSRuntime.shared.unload()
                case .phonon: await PhononTTSRuntime.shared.unload()
                }
            },
            remove: { engine in
                switch engine {
                case .apple: return
                case .kokoro: try await KokoroTTSRuntime.shared.removeModels()
                case .supertonic3: try await SupertonicTTSRuntime.shared.removeModels()
                case .pocket: try await PocketTTSRuntime.shared.removeModels()
                case .phonon: try await PhononTTSRuntime.shared.removeModels()
                }
            },
            storage: { NarratorModelStorage.measure($0) },
            availableBytes: { NarratorModelStorage.availableBytes() }
        )
    }
}

nonisolated extension NarratorModelStorage {
    /// Kokoro's frontend assets are resolved by FluidAudio at install time, so only an estimate is known up front.
    static let kokoroEstimatedBytes: Int64 = 140_000_000

    static func availableBytes() -> Int64? {
        try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    static func measure(_ engine: EbookTTSEngineChoice) -> NarratorModelStorage {
        #if targetEnvironment(macCatalyst)
        return .empty
        #else
        switch engine {
        case .apple:
            return .empty
        case .kokoro:
            let installed = allocatedBytes(in: (try? KokoroTTSRuntime.modelDirectories) ?? [])
            let remaining = KokoroTTSRuntime.hasDownloadedVoices ? 0 : max(kokoroEstimatedBytes - installed, 0)
            return NarratorModelStorage(
                packageBytes: kokoroEstimatedBytes,
                remainingBytes: remaining,
                installedBytes: installed,
                isEstimate: true
            )
        case .supertonic3:
            return measurePack(.supertonic)
        case .pocket:
            return measurePack(.pocket)
        case .phonon:
            return PhononTTSRuntime.modelStorage
        }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    private static func measurePack(_ pack: LocalNarratorPack) -> NarratorModelStorage {
        NarratorModelStorage(
            packageBytes: Int64(pack.byteCount),
            remainingBytes: Int64(pack.missingByteCount),
            installedBytes: allocatedBytes(in: (try? pack.storageDirectories) ?? []),
            isEstimate: false
        )
    }

    private static func allocatedBytes(in directories: [URL]) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        var total: Int64 = 0
        for directory in directories {
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: Array(keys)) else { continue }
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
    #endif
}
#endif
