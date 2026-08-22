import Foundation
import Testing

@testable import enve

struct ReaderProgressPolicyTests {
    @Test func bridgeWritesStayDisarmedUntilAUserInteractionIsRendered() {
        var gate = ReaderBridgeWriteGate()

        gate.armIfUserInteractionPending()
        #expect(!gate.isWriteArmed)

        gate.noteUserInteraction()
        #expect(!gate.isWriteArmed)

        gate.armIfUserInteractionPending()
        #expect(gate.isWriteArmed)
        #expect(!gate.isUserInteractionPending)
    }

    @Test func armingIsConsumedByASingleCommit() {
        var gate = ReaderBridgeWriteGate()
        gate.noteUserInteraction()
        gate.armIfUserInteractionPending()

        gate.noteCommittedWrite()

        #expect(!gate.isWriteArmed)
        #expect(gate.hasCommittedUserPosition)

        gate.armIfUserInteractionPending()
        #expect(!gate.isWriteArmed)
    }

    @Test func restartingTheBridgeSessionForgetsPriorArmingAndCommits() {
        var gate = ReaderBridgeWriteGate()
        gate.noteUserInteraction()
        gate.armIfUserInteractionPending()
        gate.noteCommittedWrite()
        gate.noteUserInteraction()

        gate.reset()

        #expect(gate == ReaderBridgeWriteGate())
        #expect(!gate.hasCommittedUserPosition)
        #expect(!gate.isUserInteractionPending)
    }
}
