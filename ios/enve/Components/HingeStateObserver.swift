import SwiftUI
import UIKit

struct HingeStateObserver: UIViewRepresentable {
    let store: HingeStateStore

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        #if compiler(>=6.4)
        if #available(iOS 27.1, *) {
            let store = store
            let interaction = UIHingeInteraction { _, update in
                // Defer updates that arrive during SwiftUI view installation.
                let status = update.hinge.map { Self.status(for: $0.status) }
                let angle = update.hinge.map { Double($0.angle) }
                Task { @MainActor in
                    if let status {
                        store.noteHinge(status: status, angle: angle)
                    } else {
                        store.noteHingeUnavailable()
                    }
                }
            }
            view.addInteraction(interaction)
        }
        #endif
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    #if compiler(>=6.4)
    @available(iOS 27.1, *)
    private static func status(for status: UIHinge.Status) -> HingeStateStore.Status {
        switch status {
        case .closed: .closed
        case .partiallyOpen: .partiallyOpen
        case .fullyOpen: .fullyOpen
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
    #endif
}
