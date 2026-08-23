import Foundation

final class StarDictDictionary: @unchecked Sendable {

    struct Entry: Sendable {
        let word: String
        let offset: UInt64
        let size: UInt32
    }

    struct Definition: Sendable {
        let headword: String
        let definition: String
        let type: Character

        let matchedForm: String?
    }

    enum LoadError: Error {
        case ifoUnreadable
        case idxMissing
        case dictMissing
        case truncatedIndex
        case decompressionFailed
    }

    let ifoURL: URL
    let directory: URL
    let baseName: String

    private(set) var meta: [String: String] = [:]
    private(set) var entries: [Entry] = []

    private var normIndex: [String: [Int]] = [:]
    private var synIndex: [String: [Int]] = [:]
    private var dictBuffer: Data?
    private var loaded = false

    init(ifoURL: URL) {
        self.ifoURL = ifoURL
        self.directory = ifoURL.deletingLastPathComponent()
        self.baseName = ifoURL.deletingPathExtension().lastPathComponent
    }

    var name: String { meta["bookname"] ?? baseName }
    var wordCount: Int { Int(meta["wordcount"] ?? "") ?? entries.count }

    func load() throws {
        guard !loaded else { return }
        try parseIfo()
        try parseIdx()
        buildNormIndex()
        parseSyn()
        loaded = true
    }

    func lookup(_ word: String) -> [Definition] {
        guard loaded else { return [] }
        let key = StarDictMorphology.normalize(word)

        if let indices = synIndex[key], !indices.isEmpty {
            return indices.compactMap { readEntry(at: $0, matchedForm: nil) }
        }
        if let indices = normIndex[key], !indices.isEmpty {
            return indices.compactMap { readEntry(at: $0, matchedForm: nil) }
        }
        return []
    }

    func lookupFuzzy(_ word: String) -> [Definition] {
        guard loaded else { return [] }
        for candidate in StarDictMorphology.candidates(for: word) {
            let key = StarDictMorphology.normalize(candidate)
            if let indices = synIndex[key], !indices.isEmpty {
                return indices.compactMap { readEntry(at: $0, matchedForm: candidate) }
            }
            if let indices = normIndex[key], !indices.isEmpty {
                return indices.compactMap { readEntry(at: $0, matchedForm: candidate) }
            }
        }
        return []
    }

    func suggest(prefix rawPrefix: String, limit: Int = 10) -> [String] {
        guard loaded else { return [] }
        let prefix = StarDictMorphology.normalize(rawPrefix)
        var results: [String] = []
        for entry in entries {
            if StarDictMorphology.normalize(entry.word).hasPrefix(prefix) {
                results.append(entry.word)
                if results.count >= limit { break }
            }
        }
        return results
    }

    private func parseIfo() throws {
        guard let raw = try? String(contentsOf: ifoURL, encoding: .utf8) else {
            throw LoadError.ifoUnreadable
        }
        for line in raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
            meta[String(key)] = String(value)
        }
    }

    private func parseIdx() throws {
        let idxURL = directory.appendingPathComponent("\(baseName).idx")
        guard let buf = try? Data(contentsOf: idxURL) else {
            throw LoadError.idxMissing
        }
        let use64 = (Int(meta["idxoffsetbits"] ?? "") ?? 32) == 64
        let offsetBytes = use64 ? 8 : 4
        var pos = 0
        let count = buf.count

        while pos < count {

            var end = pos
            while end < count, buf[end] != 0 { end += 1 }
            if end >= count { break }
            let wordBytes = buf.subdata(in: pos..<end)
            guard let word = String(data: wordBytes, encoding: .utf8) else {
                pos = end + 1
                continue
            }
            pos = end + 1
            if pos + offsetBytes + 4 > count { break }

            let offset: UInt64
            if use64 {
                let hi = UInt64(readUInt32BE(buf, at: pos))
                let lo = UInt64(readUInt32BE(buf, at: pos + 4))
                offset = (hi << 32) | lo
            } else {
                offset = UInt64(readUInt32BE(buf, at: pos))
            }
            let size = readUInt32BE(buf, at: pos + offsetBytes)
            pos += offsetBytes + 4
            entries.append(Entry(word: word, offset: offset, size: size))
        }
    }

    private func buildNormIndex() {
        normIndex.removeAll(keepingCapacity: false)
        normIndex.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() {
            let key = StarDictMorphology.normalize(entry.word)
            normIndex[key, default: []].append(i)
        }
    }

    private func parseSyn() {
        let synURL = directory.appendingPathComponent("\(baseName).syn")
        guard let buf = try? Data(contentsOf: synURL) else { return }
        var pos = 0
        let count = buf.count
        while pos < count {
            var end = pos
            while end < count, buf[end] != 0 { end += 1 }
            if end >= count { break }
            let wordBytes = buf.subdata(in: pos..<end)
            guard let word = String(data: wordBytes, encoding: .utf8) else {
                pos = end + 1
                continue
            }
            pos = end + 1
            if pos + 4 > count { break }
            let idx = Int(readUInt32BE(buf, at: pos))
            pos += 4
            guard idx >= 0, idx < entries.count else { continue }
            let key = StarDictMorphology.normalize(word)
            synIndex[key, default: []].append(idx)
        }
    }

    private func loadDict() throws -> Data {
        if let buf = dictBuffer { return buf }
        let dictURL = directory.appendingPathComponent("\(baseName).dict")
        let dictDzURL = directory.appendingPathComponent("\(baseName).dict.dz")

        if FileManager.default.fileExists(atPath: dictDzURL.path) {
            guard let gzData = try? Data(contentsOf: dictDzURL),
                let inflated = StarDictGzip.decompress(gzData)
            else {
                throw LoadError.decompressionFailed
            }
            dictBuffer = inflated
            return inflated
        }
        if FileManager.default.fileExists(atPath: dictURL.path),
            let data = try? Data(contentsOf: dictURL)
        {
            dictBuffer = data
            return data
        }
        throw LoadError.dictMissing
    }

    private func readEntry(at index: Int, matchedForm: String?) -> Definition? {
        guard index >= 0, index < entries.count else { return nil }
        let entry = entries[index]
        guard let buf = try? loadDict() else { return nil }
        let start = Int(entry.offset)
        let end = start + Int(entry.size)
        guard end <= buf.count else { return nil }
        let slice = buf.subdata(in: start..<end)
        guard let text = String(data: slice, encoding: .utf8) else { return nil }
        let type = (meta["sametypesequence"] ?? "m").first ?? "m"
        return Definition(headword: entry.word, definition: text, type: type, matchedForm: matchedForm)
    }

    private func readUInt32BE(_ buf: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(buf[offset])
        let b1 = UInt32(buf[offset + 1])
        let b2 = UInt32(buf[offset + 2])
        let b3 = UInt32(buf[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
