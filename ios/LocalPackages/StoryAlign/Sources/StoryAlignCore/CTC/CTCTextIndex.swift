import Foundation

struct CTCTextSentence: Sendable {
    let chapter: Int
    let sentence: Int
    let text: String
    let range: Range<Int>
}

struct CTCTextAnchor: Sendable {
    let character: Int
    let frame: Int
}

struct CTCDecodedText: Sendable {
    let labels: [Int]
    let frames: [Int]
}

struct CTCTextIndex {
    static let ngramLength = 10
    let labels: [Int]
    let sentences: [CTCTextSentence]
    private let ngrams: [UInt64: [Int]]

    init(chapters: [EpubManifestItem], vocabulary: [Character: Int]) {
        var labels: [Int] = []
        var sentences: [CTCTextSentence] = []
        let normalizer = WordNormalizer()
        normalizer.numberFormatter.locale = Locale(identifier: "en_US")
        for (chapter, item) in chapters.enumerated() {
            for (sentence, text) in item.xhtmlSentences.enumerated() {
                let start = labels.count
                let normalized = normalizer.normalizeWordsInSentence(text)
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
                    .replacingOccurrences(of: "’", with: "'")
                labels.append(contentsOf: normalized.compactMap { vocabulary[$0] })
                sentences.append(CTCTextSentence(chapter: chapter, sentence: sentence, text: text, range: start..<labels.count))
            }
        }
        var ngrams: [UInt64: [Int]] = [:]
        if labels.count >= Self.ngramLength {
            for position in stride(from: 0, through: labels.count - Self.ngramLength, by: 4) {
                let key = Self.key(labels, at: position)
                if ngrams[key, default: []].count < 8 { ngrams[key, default: []].append(position) }
            }
        }
        self.labels = labels
        self.sentences = sentences
        self.ngrams = ngrams
    }

    static func decode(_ emissions: CTCEmissions, blank: Int, space: Int?) -> CTCDecodedText {
        var previous = -1
        var labels: [Int] = []
        var frames: [Int] = []
        for frame in 0..<emissions.frames {
            let row = frame * emissions.classes
            var best = 0
            for label in 1..<emissions.classes where emissions.values[row + label] > emissions.values[row + best] { best = label }
            if best != previous, best != blank, best != space {
                labels.append(best)
                frames.append(frame)
            }
            previous = best
        }
        return CTCDecodedText(labels: labels, frames: frames)
    }

    func anchors(for decoded: CTCDecodedText) throws -> [CTCTextAnchor] {
        guard decoded.labels.count >= Self.ngramLength else { return [] }
        var matches: [(book: Int, decoded: Int)] = []
        var offsets: [Int: Int] = [:]
        for position in 0...(decoded.labels.count - Self.ngramLength) {
            if position.isMultiple(of: 64) { try Task.checkCancellation() }
            guard let locations = ngrams[Self.key(decoded.labels, at: position)], locations.count < 8 else { continue }
            for location in locations {
                matches.append((location, position))
                let bucket = Int(floor(Double(location - position) / 32))
                for neighbor in (bucket - 1)...(bucket + 1) { offsets[neighbor, default: 0] += 1 }
            }
        }
        guard let best = offsets.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }), best.value >= 3 else { return [] }
        let center = best.key * 32 + 16
        let competing = offsets.filter { abs($0.key - best.key) > 2 }.map(\.value).max() ?? 0
        guard competing * 4 < best.value * 3 else { return [] }
        let local = matches.filter { abs(($0.book - $0.decoded) - center) < 64 }.sorted { $0.decoded < $1.decoded }
        var anchors: [CTCTextAnchor] = []
        var lastDecoded = -Self.ngramLength
        for match in local {
            guard match.decoded >= lastDecoded + Self.ngramLength,
                  match.book > (anchors.last?.character ?? -1),
                  decoded.frames[match.decoded] > (anchors.last?.frame ?? -1)
            else { continue }
            anchors.append(CTCTextAnchor(character: match.book, frame: decoded.frames[match.decoded]))
            lastDecoded = match.decoded
        }
        return anchors.count >= 2 ? anchors : []
    }

    private static func key(_ labels: [Int], at start: Int) -> UInt64 {
        var result: UInt64 = 0
        for offset in 0..<ngramLength { result = (result << 5) | UInt64(labels[start + offset]) }
        return result
    }
}
