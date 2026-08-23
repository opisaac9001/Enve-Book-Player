import Foundation

#if os(iOS)
import FoundationModels
#endif

protocol LibrarianBackend {
    var id: String { get }
    var displayName: String { get }
    var contextBudgetCharacters: Int { get }
    var keepsDataOnDevice: Bool { get }
    func availabilityMessage() -> String?
    func answer(instructions: String, prompt: String, history: [LibrarianMessage]) async throws -> String
}

final class FoundationModelsLibrarianBackend: LibrarianBackend {
    static let shared = FoundationModelsLibrarianBackend()
    private init() {}

    let id = "apple"
    let displayName = "Apple Intelligence"

    let contextBudgetCharacters = 7_000
    let keepsDataOnDevice = true

    func availabilityMessage() -> String? {
        #if os(iOS)
        guard #available(iOS 26.0, *) else {
            return "Apple Intelligence requires iOS 26 or later. Connect a local server in Settings to use the Librarian on this device."
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return
                "Apple Intelligence requires newer iPhone hardware. Connect a local server in Settings to use the Librarian on this device."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use Enve Librarian."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing its on-device model."
        @unknown default:
            return "Apple Intelligence is not available right now."
        }
        #else
        return "Enve Librarian requires iOS."
        #endif
    }

    func answer(instructions: String, prompt: String, history: [LibrarianMessage]) async throws -> String {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { throw EnveLibrarianError.backendUnavailable("Apple Intelligence requires iOS 26 or later.") }
        if let message = availabilityMessage() { throw EnveLibrarianError.backendUnavailable(message) }

        let fullPrompt = [historyBlock(history), prompt]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        do {
            let content = try await Task.withTimeout(seconds: 45) {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: fullPrompt)
                return response.content
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as URLError where error.code == .timedOut {
            throw EnveLibrarianError.responseTimedOut
        } catch let error as LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error { throw EnveLibrarianError.contextTooLarge }
            throw error
        }
        #else
        throw EnveLibrarianError.backendUnavailable("Enve Librarian requires iOS.")
        #endif
    }

    private func historyBlock(_ history: [LibrarianMessage]) -> String {
        let turns = history.suffix(6)
        guard !turns.isEmpty else { return "" }
        let lines = turns.map { "\($0.role == .user ? "User" : "Enve"): \($0.text)" }
        return "Conversation so far:\n" + lines.joined(separator: "\n")
    }
}

final class OpenAICompatibleLibrarianBackend: LibrarianBackend {
    static let shared = OpenAICompatibleLibrarianBackend()
    private init() {}

    let id = "server"
    let displayName = "Local Server"
    let contextBudgetCharacters = 24_000
    let keepsDataOnDevice = false

    private var settings: BookIntelligenceSettingsStore { .shared }

    func availabilityMessage() -> String? {
        settings.librarianServerConfigured
            ? nil
            : "Add a server URL and model in Settings › Playback › Librarian."
    }

    func answer(instructions: String, prompt: String, history: [LibrarianMessage]) async throws -> String {
        guard let baseURL = settings.librarianServerBaseURL, settings.librarianServerConfigured else {
            throw EnveLibrarianError.backendUnavailable("Add a server URL and model in Settings › Playback › Librarian.")
        }
        var messages: [WireMessage] = [WireMessage(role: "system", content: instructions)]
        messages += history.suffix(8).map {
            WireMessage(role: $0.role == .user ? "user" : "assistant", content: $0.text)
        }
        messages.append(WireMessage(role: "user", content: prompt))

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try JSONEncoder().encode(
            WireRequest(
                model: settings.librarianServerModel,
                messages: messages,
                stream: true,
                temperature: 0.2,
                max_tokens: 800,
                reasoning_effort: "none"
            )
        )

        let (bytes, response) = try await Self.makeSession().bytes(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw EnveLibrarianError.backendUnavailable(
                "The local server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)."
            )
        }

        var answer = ""
        for try await line in bytes.lines {
            let payload =
                line.hasPrefix("data:")
                ? line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                : line.trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                let content = chunk.choices.first?.delta.content
            else { continue }
            answer += content
        }
        let cleaned = Self.strippingThinkBlocks(answer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw EnveLibrarianError.backendUnavailable("The local server did not return an answer.")
        }
        return cleaned
    }

    func availableModels() async throws -> [String] {
        guard let baseURL = settings.librarianServerBaseURL else {
            throw EnveLibrarianError.backendUnavailable("Enter a server URL first.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        authorize(&request)
        let (data, response) = try await Self.makeSession().data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw EnveLibrarianError.backendUnavailable(
                "The local server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)."
            )
        }
        return try JSONDecoder().decode(ModelsResponse.self, from: data).data.map(\.id)
    }

    private func authorize(_ request: inout URLRequest) {
        if let key = settings.librarianServerAPIKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg)
    }

    private static func strippingThinkBlocks(_ text: String) -> String {
        text
            .replacingOccurrences(of: "(?is)<think\\b[^>]*>.*?</think>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<think\\b[^>]*>.*$", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "(?is)</?think\\b[^>]*>", with: " ", options: .regularExpression)
    }

    private struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct WireRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let temperature: Double
        let max_tokens: Int

        let reasoning_effort: String
    }

    private struct ModelsResponse: Decodable {
        struct Entry: Decodable { let id: String }
        let data: [Entry]
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }
}

func normalizedLibrarianServerURL(_ raw: String) -> URL? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    if !value.contains("://") { value = "http://" + value }
    while value.hasSuffix("/") { value.removeLast() }
    if !value.hasSuffix("/v1") { value += "/v1" }
    return URL(string: value)
}
