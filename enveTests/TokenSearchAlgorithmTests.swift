import Foundation
@preconcurrency import ReadiumShared
import Testing

@testable import enve

@MainActor
struct TokenSearchAlgorithmTests {
    @Test func quoteMatchesAcrossTypographicPunctuationDifferences() async {
        let algorithm = TokenSearchAlgorithm()
        let text = "It’s a well-known truth that readers remember the exact sentence."

        let ranges = await algorithm.findRanges(
            of: "It's a well known truth that readers remember the exact sentence.",
            options: algorithm.options,
            in: text,
            language: nil
        )

        #expect(ranges.count == 1)
    }

    @Test func longExactQuoteIsNotLimitedToTheShortFuzzyWindow() async {
        let algorithm = TokenSearchAlgorithm()
        let middle = String(repeating: "carefully ", count: 20)
        let text = "Readers \(middle)remember this ending."

        let ranges = await algorithm.findRanges(
            of: text,
            options: algorithm.options,
            in: text,
            language: nil
        )

        #expect(ranges.count == 1)
    }
}
