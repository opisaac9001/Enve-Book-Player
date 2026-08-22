import Foundation
import Logging

struct MatchScore: Sendable {
    let total: Double
    let durationScore: Double
    let titleScore: Double
    let authorScore: Double
    let hasDuration: Bool
    let requiresManualReview: Bool

    static let W_DURATION: Double = 0.7
    static let W_TITLE: Double = 0.2
    static let W_AUTHOR: Double = 0.1
    static let DEFAULT_DURATION_SCORE_MISSING_INFO: Double = 0.1

    var isHighConfidence: Bool { total >= 0.85 && !requiresManualReview }
    var isMediumConfidence: Bool { total >= 0.70 && total < 0.85 }
    var isLowConfidence: Bool { total < 0.70 }

    var formattedTotal: String {
        return String(format: "%.0f%%", total * 100)
    }

    var displayPercentage: Int {
        return Int(round(total * 100))
    }

    var confidenceLevel: String {
        if isHighConfidence { return "High" }
        if isMediumConfidence { return "Medium" }
        return "Low"
    }
}

enum MatchingUtils {

    static func calculateScore(
        file: FileMetadataLayer,
        audible: AudibleSearchResult
    ) -> MatchScore {
        if let fileASIN = file.asin,
            !fileASIN.isEmpty,
            fileASIN.uppercased() == audible.asin.uppercased()
        {
            let hasDuration = (file.duration ?? 0) > 0 && audible.duration > 0
            let requiresManualReview = !hasDuration || calculateDurationDiffMinutes(file: file, audible: audible) > 10

            return MatchScore(
                total: 1.0,
                durationScore: 1.0,
                titleScore: 1.0,
                authorScore: 1.0,
                hasDuration: hasDuration,
                requiresManualReview: requiresManualReview
            )
        }

        let durationScore = calculateDurationScore(
            localDurationSeconds: file.duration ?? 0,
            audibleDurationSeconds: TimeInterval(audible.duration)
        )

        let titleToMatch: String
        if let folderName = file.folderName, !folderName.isEmpty {
            titleToMatch = folderName
        } else if let fileName = file.fileName, !fileName.isEmpty {
            titleToMatch = fileName
        } else {
            titleToMatch = file.title ?? ""
        }

        var effectiveTitleScore = calculateTitleScore(queryTitle: titleToMatch, bookTitle: audible.title)

        if let seriesName = audible.seriesName, !seriesName.isEmpty {
            let seriesScore = calculateTitleScore(queryTitle: titleToMatch, bookTitle: seriesName)
            if seriesScore > effectiveTitleScore {
                effectiveTitleScore = min(1.0, seriesScore + 0.1)
                AppLogger.library.info(
                    "Series Match Bonus: '\(titleToMatch)' matches series '\(seriesName)' (score: \(String(format: "%.2f", seriesScore)) -> \(String(format: "%.2f", effectiveTitleScore)))"
                )
            }
        }

        let titleScore = effectiveTitleScore

        let authorScore = calculateAuthorScore(
            queryAuthor: file.author ?? "",
            bookAuthors: audible.authors
        )

        let baseConfidence = MatchScore.W_DURATION * durationScore + MatchScore.W_TITLE * titleScore + MatchScore.W_AUTHOR * authorScore

        let seriesPenalty = calculateSeriesNumberPenalty(
            localTitle: titleToMatch,
            localFileName: file.fileName ?? "",
            resultTitle: audible.title,
            localSeriesNumber: file.seriesNumber
        )

        let confidence = max(0.0, baseConfidence + seriesPenalty)

        let clampedConfidence = max(0.0, min(1.0, confidence))

        let hasDuration = (file.duration ?? 0) > 0 && audible.duration > 0
        let durationDiffMinutes = calculateDurationDiffMinutes(file: file, audible: audible)
        let requiresManualReview = !hasDuration || durationDiffMinutes > 10.0

        let sourceDiagnosticID = DiagnosticLogSanitizer.identifier(
            for: [file.title, file.fileName, file.author].compactMap { $0 }.joined(separator: "|")
        )
        let resultDiagnosticID = DiagnosticLogSanitizer.identifier(
            for: ([audible.title] + audible.authors).joined(separator: "|")
        )

        AppLogger.library.debug("ABS-style score breakdown sourceId=\(sourceDiagnosticID) resultId=\(resultDiagnosticID)")
        AppLogger.library.debug(
            "Duration: \(String(format: "%.2f", durationScore)) (diff: \(String(format: "%.1f", durationDiffMinutes)) min)"
        )
        AppLogger.library.debug("Title: \(String(format: "%.2f", titleScore))")
        AppLogger.library.debug("Author: \(String(format: "%.2f", authorScore))")
        if seriesPenalty != 0 {
            AppLogger.library.debug("Series Penalty: \(String(format: "%.2f", seriesPenalty)) (mismatch detected)")
        }
        AppLogger.library.debug(
            "Weighted: (\(String(format: "%.1f", MatchScore.W_DURATION * 100))%×\(String(format: "%.2f", durationScore))) + (\(String(format: "%.1f", MatchScore.W_TITLE * 100))%×\(String(format: "%.2f", titleScore))) + (\(String(format: "%.1f", MatchScore.W_AUTHOR * 100))%×\(String(format: "%.2f", authorScore)))"
        )
        AppLogger.library.info("CONFIDENCE: \(String(format: "%.0f", clampedConfidence * 100))%")

        return MatchScore(
            total: clampedConfidence,
            durationScore: durationScore,
            titleScore: titleScore,
            authorScore: authorScore,
            hasDuration: hasDuration,
            requiresManualReview: requiresManualReview
        )
    }

