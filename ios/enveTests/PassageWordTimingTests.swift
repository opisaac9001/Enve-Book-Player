import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PassageWordTimingTests {
    private static let sentence = "The lantern swung once, and the harbor went quiet."

    private static func mapping(text: String = sentence, words: [PassageWordTiming]? = nil, start: TimeInterval = 10, end: TimeInterval = 14) -> PassageMapping {
        PassageMapping(
            key: PassageSentenceKey(chapter: 0, sentence: 1), href: "OEBPS/c1.xhtml", text: text, before: "before.", after: "After",
            chapterProgression: 0.1, totalProgression: 0.05, trackIndex: 0, start: start, end: end,
            granularity: words == nil ? .sentence : .word, engine: "test", score: 1, words: words
        )
    }

    /// Back-to-back test timings for the printed words; real timings only ever come from a recognizer.
    private static func timings(_ text: String, from start: TimeInterval, step: TimeInterval, length: TimeInterval) -> [PassageWordTiming] {
        PassageWordMatcher.printedWords(text).enumerated().map { index, chunk in
            PassageWordTiming(location: chunk.location, length: chunk.length, start: start + Double(index) * step, end: start + Double(index) * step + length)
        }
    }

    @Test func wordsRoundTripAndSentenceOnlyFilesStillDecode() throws {
        let words = Self.timings(Self.sentence, from: 10, step: 0.4, length: 0.35)
        let mapping = Self.mapping(words: words)
        let decoded = try JSONDecoder().decode(PassageMapping.self, from: JSONEncoder().encode(mapping))
        #expect(decoded == mapping)
        #expect(decoded.words == words)

        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.mapping())) as? [String: Any])
        legacy.removeValue(forKey: "words")
        let old = try JSONDecoder().decode(PassageMapping.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.words == nil)
        #expect(old.granularity == .sentence)
    }

    @Test func malformedWordTimingsAreRejectedWhole() {
        let text = "Ok 👩‍👩‍👧 naïve café."
        let good = PassageWordTiming(location: 0, length: 2, start: 10, end: 10.3)
        let validated = { (words: [PassageWordTiming]) in PassageWordTiming.validated(words, in: text, start: 10, end: 14) }
        #expect(validated([good]) == [good])
        #expect(validated([]) == nil)
        #expect(validated([PassageWordTiming(location: 0, length: 200, start: 10, end: 10.3)]) == nil)
        #expect(validated([PassageWordTiming(location: -1, length: 2, start: 10, end: 10.3)]) == nil)
        #expect(validated([PassageWordTiming(location: 0, length: 0, start: 10, end: 10.3)]) == nil)
        // Inside the emoji's surrogate pairs and inside its grapheme cluster.
        #expect(validated([PassageWordTiming(location: 4, length: 2, start: 10, end: 10.3)]) == nil)
        #expect(validated([PassageWordTiming(location: 3, length: 2, start: 10, end: 10.3)]) == nil)
        // Punctuation only, reversed or non-finite time, outside the sentence, overlapping or out of order.
        #expect(validated([PassageWordTiming(location: text.utf16.count - 1, length: 1, start: 10, end: 10.3)]) == nil)
        #expect(validated([PassageWordTiming(location: 0, length: 2, start: 10.3, end: 10)]) == nil)
        #expect(validated([PassageWordTiming(location: 0, length: 2, start: .nan, end: 10)]) == nil)
        #expect(validated([PassageWordTiming(location: 0, length: 2, start: 9, end: 9.5)]) == nil)
        #expect(validated([good, PassageWordTiming(location: 1, length: 1, start: 10.4, end: 10.6)]) == nil)
        #expect(validated([PassageWordTiming(location: 12, length: 5, start: 11, end: 11.3), good]) == nil)
        #expect(validated([good, PassageWordTiming(location: 12, length: 5, start: 10.1, end: 10.4)]) == nil)
        // Only whole printed words: "O" inside "Ok" or "naïve café" across two words are not word targets.
        #expect(validated([PassageWordTiming(location: 0, length: 1, start: 10, end: 10.3)]) == nil)
        #expect(validated([PassageWordTiming(location: 12, length: 10, start: 10, end: 10.3)]) == nil)
        #expect(validated([PassageWordTiming(location: 12, length: 5, start: 10, end: 10.3)])?.count == 1)
    }

    @Test func extremeDecodedRangesNeverTrapAndKeepTheSentence() throws {
        let text = "Ok naïve café."
        for (location, length) in [(Int.max, 1), (1, Int.max), (Int.max, Int.max), (0, Int.max), (Int.min, 2), (2, Int.min), (Int.max - 1, 2)] {
            let word = PassageWordTiming(location: location, length: length, start: 10, end: 10.3)
            #expect(word.range(in: text) == nil)
            #expect(PassageWordTiming.validated([word], in: text, start: 10, end: 14) == nil)
            #expect(Self.mapping(text: text, words: [word]).locatorJSON(for: word) == nil)
        }
        let json = #"{"key":{"chapter":0,"sentence":1},"href":"OEBPS/c1.xhtml","text":"Ok naïve café.","before":"","after":"","chapterProgression":0.1,"totalProgression":0.05,"trackIndex":0,"start":10,"end":14,"granularity":"word","engine":"test","score":1,"words":[{"location":9223372036854775807,"length":9223372036854775807,"start":10,"end":10.3}]}"#
        let decoded = try JSONDecoder().decode(PassageMapping.self, from: Data(json.utf8))
        #expect(decoded.words.flatMap { PassageWordTiming.validated($0, in: decoded.text, start: decoded.start, end: decoded.end) } == nil)
        #expect(decoded.locatorJSON.contains("Ok naïve café."))
    }

    @Test func printedWordsAreLexicalWordsWithOriginalUTF16Ranges() throws {
        func printed(_ text: String) -> [String] {
            PassageWordMatcher.printedWords(text).map(\.text)
        }
        let text = "“Café”—naïve 👩‍👩‍👧 don’t well-known."
        #expect(printed(text) == ["Café", "naïve", "don’t", "well-known"])
        #expect(printed("harbor—Mira watched/waited,quietly; it's 3.5 miles—and the sea-wall held.") == [
            "harbor", "Mira", "watched", "waited", "quietly", "it's", "3.5", "miles", "and", "the", "sea-wall", "held",
        ])
        #expect(printed("— … 👩‍👩‍👧 !") == [])
        #expect(PassageWordMatcher.words("Café’s") == PassageWordMatcher.words("cafe's"))
        for word in PassageWordMatcher.printedWords(text) {
            #expect(String(text.utf16.dropFirst(word.location).prefix(word.length)) == word.text)
        }

        let words = Self.timings(text, from: 10, step: 0.5, length: 0.4)
        let mapping = Self.mapping(text: text, words: words)
        let locator = try #require(mapping.locatorJSON(for: words[2]))
        let quote = try #require(try JSONSerialization.jsonObject(with: Data(locator.utf8)) as? [String: Any])["text"] as? [String: String]
        #expect(quote?["highlight"] == "don’t")
        #expect(quote?["before"] == "“Café”—naïve 👩‍👩‍👧 ")
        let cafe = try #require(mapping.locatorJSON(for: words[0]))
        #expect(cafe.contains("\"highlight\":\"Café\""))
        #expect(quote?["after"] == " well-known.")
    }

    @Test func repeatedWordsKeepTheirOwnContext() throws {
        let text = "the cat saw the dog"
        let words = Self.timings(text, from: 10, step: 0.5, length: 0.4)
        let mapping = Self.mapping(text: text, words: words)
        let first = try #require(mapping.locatorJSON(for: words[0]))
        let second = try #require(mapping.locatorJSON(for: words[3]))
        #expect(first != second)
        #expect(first.contains("\"before\":\"before.\""))
        #expect(second.contains("\"before\":\"the cat saw \""))
    }

    @Test func theSpokenWordIsFoundOnlyInsideItsObservedSpan() {
        let words = Self.timings(Self.sentence, from: 10, step: 0.4, length: 0.35)
        let mapping = Self.mapping(words: words)
        #expect(mapping.word(at: 9.9) == nil)
        #expect(mapping.word(at: 10) == words[0])
        #expect(mapping.word(at: 10.34) == words[0])
        #expect(mapping.word(at: 10.37) == nil)
        #expect(mapping.word(at: 10.4) == words[1])
        #expect(mapping.word(at: 13.9) == nil)
        #expect(Self.mapping().word(at: 10.1) == nil)
    }

    @Test func onlyWordsWithTheirOwnObservedRunsAreTimed() throws {
        let sentences = [
            "The lantern swung once and the harbor went quiet.",
            "Café owners didn't open until the tide turned again.",
            "New York sailors waved at the the old pier tonight.",
        ]
        let matcher = PassageWordMatcher(sentences: sentences)
        var runs: [TranscribedWord] = []
        var clock = 1.0
        func say(_ text: String) {
            runs.append(TranscribedWord(text: text, start: clock, end: clock + 0.3))
            clock += 0.4
        }
        "The lantern swung once and the harbor went quiet".split(separator: " ").forEach { say(String($0)) }
        ["cafe", "owners", "didn't", "open", "until", "the", "tide", "turned", "again"].forEach(say)
        // The recognizer timed "New York" as one run: the pair is spoken, but neither word is timed alone.
        ["New York", "sailors", "waved", "at", "the", "the", "old", "pier", "tonight"].forEach(say)

        let matches = matcher.match(runs) { _ in true }
        #expect(matches.map(\.sentenceIndex) == [0, 1, 2])
        for match in matches {
            let words = try #require(match.words)
            #expect(PassageWordTiming.validated(words, in: sentences[match.sentenceIndex], start: match.start, end: match.end) == words)
            // Sentence boundaries are observed runs, never interpolated.
            #expect(words.last?.end == match.end)
        }
        #expect(matches[0].words?.first?.start == matches[0].start)
        let cafe = try #require(matches[1].words?.first)
        #expect(String(sentences[1].utf16.dropFirst(cafe.location).prefix(cafe.length)) == "Café")
        #expect(cafe.start == runs[9].start)
        let didnt = try #require(matches[1].words?[2])
        #expect(didnt.length == 6)
        #expect(didnt.start == runs[11].start)

        let third = try #require(matches[2].words)
        let printed = PassageWordMatcher.printedWords(sentences[2])
        #expect(!third.contains { $0.location == printed[0].location || $0.location == printed[1].location })
        let repeated = third.filter { $0.location == printed[5].location || $0.location == printed[6].location }
        #expect(repeated.count == 2)
        #expect(repeated[0].end <= repeated[1].start)
    }

    @Test func wordsSeparatedOnlyByPunctuationAreTimedSeparatelyAndAJointRunTimesNeither() throws {
        let sentence = "The harbor—Mira watched/waited, quietly counting every passing lantern tonight."
        let matcher = PassageWordMatcher(sentences: [sentence])
        let printed = PassageWordMatcher.printedWords(sentence)
        func runs(joining joined: Bool) -> [TranscribedWord] {
            let spoken = joined
                ? ["The", "harbor Mira", "watched", "waited", "quietly", "counting", "every", "passing", "lantern", "tonight"]
                : ["The", "harbor", "Mira", "watched", "waited", "quietly", "counting", "every", "passing", "lantern", "tonight"]
            return spoken.enumerated().map { TranscribedWord(text: $0.element, start: 1 + Double($0.offset) * 0.4, end: 1.3 + Double($0.offset) * 0.4) }
        }
        let separate = try #require(matcher.match(runs(joining: false)) { _ in true }.first?.words)
        #expect(separate.map(\.location) == printed.map(\.location))
        #expect(separate[1].start == 1.4 && separate[2].start == 1.8)

        let joined = try #require(matcher.match(runs(joining: true)) { _ in true }.first?.words)
        #expect(!joined.contains { $0.location == printed[1].location || $0.location == printed[2].location })
        #expect(joined.contains { $0.location == printed[3].location })
    }

    @Test func aWordWithoutATimedNeighborStaysUntimed() throws {
        let sentences = ["Bright harbor lights shimmered across water while gulls circled overhead."]
        let matcher = PassageWordMatcher(sentences: sentences)
        // Every other word is misrecognized, so no recognized word has a recognized neighbor.
        let spoken = ["Bright", "xx", "lights", "yy", "across", "zz", "while", "qq", "circled", "overhead"]
        let runs = spoken.enumerated().map { TranscribedWord(text: $0.element, start: 1 + Double($0.offset) * 0.4, end: 1.3 + Double($0.offset) * 0.4) }
        let match = try #require(matcher.match(runs) { _ in true }.first)
        let printed = PassageWordMatcher.printedWords(sentences[0])
        #expect(match.words?.map(\.location) == [printed[8].location, printed[9].location])
    }
}
