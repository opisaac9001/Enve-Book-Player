#if os(iOS)
import Foundation
import Logging
import WebKit
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

nonisolated enum PhononVoice: String, CaseIterable, Identifiable, Sendable {
    case hugh = "Hugh"
    case spencer = "Spencer"

    var id: String { rawValue }
}

@MainActor
final class PhononTTSRuntime: NSObject, WKNavigationDelegate {
    static let shared = PhononTTSRuntime()

    private nonisolated struct Manifest: Decodable {
        struct Asset: Decodable {
            let file: NeuralTTSModelFile
            let url: URL

            init(from decoder: any Decoder) throws {
                file = try NeuralTTSModelFile(from: decoder)
                url = try decoder.container(keyedBy: CodingKeys.self).decode(URL.self, forKey: .url)
            }

            private enum CodingKeys: String, CodingKey { case url }
        }

        let revision: String
        let files: [Asset]
    }

    private nonisolated static let manifest = Result {
        guard let url = Bundle.main.url(forResource: "PhononManifest", withExtension: "json") else {
            throw NeuralTTSError.invalidModel
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    private nonisolated static let modelRoot = URL.cachesDirectory.appendingPathComponent("Phonon31m", isDirectory: true)
    private let audioCache = NeuralTTSAudioCache(namespace: "Phonon31m")
    private var webView: WKWebView?
    private var navigation: CheckedContinuation<Void, Error>?
    private var preparation: Task<Void, Error>?
    private var generation = 0

    nonisolated static var isSupportedOnCurrentOS: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        if #available(iOS 18, *) { return true }
        return false
        #endif
    }

    nonisolated static var hasDownloadedVoices: Bool {
        guard isSupportedOnCurrentOS, let manifest = try? manifest.get() else { return false }
        return manifest.files.allSatisfy { $0.file.hasExpectedSize(at: modelRoot.appendingPathComponent($0.file.path)) }
    }

    nonisolated static var modelStorage: NarratorModelStorage {
        guard let manifest = try? manifest.get() else { return .empty }
        var packageBytes: Int64 = 0
        var remainingBytes: Int64 = 0
        var installedBytes: Int64 = 0
        for asset in manifest.files {
            let file = asset.file
            let url = modelRoot.appendingPathComponent(file.path)
            packageBytes += Int64(file.size)
            if !file.hasExpectedSize(at: url) { remainingBytes += Int64(file.size) }
            installedBytes += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return NarratorModelStorage(
            packageBytes: packageBytes, remainingBytes: remainingBytes,
            installedBytes: installedBytes, isEstimate: false
        )
    }

    func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard Self.isSupportedOnCurrentOS else { throw NeuralTTSError.notReady }
        if let preparation {
            try await preparation.value
            return
        }
        if webView != nil {
            progress?(1)
            return
        }
        let started = generation
        let task = Task { [self] in
            let manifest = try Self.manifest.get()
            let root = Self.modelRoot
            let total = Double(manifest.files.reduce(0) { $0 + $1.file.size })
            var completed = 0
            for asset in manifest.files {
                let file = asset.file
                let before = Double(completed)
                try await file.install(from: asset.url, at: root.appendingPathComponent(file.path)) { fraction in
                    progress?((before + fraction * Double(file.size)) / total * 0.98)
                }
                completed += file.size
                progress?(Double(completed) / total * 0.98)
            }
            try Task.checkCancellation()
            try await loadModel(manifest)
            try Task.checkCancellation()
            progress?(1)
        }
        preparation = task
        defer { if generation == started { preparation = nil } }
        do {
            try await task.value
            guard generation == started else { throw CancellationError() }
        } catch {
            if generation == started { webView = nil }
            throw error
        }
    }

    func synthesize(text: String, voice: PhononVoice) async throws -> [Float] {
        try Task.checkCancellation()
        let key = audioCache.key(try Self.manifest.get().revision, voice.rawValue, text)
        if let cached = try audioCache.load(key: key) { return cached }
        try await prepare()
        try Task.checkCancellation()
        guard let webView else { throw NeuralTTSError.notReady }
        let id = UUID().uuidString
        let result = try await withTaskCancellationHandler {
            try await webView.callAsyncJavaScript(
                "return await speakPhonon(id, text, voice)",
                arguments: ["id": id, "text": text, "voice": voice.rawValue],
                contentWorld: .page
            )
        } onCancel: {
            Task { @MainActor [weak self] in
                _ = try? await self?.webView?.callAsyncJavaScript(
                    "cancelPhonon(id)", arguments: ["id": id], contentWorld: .page
                )
            }
        }
        try Task.checkCancellation()
        guard self.webView === webView else { throw CancellationError() }
        guard let encoded = result as? String,
            let data = Data(base64Encoded: encoded),
            data.count.isMultiple(of: MemoryLayout<Float>.stride)
        else { throw NeuralTTSError.invalidAudio }

        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.stride)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        try audioCache.store(samples, key: key)
        return samples
    }