    static func calculateScore(
        file: FileMetadataLayer,
        iTunes: iTunesAudiobook
    ) -> MatchScore {
        let durationScore = MatchScore.DEFAULT_DURATION_SCORE_MISSING_INFO

        let titleToMatch: String
        if let folderName = file.folderName, !folderName.isEmpty {
            titleToMatch = folderName
        } else if let fileName = file.fileName, !fileName.isEmpty {
            titleToMatch = fileName
        } else {
            titleToMatch = file.title ?? ""
        }

        let iTunesTitle = iTunes.trackCensoredName ?? iTunes.trackName ?? iTunes.collectionCensoredName ?? iTunes.collectionName ?? ""
        let titleScore = calculateTitleScore(queryTitle: titleToMatch, bookTitle: iTunesTitle)

        let iTunesAuthors = iTunes.artistName.map { [$0] } ?? []
        let authorScore = calculateAuthorScore(queryAuthor: file.author ?? "", bookAuthors: iTunesAuthors)

        let confidence = MatchScore.W_DURATION * durationScore + MatchScore.W_TITLE * titleScore + MatchScore.W_AUTHOR * authorScore

        let clampedConfidence = max(0.0, min(1.0, confidence))

        return MatchScore(
            total: clampedConfidence,
            durationScore: durationScore,
            titleScore: titleScore,
            authorScore: authorScore,
            hasDuration: false,
            requiresManualReview: true
        )
    }

    static func calculateBookScore(
        file: FileMetadataLayer,
        title: String,
        authors: [String],
        isbn: String? = nil
    ) -> MatchScore {
        if let fileISBN = file.isbn?.trimmingCharacters(in: .whitespacesAndNewlines),
            let isbn = isbn?.trimmingCharacters(in: .whitespacesAndNewlines),
            !fileISBN.isEmpty,
            fileISBN.caseInsensitiveCompare(isbn) == .orderedSame
        {
            return MatchScore(
                total: 1.0,
                durationScore: 1.0,
                titleScore: 1.0,
                authorScore: 1.0,
                hasDuration: false,
                requiresManualReview: false
            )
        }

        let titleToMatch: String
        if let folderName = file.folderName, !folderName.isEmpty {
            titleToMatch = folderName
        } else if let fileName = file.fileName, !fileName.isEmpty {
            titleToMatch = fileName
        } else {
            titleToMatch = file.title ?? ""
        }

        let titleScore = calculateTitleScore(queryTitle: titleToMatch, bookTitle: title)
        let authorScore = calculateAuthorScore(queryAuthor: file.author ?? "", bookAuthors: authors)
        let total = max(0.0, min(1.0, (0.75 * titleScore) + (0.25 * authorScore)))

        return MatchScore(
            total: total,
            durationScore: 1.0,
            titleScore: titleScore,
            authorScore: authorScore,
            hasDuration: false,
            requiresManualReview: false
        )
    }

