import Foundation
import NaturalLanguage

@MainActor
enum SentenceExtractor {

    private static let sharedTokenizer: NLTokenizer = NLTokenizer(unit: .sentence)

    static func enclosingSentence(before: String, word: String, after: String) -> String {
        let combined = before + word + after
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return word }

        let tokenizer = sharedTokenizer
        tokenizer.string = trimmed

        let target = word
        let searchRange = trimmed.range(of: target) ?? trimmed.startIndex..<trimmed.endIndex
        let targetMid = midIndex(of: searchRange, in: trimmed)

        var enclosing: Range<String.Index>? = nil
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            if range.contains(targetMid) || range.lowerBound == targetMid {
                enclosing = range
                return false
            }
            return true
        }

        guard let range = enclosing else { return trimmed }
        let sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.isEmpty ? trimmed : sentence
    }

    private static func midIndex(of range: Range<String.Index>, in s: String) -> String.Index {
        let lower = s.distance(from: s.startIndex, to: range.lowerBound)
        let upper = s.distance(from: s.startIndex, to: range.upperBound)
        let mid = lower + (upper - lower) / 2
        return s.index(s.startIndex, offsetBy: mid)
    }
}