    func removeModels() async throws {
        await unload()
        if FileManager.default.fileExists(atPath: Self.modelRoot.path) {
            try FileManager.default.removeItem(at: Self.modelRoot)
        }
        try? audioCache.removeAll()
    }

    func unload() async {
        generation += 1
        let task = preparation
        preparation = nil
        task?.cancel()
        finishNavigation(.failure(CancellationError()))
        let view = webView
        webView = nil
        view?.stopLoading()
        if let view {
            view.loadHTMLString("", baseURL: nil)
        }
        _ = try? await task?.value
    }

    private func loadModel(_ manifest: Manifest) async throws {
        var files = Dictionary(uniqueKeysWithValues: manifest.files.map {
            ($0.file.path, Self.modelRoot.appendingPathComponent($0.file.path))
        })
        for name in ["Phonon.html", "PhononAdapter.js", "PhononBindings.js", "PhononSIMD.wasm"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw NeuralTTSError.invalidModel
            }
            files[name] = url
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PhononResources(files: files), forURLScheme: "enve-phonon")
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            view.load(URLRequest(url: URL(string: "enve-phonon://local/Phonon.html")!))
        }
        _ = try await view.callAsyncJavaScript(
            "await import('enve-phonon://local/PhononAdapter.js'); await preparePhonon()",
            contentWorld: .page
        )
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        let continuation = navigation
        navigation = nil
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard self.webView === webView else { return }
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard self.webView === webView else { return }
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.webView(webView, didFail: navigation, withError: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        self.webView = nil
        finishNavigation(.failure(NeuralTTSError.notReady))
    }
}

private final class PhononResources: NSObject, WKURLSchemeHandler {
    private let files: [String: URL]

    init(files: [String: URL]) {
        self.files = files
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "local",
            task.request.httpMethod == nil || task.request.httpMethod == "GET",
            let file = files[String(url.path.dropFirst())],
            let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else {
            task.didFailWithError(NeuralTTSError.invalidModel)
            return
        }
        let mimeType: String
        switch file.pathExtension {
        case "html": mimeType = "text/html; charset=utf-8"
        case "js": mimeType = "text/javascript; charset=utf-8"
        case "wasm": mimeType = "application/wasm"
        default: mimeType = "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": mimeType,
            "Content-Length": String(data.count),
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff",
            "Access-Control-Allow-Origin": "*",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
final class PhononTTSEngine: @preconcurrency TTSEngine, @unchecked Sendable {
    var currentRate: Float

    nonisolated(unsafe) let availableVoices: [TTSVoice] = []

    private let voice: PhononVoice
    private let startAnchor: EbookTTSStartAnchor
    private let fallbackEngine: AnchoredAVTTSEngine
    private let audioPlayer = NeuralTTSAudioPlayer(sampleRate: 24_000, adjustsRate: true)

    init(voice: PhononVoice, rate: Float, startAnchor: EbookTTSStartAnchor) {
        self.voice = voice
        self.startAnchor = startAnchor
        currentRate = rate
        fallbackEngine = AnchoredAVTTSEngine(rate: rate, anchor: startAnchor)
    }

    func speak(
        _ utterance: TTSUtterance,
        onSpeakRange: @escaping (Range<String.Index>) -> Void
    ) async -> Result<Void, ReadiumNavigator.TTSError> {
        guard !Task.isCancelled else { return .success(()) }
        fallbackEngine.currentRate = currentRate
        guard utterance.language.code.bcp47.lowercased().split(separator: "-").first == "en" else {
            return await fallbackEngine.speak(utterance, onSpeakRange: onSpeakRange)
        }
        guard let slice = startAnchor.slice(for: utterance.text) else { return .success(()) }

        return await withTaskCancellationHandler {
            do {
                if utterance.delay > 0 {
                    try await Task.sleep(for: .seconds(utterance.delay))
                }
                let samples = try await PhononTTSRuntime.shared.synthesize(text: slice.spoken, voice: voice)
                try Task.checkCancellation()
                return await audioPlayer.play(samples, text: slice.spoken, rate: currentRate) {
                    onSpeakRange(slice.originalRange(for: $0))
                }
            } catch is CancellationError {
                return .success(())
            } catch {
                guard !Task.isCancelled else { return .success(()) }
                AppLogger.library.error("Phonon synthesis failed; using Apple speech: \(error)")
                return await fallbackEngine.speak(utterance, slice: slice, onSpeakRange: onSpeakRange)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.audioPlayer.cancel() }
        }
    }
}
#endif