    private static func calculateSeriesNumberPenalty(
        localTitle: String,
        localFileName: String,
        resultTitle: String,
        localSeriesNumber: Int?
    ) -> Double {
        let localNumbers = extractSeriesNumbers(from: localTitle) + extractSeriesNumbers(from: localFileName)
        let resultNumbers = extractSeriesNumbers(from: resultTitle)

        var allLocalNumbers = Set(localNumbers)
        if let sn = localSeriesNumber, sn > 0 {
            allLocalNumbers.insert(sn)
        }

        if allLocalNumbers.isEmpty || resultNumbers.isEmpty {
            return 0.0
        }

        let resultNumberSet = Set(resultNumbers)
        if resultNumbers.count > 1 {
            if let localNum = allLocalNumbers.first,
                let minResult = resultNumbers.min(),
                let maxResult = resultNumbers.max(),
                localNum >= minResult && localNum <= maxResult
            {
                AppLogger.library.info("Possible omnibus: local=\(localNum), result range=\(minResult)-\(maxResult)")
                return -0.05
            }
        }

        let matchingNumbers = allLocalNumbers.intersection(resultNumberSet)

        if !matchingNumbers.isEmpty {
            AppLogger.library.info("Series number match: \(matchingNumbers)")
            return 0.0
        } else {
            AppLogger.library.info("SERIES MISMATCH: local=\(Array(allLocalNumbers)), result=\(resultNumbers)")
            return -0.30
        }
    }

    private static func extractSeriesNumbers(from text: String) -> [Int] {
        var numbers: [Int] = []

        let lowercased = text.lowercased()

        let romanNumbers = extractRomanNumerals(from: text)
        numbers.append(contentsOf: romanNumbers)

        let writtenNumbers = extractWrittenNumbers(from: lowercased)
        numbers.append(contentsOf: writtenNumbers)

        let seriesPatterns = [
            "\\b(?:book|bk)\\.?\\s*(\\d+)",
            "\\bvol(?:ume)?\\.?\\s*(\\d+)",
            "\\b(?:part|pt)\\.?\\s*(\\d+)",
            "#(\\d+)",
            "\\b(?:episode|chapter|issue|season)\\s*(\\d+)",
        ]

        for pattern in seriesPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lowercased.startIndex..., in: lowercased)
                let matches = regex.matches(in: lowercased, options: [], range: range)

