import Foundation
import Testing

@testable import enve

@MainActor
struct LinkedBookAlignmentQualityTests {
    private static let credible = anchors(at: (1...9).map { Double($0) / 10 })

    private static let gappy = anchors(at: [0.10, 0.15, 0.20, 0.80, 0.85, 0.90])

    @Test func credibleRunIsUsable() {
        let quality = LinkedBookAlignmentEvaluator.assess(Self.credible).quality
        #expect(quality.isUsable)
        #expect(quality.unitCount == 9)
        #expect(quality.purity == 1)
        #expect(quality.monotonicity == 1)
        #expect(quality.coverage > 0.75)
        #expect(quality.largestGap <= 0.11)
    }

    @Test func unevenPacingScoresLowerThanSteadyPacing() {
        let lurching = Self.anchors(
            audio: (1...9).map { Double($0) / 10 },
            ebook: [0.02, 0.04, 0.06, 0.08, 0.10, 0.62, 0.72, 0.82, 0.94]
        )
        let uneven = LinkedBookAlignmentEvaluator.assess(lurching).quality
        let steady = LinkedBookAlignmentEvaluator.assess(Self.credible).quality
        #expect(uneven.isUsable)
        #expect(uneven.timingConsistency < steady.timingConsistency)
    }

    @Test func mostlyMalformedRunIsNotUsable() {
        let quality = LinkedBookAlignmentEvaluator.assess([
            Self.anchor(audio: 0.2, ebook: 0.2),
            Self.anchor(audio: 0.8, ebook: 0.8),
            Self.anchor(audio: .nan, ebook: 0.3),
            Self.anchor(audio: 0.4, ebook: .infinity),
            Self.anchor(audio: 1.4, ebook: 0.5),
            Self.anchor(audio: 0.6, ebook: 0.6, quote: "  "),
        ]).quality
        #expect(!quality.isUsable)
        #expect(quality.defects.contains(.malformedAnchors))
        #expect(quality.purity < 0.5)
    }

    @Test func contradictoryRunIsNotUsable() {
        let quality = LinkedBookAlignmentEvaluator.assess(
            Self.anchors(
                audio: (1...8).map { Double($0) / 10 },
                ebook: [0.10, 0.90, 0.85, 0.80, 0.75, 0.70, 0.65, 0.60]
            )
        ).quality
        #expect(!quality.isUsable)
        #expect(quality.defects.contains(.notMonotonic))
    }

    @Test func clusteredRunIsNotUsable() {
        let quality = LinkedBookAlignmentEvaluator.assess(
            Self.anchors(at: [0.500, 0.504, 0.508, 0.512])
        ).quality
        #expect(!quality.isUsable)
        #expect(quality.defects.contains(.degenerateSpan))
    }

    @Test func firstUsableRunIsAlwaysAccepted() {
        let decision = LinkedBookAlignmentEvaluator.decide(
            candidate: LinkedBookAlignmentEvaluator.assess(Self.gappy),
            incumbent: nil
        )
        #expect(decision.isAccepted)
    }

    @Test func clearlyWorseRunIsRefused() {
        let decision = LinkedBookAlignmentEvaluator.decide(
            candidate: LinkedBookAlignmentEvaluator.assess(Self.gappy),
            incumbent: LinkedBookAlignmentEvaluator.assess(Self.credible).quality
        )
        guard case .rejected(let reason, _, let explanation) = decision else {
            Issue.record("expected the sparser run to be refused")
            return
        }
        #expect(reason == .inferiorCandidate)
        #expect(!explanation.isEmpty)
    }

    @Test func runThatTradesOneMeasurementForAnotherIsAccepted() {
        let wider = Self.anchors(at: [0.02, 0.06, 0.10, 0.14, 0.18, 0.78, 0.86, 0.92, 0.98])
        let decision = LinkedBookAlignmentEvaluator.decide(
            candidate: LinkedBookAlignmentEvaluator.assess(wider),
            incumbent: LinkedBookAlignmentEvaluator.assess(Self.credible).quality
        )
        #expect(decision.isAccepted)
    }

    @Test func refusedRunLeavesTheAcceptedMapInPlace() {
        var versions = LinkedBookCalibrationVersions()
        let decision = versions.install(Self.credible)
        #expect(decision.isAccepted)

        #expect(!versions.install(Self.gappy).isAccepted)
        #expect(versions.accepted?.count == 9)
        #expect(!versions.hasPrevious)
    }

    @Test func malformedRunCannotReplaceAnAcceptedMap() {
        var versions = LinkedBookCalibrationVersions()
        versions.install(Self.credible)

        let refused = versions.install([
            Self.anchor(audio: .nan, ebook: .nan),
            Self.anchor(audio: 2, ebook: -1),
            Self.anchor(audio: 0.5, ebook: 0.5, quote: ""),
        ])
        guard case .rejected(let reason, _, _) = refused else {
            Issue.record("expected the malformed run to be refused")
            return
        }
        #expect(reason == .invalidCandidate)
        #expect(versions.accepted?.count == 9)
    }

    @Test func betterRunReplacesTheMapAndKeepsItRestorable() {
        var versions = LinkedBookCalibrationVersions()
        versions.install(Self.gappy)
        let decision = versions.install(Self.credible)
        #expect(decision.isAccepted)

        #expect(versions.accepted?.count == 9)
        #expect(versions.previous?.count == 6)
        #expect(versions.hasPrevious)
    }

    @Test func restoringPutsTheEarlierMapBackAndStaysReversible() {
        var versions = LinkedBookCalibrationVersions()
        versions.install(Self.gappy)
        versions.install(Self.credible)

        let restored = versions.restorePrevious()
        #expect(restored)
        #expect(versions.accepted?.count == 6)
        #expect(versions.previous?.count == 9)

        let restoredAgain = versions.restorePrevious()
        #expect(restoredAgain)
        #expect(versions.accepted?.count == 9)
    }

    @Test func restoringWithoutAnEarlierMapDoesNothing() {
        var versions = LinkedBookCalibrationVersions()
        versions.install(Self.credible)
        let restored = versions.restorePrevious()
        #expect(!restored)
        #expect(versions.accepted?.count == 9)
    }

    @Test func mapStoredWithoutQualityIsRetainedOnTheNextRun() {
        var versions = LinkedBookCalibrationVersions(
            accepted: Self.gappy,
            acceptedQuality: nil,
            previous: nil,
            previousQuality: nil
        )
        let decision = versions.install(Self.credible)
        #expect(decision.isAccepted)
        #expect(versions.accepted?.count == 9)
        #expect(versions.previous?.count == 6)
    }

    @Test func clearingDropsBothVersions() {
        var versions = LinkedBookCalibrationVersions()
        versions.install(Self.gappy)
        versions.install(Self.credible)
        versions.clear()

        #expect(versions.accepted == nil)
        #expect(!versions.hasPrevious)
    }

    private static func anchors(at progressions: [Double]) -> [LinkedBookCalibrationAnchor] {
        anchors(audio: progressions, ebook: progressions)
    }

    private static func anchors(
        audio: [Double],
        ebook: [Double]
    ) -> [LinkedBookCalibrationAnchor] {
        zip(audio, ebook).map { anchor(audio: $0, ebook: $1) }
    }

    private static func anchor(
        audio: Double,
        ebook: Double,
        quote: String = "anchored passage"
    ) -> LinkedBookCalibrationAnchor {
        LinkedBookCalibrationAnchor(
            ebookProgress: ebook,
            audioProgress: audio,
            quote: quote,
            href: "chapter.xhtml",
            confidence: 0.8
        )
    }
}
