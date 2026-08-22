import Foundation

struct LinkedBookChapterLandmark: Codable, Equatable, Sendable {
    let title: String
    let progression: Double
}

struct LinkedBookChapterMatch: Equatable, Sendable {
    let ebookIndex: Int
    let audiobookIndex: Int
    let confidence: Double
}

enum LinkedBookChapterMapper {
    private struct NormalizedTitle {
        let text: String
        let tokens: Set<String>
        let chapterNumber: Int?
    }

    static func matches(
        ebookTitles: [String],
        audiobookTitles: [String]
    ) -> [LinkedBookChapterMatch] {
        guard !ebookTitles.isEmpty, !audiobookTitles.isEmpty else { return [] }

        let ebook = ebookTitles.map(normalize)
        let audio = audiobookTitles.map(normalize)
        if ebook.count * audio.count > 250_000 {
            return greedyMatches(ebook: ebook, audio: audio)
        }
        let rowCount = ebook.count + 1
        let columnCount = audio.count + 1
        var scores = Array(
            repeating: Array(repeating: 0.0, count: columnCount),
            count: rowCount
        )
        var decisions = Array(
            repeating: Array(repeating: UInt8(0), count: columnCount),
            count: rowCount
        )

        for ebookIndex in 1..<rowCount {
            for audioIndex in 1..<columnCount {
                let skipEbook = scores[ebookIndex - 1][audioIndex]
                let skipAudio = scores[ebookIndex][audioIndex - 1]
                let confidence = similarity(
                    ebook[ebookIndex - 1],
                    audio[audioIndex - 1]
                )
                let matched =
                    confidence >= 0.62
                    ? scores[ebookIndex - 1][audioIndex - 1] + confidence
                    : -.infinity

                if matched > skipEbook, matched > skipAudio {
                    scores[ebookIndex][audioIndex] = matched
                    decisions[ebookIndex][audioIndex] = 3
                } else if skipEbook >= skipAudio {
                    scores[ebookIndex][audioIndex] = skipEbook
                    decisions[ebookIndex][audioIndex] = 1
                } else {
                    scores[ebookIndex][audioIndex] = skipAudio
                    decisions[ebookIndex][audioIndex] = 2
                }
            }
        }

        var result: [LinkedBookChapterMatch] = []
        var ebookIndex = ebook.count
        var audioIndex = audio.count
        while ebookIndex > 0, audioIndex > 0 {
            switch decisions[ebookIndex][audioIndex] {
            case 3:
                let confidence = similarity(ebook[ebookIndex - 1], audio[audioIndex - 1])
                result.append(
                    LinkedBookChapterMatch(
                        ebookIndex: ebookIndex - 1,
                        audiobookIndex: audioIndex - 1,
                        confidence: confidence
                    )
                )
                ebookIndex -= 1
                audioIndex -= 1
            case 1:
                ebookIndex -= 1
            case 2:
                audioIndex -= 1
            default:
                ebookIndex -= 1
                audioIndex -= 1
            }
        }
        return result.reversed()
    }

    private static func greedyMatches(
        ebook: [NormalizedTitle],
        audio: [NormalizedTitle]
    ) -> [LinkedBookChapterMatch] {
        var result: [LinkedBookChapterMatch] = []
        var audioCursor = 0
        for ebookIndex in ebook.indices {
            guard audioCursor < audio.count else { break }
            let expected = Int(
                (Double(ebookIndex) / Double(max(ebook.count - 1, 1)))
                    * Double(max(audio.count - 1, 0))
            )
            let lowerBound = max(audioCursor, expected - 24)
            let upperBound = min(audio.count, max(lowerBound + 1, expected + 49))
            guard lowerBound < upperBound else { continue }

            var best: (index: Int, confidence: Double)?
            for audioIndex in lowerBound..<upperBound {
                let confidence = similarity(ebook[ebookIndex], audio[audioIndex])
                guard confidence >= 0.62 else { continue }
                if let current = best,
                    confidence < current.confidence
                        || (confidence == current.confidence
                            && abs(audioIndex - expected) >= abs(current.index - expected))
                {
                    continue
                } else {
                    best = (audioIndex, confidence)
                }
            }
            guard let best else { continue }
            result.append(
                LinkedBookChapterMatch(
                    ebookIndex: ebookIndex,
                    audiobookIndex: best.index,
                    confidence: best.confidence
                )
            )
            audioCursor = best.index + 1
        }
        return result
    }

    static func recommendedOffset(
        ebookTitles: [String],
        audiobookTitles: [String]
    ) -> Int? {
        let strongMatches = matches(
            ebookTitles: ebookTitles,
            audiobookTitles: audiobookTitles
        ).filter { $0.confidence >= 0.72 }
        guard strongMatches.count >= 2 else { return nil }

        let offsets = strongMatches.map { $0.audiobookIndex - $0.ebookIndex }
        let grouped = Dictionary(grouping: offsets, by: { $0 })
        guard
            let winner = grouped.max(by: {
                if $0.value.count == $1.value.count {
                    return abs($0.key) > abs($1.key)
                }
                return $0.value.count < $1.value.count
            })
        else {
            return nil
        }

        let requiredAgreement = max(2, Int(ceil(Double(strongMatches.count) * 0.6)))
        return winner.value.count >= requiredAgreement ? winner.key : nil
    }

