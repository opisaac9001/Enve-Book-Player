import Foundation

public struct CTCAlignmentQuality: Codable, Sendable, Equatable {
    public let eligibleSentenceCount: Int
    public let acceptedSentenceCount: Int
    public let audioCoverage: Double

    public init(eligibleSentenceCount: Int, acceptedSentenceCount: Int, audioCoverage: Double) {
        self.eligibleSentenceCount = eligibleSentenceCount
        self.acceptedSentenceCount = acceptedSentenceCount
        self.audioCoverage = audioCoverage
    }

    public var coverage: Double {
        eligibleSentenceCount > 0 ? Double(acceptedSentenceCount) / Double(eligibleSentenceCount) : 0
    }

    var isUsable: Bool {
        eligibleSentenceCount >= 3 && acceptedSentenceCount >= 3 && acceptedSentenceCount <= eligibleSentenceCount
            && coverage >= 0.70 && audioCoverage.isFinite && (0...1).contains(audioCoverage)
    }
}
