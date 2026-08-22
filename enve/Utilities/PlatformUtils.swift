import Foundation
import SwiftUI

enum PlatformRuntime {
    static var cloudKitEnabled: Bool {
        #if DEBUG && targetEnvironment(macCatalyst)
        !ProcessInfo.processInfo.arguments.contains("-disableCloudKit")
        #else
        true
        #endif
    }
}

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias UIImage = NSImage
#endif

#if os(macOS)
enum UIKeyboardType {
    case `default`
    case emailAddress
    case URL
    case numberPad
    case decimalPad
}

extension View {
    func keyboardType(_ type: UIKeyboardType) -> some View {
        self
    }
}
#endif

enum PlatformHaptics {
    enum ImpactStyle {
        case light
        case medium
        case heavy
        case soft
        case rigid
    }

    enum NotificationStyle {
        case success
        case warning
        case error
    }

    static func impact(_ style: ImpactStyle = .medium) {
        #if os(iOS)
        let uiStyle: UIImpactFeedbackGenerator.FeedbackStyle = {
            switch style {
            case .light: return .light
            case .medium: return .medium
            case .heavy: return .heavy
            case .soft: return .soft
            case .rigid: return .rigid
            }
        }()
        UIImpactFeedbackGenerator(style: uiStyle).impactOccurred()
        #endif
    }

    static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }

    static func notification(_ style: NotificationStyle) {
        #if os(iOS)
        let uiStyle: UINotificationFeedbackGenerator.FeedbackType = {
            switch style {
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }()
        UINotificationFeedbackGenerator().notificationOccurred(uiStyle)
        #endif
    }
}

final class BackgroundTaskAssertion {
    #if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {}

    static func begin(name: String, expirationHandler: (@Sendable () -> Void)? = nil) -> BackgroundTaskAssertion {
        let assertion = BackgroundTaskAssertion()
        #if os(iOS)
        assertion.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak assertion] in
            expirationHandler?()
            assertion?.end()
        }
        #endif
        return assertion
    }

    func end() {
        #if os(iOS)
        guard identifier != .invalid else { return }
        let activeIdentifier = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(activeIdentifier)
        #endif
    }

    var isValid: Bool {
        #if os(iOS)
        identifier != .invalid
        #else
        false
        #endif
    }
}
