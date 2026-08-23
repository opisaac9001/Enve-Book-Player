import Foundation
import Logging

@MainActor
final class DefinitionLookupService {
    static let shared = DefinitionLookupService()

    private var memoryCache: [String: String?] = [:]
    private var inflight: [String: Task<String?, Never>] = [:]

    private let cacheRoot: URL

    private init() {
        let appSupport =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheRoot = appSupport.appendingPathComponent("Enve/DefinitionCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    func definition(for rawWord: String, language: String? = nil) async -> String? {
        let word = normalize(rawWord)
        guard !word.isEmpty else { return nil }
        let lang = languageTag(from: language)
        let key = "\(lang):\(word)"

        if let cached = memoryCache[key] { return cached }
        if let task = inflight[key] { return await task.value }

        if let starDictHit = formatStarDict(InstalledDictionariesStore.shared.lookup(word)) {
            memoryCache[key] = starDictHit
            writeDisk(lang: lang, word: word, definition: starDictHit)
            return starDictHit
        }

        if let onDisk = readDisk(lang: lang, word: word) {
            memoryCache[key] = onDisk.value
            return onDisk.value
        }

        let task = Task { [lang, word] in
            await fetchOnline(word: word, lang: lang)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        memoryCache[key] = result
        writeDisk(lang: lang, word: word, definition: result)
        return result
    }

    func cached(for rawWord: String, language: String? = nil) -> String? {
        let word = normalize(rawWord)
        let lang = languageTag(from: language)
        if let cached = memoryCache["\(lang):\(word)"] { return cached }
        return readDisk(lang: lang, word: word)?.value
    }

    private func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func languageTag(from raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "en" }
        return String(raw.prefix(2)).lowercased()
    }

    private struct DiskResult { let value: String? }

    private func cacheURL(lang: String, word: String) -> URL {
        let dir = cacheRoot.appendingPathComponent(lang, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = word.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).txt", isDirectory: false)
    }

    private func readDisk(lang: String, word: String) -> DiskResult? {
        let url = cacheURL(lang: lang, word: word)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = (try? Data(contentsOf: url)) ?? Data()
        if data.isEmpty { return DiskResult(value: nil) }
        return DiskResult(value: String(data: data, encoding: .utf8))
    }

    private func writeDisk(lang: String, word: String, definition: String?) {
        let url = cacheURL(lang: lang, word: word)
        let data = (definition ?? "").data(using: .utf8) ?? Data()
        try? data.write(to: url, options: .atomic)
    }

    private struct DictionaryEntry: Decodable {
        let meanings: [Meaning]?
        struct Meaning: Decodable {
            let partOfSpeech: String?
            let definitions: [Definition]?
            struct Definition: Decodable { let definition: String? }
        }
    }

    private func fetchOnline(word: String, lang: String) async -> String? {
        guard let escaped = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
            let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/\(lang)/\(escaped)")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let entries = try JSONDecoder().decode([DictionaryEntry].self, from: data)
            return formatDefinition(from: entries)
        } catch {
            AppLogger.network.warning("DefinitionLookupService fetch failed for \(word): \(error.localizedDescription)")
            return nil
        }
    }

    private func formatStarDict(_ hit: StarDictDictionary.Definition?) -> String? {
        guard let hit, !hit.definition.isEmpty else { return nil }

        let raw = hit.definition
        let cleaned: String
        switch hit.type {
        case "h", "g":
            cleaned = stripMarkup(raw)
        default:
            cleaned = raw
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stripMarkup(_ s: String) -> String {

        let tagless = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entitiesDecoded =
            tagless
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let collapsed = entitiesDecoded.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
    }

    private func formatDefinition(from entries: [DictionaryEntry]) -> String? {
        var lines: [String] = []
        var seen = Set<String>()
        outer: for entry in entries {
            for meaning in entry.meanings ?? [] {
                guard
                    let first = meaning.definitions?.first?.definition?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    !first.isEmpty
                else { continue }
                let pos = meaning.partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let line = pos.isEmpty ? first : "(\(pos)) \(first)"
                if seen.insert(line).inserted {
                    lines.append(line)
                    if lines.count >= 3 { break outer }
                }
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