                for match in matches {
                    if match.numberOfRanges > 1,
                        let numRange = Range(match.range(at: 1), in: lowercased),
                        let num = Int(lowercased[numRange])
                    {
                        if num > 0 && num < 200 {
                            numbers.append(num)
                        }
                    }
                }
            }
        }

        var seen = Set<Int>()
        return numbers.filter { seen.insert($0).inserted }
    }

    private static func extractRomanNumerals(from text: String) -> [Int] {
        var numbers: [Int] = []

        let pattern = "(?:book|vol(?:ume)?|part|chapter|episode|#|:\\s*)\\s*([IVXLCDM]+)\\b"

        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: range)

            for match in matches {
                if match.numberOfRanges > 1,
                    let romanRange = Range(match.range(at: 1), in: text)
                {
                    let romanStr = String(text[romanRange]).uppercased()
                    if let value = romanToInt(romanStr), value > 0 && value < 100 {
                        numbers.append(value)
                    }
                }
            }
        }

        return numbers
    }

    private static func romanToInt(_ roman: String) -> Int? {
        let values: [Character: Int] = [
            "I": 1, "V": 5, "X": 10, "L": 50,
            "C": 100, "D": 500, "M": 1000,
        ]

        var result = 0
        var prev = 0

        for char in roman.reversed() {
            guard let value = values[char] else { return nil }
            if value < prev {
                result -= value
            } else {
                result += value
            }
            prev = value
        }

        return result > 0 && result < 100 ? result : nil
    }

    private static func extractWrittenNumbers(from text: String) -> [Int] {
        let writtenNumbers: [String: Int] = [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
            "twenty-one": 21, "twenty-two": 22, "twenty-three": 23, "twenty-four": 24, "twenty-five": 25,
        ]

        var numbers: [Int] = []

        for (word, value) in writtenNumbers {
            let pattern = "(?:book|vol(?:ume)?|part|chapter|episode)\\s+\(word)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    numbers.append(value)
                }
            }
        }

        return numbers
    }

    private static func calculateDurationScore(
        localDurationSeconds: TimeInterval,
        audibleDurationSeconds: TimeInterval
    ) -> Double {
        if localDurationSeconds == 0 || audibleDurationSeconds == 0 {
            return MatchScore.DEFAULT_DURATION_SCORE_MISSING_INFO
        }

        let localMinutes = localDurationSeconds / 60.0
        let audibleMinutes = audibleDurationSeconds / 60.0
        let durationDiff = Swift.abs(audibleMinutes - localMinutes)

        if durationDiff <= 1 {
            return 1.0
        } else if durationDiff <= 5 {
            return 1.1 - 0.1 * durationDiff
        } else if durationDiff <= 10 {
            return 1.2 - 0.12 * durationDiff
        } else {
            return 0.0
        }
    }

    private static func calculateDurationDiffMinutes(file: FileMetadataLayer, audible: AudibleSearchResult) -> Double {
        let localSeconds = file.duration ?? 0
        let audibleSeconds = TimeInterval(audible.duration)
        return Swift.abs(audibleSeconds - localSeconds) / 60.0
    }

    private static func calculateTitleScore(queryTitle: String, bookTitle: String) -> Double {
        let queryHasSubtitle = hasSubtitle(queryTitle)

        let scoreWithSubtitle = calculateTitleScoreInternal(
            queryTitle: queryTitle,
            bookTitle: bookTitle,
            keepSubtitle: true
        )

        if queryHasSubtitle {
            let scoreWithoutSubtitle = calculateTitleScoreInternal(
                queryTitle: queryTitle,
                bookTitle: bookTitle,
                keepSubtitle: false
            )
            return max(scoreWithSubtitle, scoreWithoutSubtitle)
        }

        return scoreWithSubtitle
    }

    private static func calculateTitleScoreInternal(
        queryTitle: String,
        bookTitle: String,
        keepSubtitle: Bool
    ) -> Double {
        let cleanBookTitle = cleanTitleForCompares(bookTitle, keepSubtitle: keepSubtitle)
        let cleanQueryTitle = cleanTitleForCompares(queryTitle, keepSubtitle: keepSubtitle)

        if cleanQueryTitle.isEmpty || cleanBookTitle.isEmpty {
            return 0.0
        }

        return levenshteinSimilarity(cleanQueryTitle, cleanBookTitle)
    }

    private static func hasSubtitle(_ title: String) -> Bool {
        return title.contains(":") || title.contains(" - ")
    }

    private static func calculateAuthorScore(queryAuthor: String, bookAuthors: [String]) -> Double {
        let normalizedQueryAuthor = cleanAuthorForCompares(queryAuthor)

        if normalizedQueryAuthor.isEmpty {
            return 1.0
        }

        if bookAuthors.isEmpty {
            return 0.0
        }

        let combinedBookAuthor = bookAuthors.joined(separator: ", ")
        let normalizedBookAuthor = cleanAuthorForCompares(combinedBookAuthor)

        if normalizedBookAuthor.isEmpty {
            return 0.0
        }

        let bookAuthorParts =
            normalizedBookAuthor
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }

        if bookAuthorParts.isEmpty {
            return 0.0
        }

        var maxScore = levenshteinSimilarity(normalizedQueryAuthor, normalizedBookAuthor)

        for part in bookAuthorParts {
            let similarity = levenshteinSimilarity(normalizedQueryAuthor, part)
            maxScore = max(maxScore, similarity)
        }

        return maxScore
    }

    static func cleanTitleForCompares(_ title: String, keepSubtitle: Bool = false) -> String {
        var cleaned = title

        if !keepSubtitle {
            if let colonIndex = cleaned.firstIndex(of: ":") {
                cleaned = String(cleaned[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            } else if let dashRange = cleaned.range(of: " - ") {
                cleaned = String(cleaned[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }

        cleaned = cleaned.replacingOccurrences(
            of: "\\([^)]*\\)",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: "\\[[^\\]]*\\]",
            with: "",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(of: "'", with: "")

        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        cleaned = cleaned.folding(options: .diacriticInsensitive, locale: nil)

        return cleaned.lowercased()
    }

    static func cleanAuthorForCompares(_ author: String) -> String {
        var cleaned = author

        cleaned = cleaned.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        cleaned = cleaned.folding(options: .diacriticInsensitive, locale: nil)

        cleaned = cleaned.replacingOccurrences(
            of: "([a-zA-Z])\\.([a-zA-Z])",
            with: "$1. $2",
            options: .regularExpression
        )

        cleaned = cleaned.replacingOccurrences(
            of: " et al\\.?",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        return cleaned.lowercased()
    }

    static func levenshteinSimilarity(_ str1: String, _ str2: String, caseSensitive: Bool = false) -> Double {
        var s1 = str1
        var s2 = str2

        if !caseSensitive {
            s1 = s1.lowercased()
            s2 = s2.lowercased()
        }

        if s1 == s2 { return 1.0 }

        let distance = levenshteinDistance(s1, s2)
        let maxLength = max(s1.count, s2.count)

        if maxLength == 0 { return 1.0 }

        return 1.0 - (Double(distance) / Double(maxLength))
    }

    static func levenshteinDistance(_ str1: String, _ str2: String) -> Int {
        let s1 = Array(str1)
        let s2 = Array(str2)

        if s1.isEmpty { return s2.count }
        if s2.isEmpty { return s1.count }

        var track = [[Int]](repeating: [Int](repeating: 0, count: s1.count + 1), count: s2.count + 1)

        for i in 0...s1.count {
            track[0][i] = i
        }

        for j in 0...s2.count {
            track[j][0] = j
        }

        for j in 1...s2.count {
            for i in 1...s1.count {
                let indicator = s1[i - 1] == s2[j - 1] ? 0 : 1
                track[j][i] = min(
                    track[j][i - 1] + 1,
                    track[j - 1][i] + 1,
                    track[j - 1][i - 1] + indicator
                )
            }
        }

        return track[s2.count][s1.count]
    }

    static func normalize(_ text: String) -> String {
        var normalized = text.lowercased()

        normalized = normalized.folding(options: .diacriticInsensitive, locale: nil)

        normalized = normalized.replacingOccurrences(
            of: "[^a-z0-9 ]",
            with: "",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: .whitespaces)
    }

    static func parseTitleAndAuthor(from query: String) -> (title: String, author: String?) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return (trimmed, nil) }

        let pattern = "\\s+(?i)by\\s+|\\s+-\\s+"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return (trimmed, nil)
        }

        let matches = regex.matches(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed))

        guard let lastMatch = matches.last, let range = Range(lastMatch.range, in: trimmed) else {
            return (trimmed, nil)
        }

        let titlePart = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let authorPart = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)

        if titlePart.isEmpty || authorPart.isEmpty {
            return (trimmed, nil)
        }

        return (titlePart, authorPart)
    }
}
