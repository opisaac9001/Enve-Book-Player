import Foundation
import Testing
import UIKit

@testable import enve

@MainActor
struct ReaderHardwarePageTurnTests {
    private typealias Policy = ReaderHardwarePageTurnPolicy

    @Test func existingKeyboardKeysKeepTheirDirections() {
        #expect(Policy.turn(forKeyInput: UIKeyCommand.inputLeftArrow) == .left)
        #expect(Policy.turn(forKeyInput: UIKeyCommand.inputRightArrow) == .right)
        #expect(Policy.turn(forKeyInput: UIKeyCommand.inputUpArrow) == .backward)
        #expect(Policy.turn(forKeyInput: UIKeyCommand.inputDownArrow) == .forward)
        #expect(Policy.turn(forKeyInput: " ") == .forward)
        #expect(Policy.turn(forKeyInput: "\r") == .forward)
        #expect(Policy.turn(forKeyInput: UIKeyCommand.inputPageDown) == .forward)
        #expect(Policy.turn(forKeyInput: UIKeyCommand.inputPageUp) == .backward)
    }

    @Test func pageTurnerFunctionKeysMatchTheAndroidEdition() {
        #expect(Policy.turn(forKeyInput: UIKeyCommand.f1) == .backward)
        #expect(Policy.turn(forKeyInput: UIKeyCommand.f2) == .forward)
        #expect(Policy.keyBindings.count == 10)
        #expect(Set(Policy.keyBindings.map(\.input)).count == Policy.keyBindings.count)
    }

    @Test func rawPressesMapToTheSameTurnsAsTheCommands() {
        let byCode: [(UIKeyboardHIDUsage, ReaderHardwarePageTurn)] = [
            (.keyboardLeftArrow, .left), (.keyboardRightArrow, .right),
            (.keyboardUpArrow, .backward), (.keyboardDownArrow, .forward),
            (.keyboardSpacebar, .forward), (.keyboardReturnOrEnter, .forward),
            (.keyboardPageDown, .forward), (.keyboardPageUp, .backward),
            (.keyboardF1, .backward), (.keyboardF2, .forward),
        ]
        for (code, turn) in byCode {
            #expect(Policy.turn(forKeyCode: code) == turn, "\(code)")
        }
        for code in [UIKeyboardHIDUsage.keyboardA, .keyboardEscape, .keyboardHome, .keyboardEnd, .keyboardF3, .keyboardTab] {
            #expect(Policy.turn(forKeyCode: code) == nil, "\(code)")
        }
    }

    @Test func otherKeysAreLeftToTheSystemAndTextInput() {
        for input in ["a", "j", UIKeyCommand.inputEscape, UIKeyCommand.inputHome, UIKeyCommand.inputEnd, UIKeyCommand.f3] {
            #expect(Policy.turn(forKeyInput: input) == nil, "\(input.debugDescription)")
        }
        #expect(Policy.turn(forKeyInput: nil) == nil)
    }

    @Test func onlyLeftAndRightFollowRightToLeftProgression() {
        #expect(ReaderHardwarePageTurn.right.isForward(rightToLeft: false))
        #expect(!ReaderHardwarePageTurn.right.isForward(rightToLeft: true))
        #expect(!ReaderHardwarePageTurn.left.isForward(rightToLeft: false))
        #expect(ReaderHardwarePageTurn.left.isForward(rightToLeft: true))
        for rightToLeft in [false, true] {
            #expect(ReaderHardwarePageTurn.forward.isForward(rightToLeft: rightToLeft))
            #expect(!ReaderHardwarePageTurn.backward.isForward(rightToLeft: rightToLeft))
        }
    }

    @Test func gamepadShouldersAndTriggersTurnByOrderAndTheDPadByDirection() {
        let turns = Dictionary(uniqueKeysWithValues: ReaderGamepadPageTurnButton.allCases.map { ($0, $0.turn) })
        #expect(turns == [
            .leftShoulder: .backward,
            .leftTrigger: .backward,
            .rightShoulder: .forward,
            .rightTrigger: .forward,
            .dpadLeft: .left,
            .dpadRight: .right,
        ])
    }

    @Test func inputIsIgnoredWhileDisabledInactiveCoveredOrEditing() {
        #expect(Policy.acceptsInput(isEnabled: true, isSceneActive: true, isCoveredByPresentation: false, isEditingText: false))
        #expect(!Policy.acceptsInput(isEnabled: false, isSceneActive: true, isCoveredByPresentation: false, isEditingText: false))
        #expect(!Policy.acceptsInput(isEnabled: true, isSceneActive: false, isCoveredByPresentation: false, isEditingText: false))
        #expect(!Policy.acceptsInput(isEnabled: true, isSceneActive: true, isCoveredByPresentation: true, isEditingText: false))
        #expect(!Policy.acceptsInput(isEnabled: true, isSceneActive: true, isCoveredByPresentation: false, isEditingText: true))
    }

    @Test func theReaderFocusedLastTakesAGamepadPress() {
        let earlier = Date(timeIntervalSinceReferenceDate: 100)
        let later = Date(timeIntervalSinceReferenceDate: 200)
        #expect(Policy.gamepadTarget(focusedAt: [earlier, later]) == 1)
        #expect(Policy.gamepadTarget(focusedAt: [later, earlier]) == 0)
        // A reader that will not take input, or never had focus, never wins over one that will.
        #expect(Policy.gamepadTarget(focusedAt: [nil, earlier]) == 1)
        #expect(Policy.gamepadTarget(focusedAt: [later, nil]) == 0)
        #expect(Policy.gamepadTarget(focusedAt: [nil, nil]) == nil)
        #expect(Policy.gamepadTarget(focusedAt: []) == nil)
    }

    @Test func theCaptureOffersKeysOnlyWhileEnabledAndUncovered() async throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
        )
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let capture = ReaderHardwareNavigationCapture.HardwareCaptureController()
        window.rootViewController = capture
        window.makeKeyAndVisible()
        defer {
            capture.tearDown()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        #expect(capture.becomeFirstResponder())
        #expect(capture.acceptsGamepadInput)
        capture.gameControllersEnabled = false
        #expect(!capture.acceptsGamepadInput)
        capture.gameControllersEnabled = true

        let commands = try #require(capture.keyCommands)
        #expect(Set(commands.compactMap(\.input)) == Set(Policy.keyBindings.map(\.input)))
        #expect(commands.allSatisfy { $0.modifierFlags.isEmpty && $0.wantsPriorityOverSystemBehavior })
        let action = try #require(commands.first?.action)
        #expect(capture.canPerformAction(action, withSender: nil))

        capture.keyboardEnabled = false
        #expect(capture.keyCommands == nil)
        let acceptsDisabledAction = capture.canPerformAction(action, withSender: nil)
        #expect(acceptsDisabledAction == false)
        capture.keyboardEnabled = true
        #expect(capture.acceptsKeyboardInput)

        // The command list stays stable while covered; the handlers decline instead.
        capture.present(UIViewController(), animated: false)
        #expect(capture.keyCommands?.count == Policy.keyBindings.count)
        #expect(!capture.acceptsKeyboardInput, "A sheet over the reader keeps its own keys")
        let acceptsCoveredAction = capture.canPerformAction(action, withSender: nil)
        #expect(acceptsCoveredAction == false)
        capture.dismiss(animated: false)
        for _ in 0..<20 where capture.presentedViewController != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(capture.acceptsKeyboardInput)
        #expect(capture.canPerformAction(action, withSender: nil))
    }
}