    static func mappingConfidence(
        matches: [LinkedBookChapterMatch],
        ebookCount: Int,
        audiobookCount: Int
    ) -> Double {
        guard !matches.isEmpty, ebookCount > 0, audiobookCount > 0 else { return 0 }
        let coverage = Double(matches.count) / Double(min(ebookCount, audiobookCount))
        let average = matches.reduce(0) { $0 + $1.confidence } / Double(matches.count)
        return min(1, coverage * 0.55 + average * 0.45)
    }

    private static func normalize(_ raw: String) -> NormalizedTitle {
        let folded =
            raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let rawTokens =
            folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let ignored = Set([
            "a", "an", "the", "chapter", "chap", "ch", "part", "book",
            "section", "track", "disc", "disk", "volume", "vol",
            "kapitel", "teil", "chapitre", "partie", "capitulo", "parte",
            "capitolo", "hoofdstuk", "rozdzial",
        ])
        let numbered = chapterNumber(in: rawTokens, markers: ignored)
        let meaningful: [String] = rawTokens.enumerated().compactMap { index, token -> String? in
            guard !ignored.contains(token),
                !numbered.tokenIndices.contains(index)
            else {
                return nil
            }
            return token
        }
        let text = meaningful.joined(separator: " ")
        return NormalizedTitle(
            text: text,
            tokens: Set(meaningful),
            chapterNumber: numbered.value
        )
    }

    private static func similarity(
        _ lhs: NormalizedTitle,
        _ rhs: NormalizedTitle
    ) -> Double {
        if let lhsNumber = lhs.chapterNumber,
            let rhsNumber = rhs.chapterNumber,
            lhsNumber != rhsNumber
        {
            return 0
        }

        let numberScore: Double = {
            switch (lhs.chapterNumber, rhs.chapterNumber) {
            case let (lhs?, rhs?) where lhs == rhs:
                return 1
            case (nil, nil):
                return 0
            default:
                return 0.15
            }
        }()

        if !lhs.text.isEmpty, lhs.text == rhs.text {
            return max(0.94, numberScore)
        }

        let union = lhs.tokens.union(rhs.tokens)
        let tokenScore =
            union.isEmpty
            ? 0
            : Double(lhs.tokens.intersection(rhs.tokens).count) / Double(union.count)
        let editScore = normalizedEditSimilarity(lhs.text, rhs.text)

        if lhs.text.isEmpty, rhs.text.isEmpty {
            return numberScore
        }
        return min(1, tokenScore * 0.5 + editScore * 0.35 + numberScore * 0.15)
    }

    private static func normalizedEditSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs)
        let right = Array(rhs)
        let maximumLength = max(left.count, right.count)
        guard maximumLength > 0 else { return 0 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(maximumLength)
    }

    private static func chapterNumber(
        in tokens: [String],
        markers: Set<String>
    ) -> (value: Int?, tokenIndices: Set<Int>) {
        for (index, token) in tokens.enumerated() {
            let isMarked = index > 0 && markers.contains(tokens[index - 1])
            let isLeadingNumeral = index == 0 && (Int(token) != nil || tokens.count == 1)
            guard isMarked || isLeadingNumeral else { continue }

            if let value = Int(token), value > 0 {
                return (value, [index])
            }
            if let tens = tensWords[token],
                tokens.indices.contains(index + 1),
                let ones = unitWords[tokens[index + 1]]
            {
                return (tens + ones, [index, index + 1])
            }
            if let value = numberWords[token] {
                return (value, [index])
            }
            if let value = romanNumeral(token) {
                return (value, [index])
            }
        }
        return (nil, [])
    }

    private static func romanNumeral(_ token: String) -> Int? {
        guard token.count <= 8,
            token.allSatisfy({ "ivxlcdm".contains($0) })
        else {
            return nil
        }
        let values: [Character: Int] = [
            "i": 1, "v": 5, "x": 10, "l": 50,
            "c": 100, "d": 500, "m": 1_000,
        ]
        var total = 0
        var previous = 0
        for character in token.reversed() {
            guard let value = values[character] else { return nil }
            if value < previous {
                total -= value
            } else {
                total += value
                previous = value
            }
        }
        guard total > 0, romanString(for: total) == token else { return nil }
        return total
    }

    private static func romanString(for rawValue: Int) -> String {
        var value = rawValue
        var result = ""
        for (number, numeral) in [
            (1_000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
            (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
            (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
        ] {
            while value >= number {
                result += numeral
                value -= number
            }
        }
        return result
    }

    private static let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
        "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80,
        "ninety": 90,
    ]

    private static let tensWords: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let unitWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
}
